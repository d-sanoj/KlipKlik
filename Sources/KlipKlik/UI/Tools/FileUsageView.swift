import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

final class FileUsageModel: ObservableObject {
    @Published private(set) var target: URL?
    @Published private(set) var holders: [FileHolder] = []
    @Published private(set) var isChecking = false
    @Published private(set) var hasChecked = false
    @Published private(set) var checkedAsAdministrator = false
    @Published private(set) var volumes: [URL] = []
    @Published var message: String?

    var targetIsVolume: Bool { target.map(FileUsage.isVolume) ?? false }

    func refreshVolumes() {
        volumes = FileUsage.ejectableVolumes()
    }

    func chooseAndCheck() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Check"
        panel.message = "Choose a file, folder or disk to see what is using it."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        check(url)
    }

    /// Looks for processes with anything open under `url`.
    func check(_ url: URL, asAdministrator: Bool = false, then: (([FileHolder]) -> Void)? = nil) {
        target = url
        holders = []
        isChecking = true
        message = nil
        FileUsage.holders(of: url, asAdministrator: asAdministrator) { [weak self] result in
            guard let self, self.target == url else { return }
            isChecking = false
            hasChecked = true
            checkedAsAdministrator = asAdministrator
            switch result {
            case .success(let found):
                holders = found
                then?(found)
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    func recheck() {
        guard let target else { return }
        check(target, asAdministrator: checkedAsAdministrator)
    }

    func stop(_ holder: FileHolder) {
        ProcessStopper.stop(
            pid: holder.pid, name: holder.command,
            reason: "It has \(holder.files.count) file\(holder.files.count == 1 ? "" : "s") open here.",
            stoppedMessage: "Stopped \(holder.command)."
        ) { [weak self] message, stopped in
            self?.message = message
            if stopped { self?.recheck() }
        }
    }

    /// - Parameter then: gets the line describing how it went.
    func eject(then: ((String) -> Void)? = nil) {
        guard let target else { return }
        let name = FileManager.default.displayName(atPath: target.path)
        FileUsage.eject(target) { [weak self] error in
            guard let self else { return }
            if let error {
                message = "Couldn't eject \(name): \(error.localizedDescription)"
            } else {
                message = "Ejected \(name)."
                self.target = nil
                holders = []
                hasChecked = false
                refreshVolumes()
            }
            if let message { then?(message) }
        }
    }

    /// The menu bar's "Eject ▸ <disk>": eject straight away when nothing holds
    /// it; otherwise say who does, and offer to quit them or look closer.
    func ejectFromMenu(_ volume: URL, review: @escaping () -> Void) {
        let name = FileManager.default.displayName(atPath: volume.path)
        check(volume) { [weak self] found in
            guard let self else { return }
            guard !found.isEmpty else {
                eject { message in
                    ToolsAlert.inform(message.hasPrefix("Ejected") ? "Ejected" : "Not Ejected", message)
                }
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(name) is in use"
            alert.informativeText = found.prefix(6).map { "• \($0.command)" }.joined(separator: "\n")
                + (found.count > 6 ? "\n…and \(found.count - 6) more" : "")
                + "\n\nQuit them and eject? Unsaved work in them may be lost."
            alert.addButton(withTitle: "Quit and Eject")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Show Details…")
            ToolsAlert.ask(alert) { [weak self] response in
                switch response {
                case .alertFirstButtonReturn: self?.quitAllThenEject(found)
                case .alertThirdButtonReturn: review()
                default: break
                }
            }
        }
    }

    private func quitAllThenEject(_ found: [FileHolder]) {
        let group = DispatchGroup()
        for holder in found {
            group.enter()
            Ports.stop(pid: holder.pid, force: false) { _ in group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, let target else { return }
            check(target) { [weak self] remaining in
                guard let self else { return }
                if remaining.isEmpty {
                    eject { message in ToolsAlert.inform("Eject", message) }
                } else {
                    ToolsAlert.inform(
                        "Still in use",
                        remaining.map(\.command).joined(separator: ", ")
                            + " did not quit. Open What's Using It to force them."
                    )
                }
            }
        }
    }
}

// MARK: - View

struct FileUsageView: View {
    @ObservedObject var model: FileUsageModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if let target = model.target {
                header(for: target)
                Divider()
            }
            content.fillsToolArea()
            ToolActionBar {
                ToolMessage(text: model.message ?? footnote)
            } trailing: {
                if model.targetIsVolume {
                    Button("Eject") { model.eject() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isChecking || !model.holders.isEmpty)
                }
            }
        }
        .onAppear { model.refreshVolumes() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { model.check(url) }
            }
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.chooseAndCheck()
                } label: {
                    Label("Choose…", systemImage: "folder")
                }
                .help("Choose a file, folder or disk")
            }
        }
    }

    private var footnote: String? {
        guard model.hasChecked, !model.checkedAsAdministrator else { return nil }
        return "Only your own programs are listed. Include System Processes also shows Spotlight and others."
    }

    private func header(for target: URL) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: target.path))
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(FileManager.default.displayName(atPath: target.path)).font(.title3.weight(.semibold))
                Text(target.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Check Again") { model.recheck() }
                .disabled(model.isChecking)
            Button("Include System Processes…") {
                model.check(target, asAdministrator: true)
            }
            .help("Asks for your password, so processes run by macOS itself are listed too")
            .disabled(model.isChecking || model.checkedAsAdministrator)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if model.isChecking {
            ToolProgress(text: "Looking for programs using it…")
        } else if model.target == nil {
            VStack(spacing: 18) {
                ContentUnavailableView {
                    Label("What's Using It", systemImage: "lock.doc")
                } description: {
                    Text("Find the program keeping a disk from ejecting, or a file from being moved "
                        + "or deleted. Drop a file, folder or disk here, or choose one.")
                } actions: {
                    Button("Choose…") { model.chooseAndCheck() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxHeight: 260)

                if !model.volumes.isEmpty {
                    volumeList
                }
            }
        } else if model.holders.isEmpty {
            ContentUnavailableView {
                Label("Nothing Is Using It", systemImage: "checkmark.seal")
            } description: {
                Text(model.targetIsVolume
                     ? "Nothing has it open, so it can be ejected."
                     : "No program has it open.")
            }
        } else {
            Table(model.holders) {
                TableColumn("Program") { holder in
                    HStack(spacing: 7) {
                        holderIcon(holder.pid)
                        Text(holder.command)
                    }
                }
                .width(min: 150, ideal: 200)
                TableColumn("PID") { holder in
                    Text(String(holder.pid)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(64)
                TableColumn("User") { holder in
                    Text(holder.user).foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80)
                TableColumn("Open Files") { holder in
                    Text(holder.files.first.map {
                        holder.files.count > 1 ? "\($0) and \(holder.files.count - 1) more" : $0
                    } ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(holder.files.prefix(20).joined(separator: "\n"))
                }
                .width(min: 180, ideal: 280)
                TableColumn("") { holder in
                    Button("Stop") { model.stop(holder) }.controlSize(.small)
                }
                .width(56)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var volumeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Disks").font(.headline)
            ForEach(model.volumes, id: \.self) { volume in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: volume.path))
                        .resizable()
                        .frame(width: 24, height: 24)
                    Text(FileManager.default.displayName(atPath: volume.path))
                    Spacer()
                    Button("Check") { model.check(volume) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.4)))
            }
        }
        .frame(maxWidth: 420)
    }

    @ViewBuilder
    private func holderIcon(_ pid: Int32) -> some View {
        if let app = NSRunningApplication(processIdentifier: pid), app.bundleURL?.pathExtension == "app",
           let icon = app.icon {
            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "terminal").foregroundStyle(.secondary).frame(width: 16, height: 16)
        }
    }
}
