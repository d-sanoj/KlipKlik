import AppKit
import Combine

/// The bar's state: what was typed, what Finder has selected, and where a
/// request is between "typed" and "done".
///
/// Every request takes the same road — selection, then an instant action or
/// the model, then the validator, then the builder — and stops at a preview
/// before anything runs. The one shortcut is an instant action whose plan
/// only creates new files: "zip" and "jpg" run on ↩, as they would from a
/// Finder menu, because there is nothing to undo.
@MainActor
final class PlinthBarModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(String)
        case preview(PlinthPlan)
        /// A destructive plan waiting for its second yes.
        case confirming(PlinthPlan)
        case running(PlinthPlan)
        case message(String, isError: Bool)
    }

    @Published var text = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var selection: [PlinthItem] = []
    @Published private(set) var availability: PlinthModelAvailability = .available
    /// Set by the controller from the Finder window's width.
    @Published var width: CGFloat = PlinthPlacement.minWidth

    /// Hands the keyboard back to Finder.
    var onDone: (() -> Void)?
    /// Asks the view to put the cursor in the field.
    let focusRequests = PassthroughSubject<Void, Never>()

    private var interpreter: PlinthInterpreter?
    private var task: Task<Void, Never>?
    private let runner = PlinthRunner()
    /// The request a preview was made from, so ↩ on an unchanged field runs
    /// it rather than asking the model again.
    private var previewedRequest: String?

    var selectionLabel: String? {
        guard !selection.isEmpty else { return nil }
        let summary = PlinthSelectionSummary(selection)
        if summary.kinds.count == 1, let kind = summary.kinds.keys.first {
            return kind.counted(summary.total)
        }
        return PlinthFileKind.other.counted(summary.total).replacingOccurrences(of: "files", with: "items")
    }

    var isBusy: Bool {
        switch phase {
        case .working, .running: return true
        default: return false
        }
    }

    // MARK: Focus

    /// The bar was clicked or summoned: check the model, warm it, and show
    /// what is selected.
    func didFocus() {
        focusRequests.send()
        availability = PlinthModel.availability
        if availability == .available {
            if interpreter == nil { interpreter = PlinthModel.makeInterpreter() }
            interpreter?.prewarm()
        }
        Task { [weak self] in
            guard let self, let items = try? await readSelection().get() else { return }
            selection = items
        }
    }

    /// esc: back out one level.
    func escape() {
        switch phase {
        case .working:
            task?.cancel()
            phase = .idle
        case .preview, .confirming, .message:
            phase = .idle
            previewedRequest = nil
        case .running:
            onDone?()
        case .idle:
            if text.isEmpty { onDone?() } else { text = "" }
        }
    }

    // MARK: Requests

    /// ↩ in the field, or a chip.
    func submit(_ chip: String? = nil) {
        let request = (chip ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isBusy else { return }

        // ↩ again on the request that is already previewed runs it.
        if chip == nil, request == previewedRequest {
            switch phase {
            case .preview: run()
            default: break
            }
            return
        }
        if let chip { text = chip }
        guard request.count <= PlinthLimits.requestLength else {
            show(.requestTooLong(limit: PlinthLimits.requestLength))
            return
        }

        task?.cancel()
        task = Task { [weak self] in await self?.handle(request) }
    }

    private func handle(_ request: String) async {
        phase = .working("Reading Finder's selection…")
        let items: [PlinthItem]
        switch await readSelection() {
        case .success(let read): items = read
        case .failure(let error): show(error); return
        }
        selection = items
        guard !Task.isCancelled else { return }
        guard !items.isEmpty else { show(.emptySelection); return }
        let summary = PlinthSelectionSummary(items)

        do {
            let command: PlinthCommand
            let isInstant: Bool
            if let instant = PlinthInstantActions.command(for: request, selection: summary) {
                command = instant
                isInstant = true
            } else {
                availability = PlinthModel.availability
                guard case .available = availability,
                      let interpreter = interpreter ?? PlinthModel.makeInterpreter()
                else {
                    if case .unavailable(let reason) = availability { throw PlinthError.modelUnavailable(reason) }
                    throw PlinthError.modelUnavailable("Apple Intelligence isn't available right now.")
                }
                self.interpreter = interpreter
                phase = .working("Thinking…")
                let raw = try await interpreter.interpret(request, selection: summary)
                guard !Task.isCancelled else { return }
                command = try PlinthIntentValidator.command(from: raw, selection: summary)
                isInstant = false
            }

            let plan = try PlinthCommandBuilder.live.plan(command, for: items)
            previewedRequest = request
            if isInstant, !plan.isDestructive, plan.missingTools.isEmpty, plan.skipped.isEmpty {
                execute(plan)
            } else {
                phase = .preview(plan)
            }
        } catch let error as PlinthError {
            show(error)
        } catch is CancellationError {
            phase = .idle
        } catch {
            show(.modelFailed(error.localizedDescription))
        }
    }

    /// Run on a preview: install what is missing, confirm what is
    /// destructive, then go.
    func run() {
        let plan: PlinthPlan
        switch phase {
        case .preview(let previewed), .confirming(let previewed): plan = previewed
        default: return
        }

        if let tool = plan.missingTools.first {
            PlinthToolInstaller.offer(tool) { [weak self] installed in
                guard let self else { return }
                Self.bringFinderForward()
                guard installed else { return }
                rebuild(plan)
            }
            return
        }
        if plan.isDestructive, case .preview = phase {
            phase = .confirming(plan)
            return
        }
        execute(plan)
    }

    /// Stop on a running plan.
    func stop() {
        runner.cancel()
    }

    /// The same command against the same files, after ffmpeg arrived.
    private func rebuild(_ plan: PlinthPlan) {
        do {
            phase = .preview(try PlinthCommandBuilder.live.plan(plan.command, for: selection))
        } catch let error as PlinthError {
            show(error)
        } catch {
            show(.modelFailed(error.localizedDescription))
        }
    }

    private func execute(_ plan: PlinthPlan) {
        phase = .running(plan)
        ConversionCenter.shared.run(plan.title, onSuccess: { _ in }) { [weak self] progress, done in
            guard let self else { return }
            runner.run(plan, progress: progress) { [weak self] result in
                switch result {
                case .success(let outputs):
                    if let first = outputs.first {
                        done(.success(first))
                    } else {
                        done(.failure(.init(message: "Nothing was made.")))
                    }
                    self?.finish(plan, outputs: outputs)
                case .failure(let failure):
                    let detail = failure.completed.isEmpty
                        ? failure.message
                        : failure.message + " \(failure.completed.count) finished before that."
                    done(.failure(.init(message: detail)))
                    self?.phase = .message(detail, isError: true)
                }
            }
        }
    }

    private func finish(_ plan: PlinthPlan, outputs: [URL]) {
        text = ""
        previewedRequest = nil
        let count = outputs.count
        let verb: String
        switch plan.command.action {
        case .rename: verb = "Renamed"
        default: verb = "Made"
        }
        phase = .message("\(verb) \(count) item\(count == 1 ? "" : "s").", isError: false)
        // Finder's selection moves to the results, so the chip follows.
        if PlinthSettings.shared.selectResults {
            PlinthFinder.select(outputs)
            selection = PlinthItem.live(outputs)
        }
    }

    private func show(_ error: PlinthError) {
        phase = .message(error.message, isError: true)
    }

    // MARK: Finder

    private func readSelection() async -> Result<[PlinthItem], PlinthError> {
        await withCheckedContinuation { continuation in
            FinderScript.selection { result in
                switch result {
                case .success(let urls):
                    continuation.resume(returning: .success(PlinthItem.live(urls)))
                case .failure(.notPermitted):
                    continuation.resume(returning: .failure(.automationDenied))
                case .failure(.failed(let message)):
                    continuation.resume(returning: .failure(.finderFailed(
                        message.trimmingCharacters(in: .whitespacesAndNewlines))))
                }
            }
        }
    }

    static func bringFinderForward() {
        NSRunningApplication.runningApplications(withBundleIdentifier: FinderWindowTracker.finderBundleID)
            .first?.activate()
    }
}

/// Selecting results in Finder, by path list passed as arguments — never
/// pasted into the script's text.
enum PlinthFinder {
    static func select(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let script = [
            "on run argv",
            "set chosen to {}",
            "repeat with p in argv",
            "set end of chosen to (POSIX file (contents of p)) as alias",
            "end repeat",
            "tell application \"Finder\" to select chosen",
            "end run"
        ]
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = script.flatMap { ["-e", $0] } + urls.prefix(200).map(\.path)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }
}
