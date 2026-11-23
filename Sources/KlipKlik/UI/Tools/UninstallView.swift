import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

final class UninstallModel: ObservableObject {
    /// What the right-hand side is about: an installed app, or one already
    /// removed that left files behind (from the removal watcher).
    enum Target: Equatable {
        case app(AppBundle)
        case removed(name: String, identity: LeftoverMatcher.Identity)

        var name: String {
            switch self {
            case .app(let app): return app.name
            case .removed(let name, _): return name
            }
        }

        var bundleID: String {
            switch self {
            case .app(let app): return app.bundleID
            case .removed(_, let identity): return identity.bundleID
            }
        }
    }

    @Published var apps: [AppBundle] = []
    @Published var isLoadingApps = false
    @Published var query = ""
    @Published private(set) var target: Target?
    @Published private(set) var leftovers: [Leftover] = []
    @Published var checked: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var isRemoving = false
    @Published var message: String?

    /// Sizes measured in the background, keyed by app path.
    @Published private(set) var appSizes: [String: Int64] = [:]

    var filteredApps: [AppBundle] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.bundleID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// The list's selection: the chosen installed app, if that is the target.
    var selectedAppID: String? {
        if case .app(let app) = target { return app.id }
        return nil
    }

    var selectedBytes: Int64 {
        leftovers.filter { checked.contains($0.id) }.reduce(0) { $0 + ($1.size ?? 0) }
    }

    func loadAppsIfNeeded() {
        guard apps.isEmpty, !isLoadingApps else { return }
        reloadApps()
    }

    func reloadApps() {
        isLoadingApps = true
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = InstalledApps.list()
            DispatchQueue.main.async { [weak self] in
                self?.apps = apps
                self?.isLoadingApps = false
                self?.measureApps(apps)
            }
        }
    }

    private func measureApps(_ apps: [AppBundle]) {
        DispatchQueue.global(qos: .utility).async {
            for app in apps {
                let size = LeftoverScanner.allocatedSize(of: app.url)
                DispatchQueue.main.async { [weak self] in self?.appSizes[app.id] = size }
            }
        }
    }

    func select(_ app: AppBundle) {
        message = nil
        scan(.app(app))
    }

    /// An app dropped onto the window, wherever it lives.
    func select(droppedURL url: URL) {
        guard let app = AppBundle(url: url) else {
            message = "That is not an app."
            return
        }
        if let refusal = InstalledApps.refusal(for: app) {
            message = refusal
            return
        }
        select(app)
    }

    /// From the removal watcher: the app is gone, these are its leftovers.
    func show(removed: AppRemovalWatcher.RemovedApp) {
        message = nil
        target = .removed(name: removed.name, identity: removed.identity)
        leftovers = removed.leftovers
        checked = Set(removed.leftovers.filter { $0.strength == .exact }.map(\.id))
    }

    private func scan(_ target: Target) {
        self.target = target
        leftovers = []
        checked = []
        isScanning = true

        DispatchQueue.global(qos: .userInitiated).async {
            let identity: LeftoverMatcher.Identity
            var bundleURL: URL?
            switch target {
            case .app(let app):
                identity = app.identity
                bundleURL = app.url
            case .removed(_, let removedIdentity):
                identity = removedIdentity
            }
            let others = InstalledApps.allBundleIDs().subtracting([identity.bundleID])
            let found = LeftoverScanner.scan(app: identity, bundleURL: bundleURL, others: others)

            DispatchQueue.main.async { [weak self] in
                guard let self, self.target == target else { return }
                leftovers = found
                checked = Set(found.filter { $0.strength == .exact }.map(\.id))
                isScanning = false
            }
        }
    }

    func toggle(_ item: Leftover) {
        if checked.contains(item.id) { checked.remove(item.id) } else { checked.insert(item.id) }
    }

    /// Confirms, quits the app if it is running, and moves everything ticked
    /// to the Trash.
    func removeChecked() {
        guard let target, !isRemoving else { return }
        let chosen = leftovers.filter { checked.contains($0.id) }
        guard !chosen.isEmpty else { return }

        let removesApp = chosen.contains { $0.kind == .appBundle }
        let needsAdmin = chosen.contains(where: \.needsAdmin)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = removesApp
            ? "Uninstall \(target.name)?"
            : "Remove \(chosen.count) leftover item\(chosen.count == 1 ? "" : "s") of \(target.name)?"
        alert.informativeText = "\(chosen.count) item\(chosen.count == 1 ? "" : "s"), "
            + "\(formattedBytes(selectedBytes)), go to the Trash — you can put them back from "
            + "there until it is emptied. \(target.name)'s privacy permissions are reset too."
            + (needsAdmin ? "\n\nSome items belong to the system, so macOS will ask for your password." : "")
        alert.addButton(withTitle: removesApp ? "Uninstall" : "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        ToolsAlert.confirm(alert) { [weak self] confirmed in
            guard let self, confirmed else { return }
            quitIfRunning(bundleID: target.bundleID, name: target.name) { [weak self] ready in
                guard ready else { return }
                self?.perform(chosen, target: target, removesApp: removesApp)
            }
        }
    }

    private func perform(_ chosen: [Leftover], target: Target, removesApp: Bool) {
        isRemoving = true
        message = nil
        AppRemover.remove(chosen, bundleID: target.bundleID) { [weak self] report in
            guard let self else { return }
            isRemoving = false
            leftovers.removeAll { item in report.removed.contains(item.url) }
            let remaining = Set(leftovers.map(\.id))
            checked = checked.intersection(remaining)
            message = Self.summary(report, name: target.name)
            if removesApp, report.removed.contains(where: { url in
                chosen.contains { $0.kind == .appBundle && $0.url == url }
            }) {
                apps.removeAll { $0.bundleID == target.bundleID }
            }
        }
    }

    /// Asks the app to quit, then waits up to six seconds for it — on a
    /// timer, never by spinning the main thread. `ready` is false when it
    /// would not go, or the user chose not to quit it.
    private func quitIfRunning(bundleID: String, name: String, ready: @escaping (Bool) -> Void) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else {
            ready(true)
            return
        }

        let alert = NSAlert()
        alert.messageText = "\(name) is open"
        alert.informativeText = "It has to quit before its files can be removed."
        alert.addButton(withTitle: "Quit \(name)")
        alert.addButton(withTitle: "Cancel")
        ToolsAlert.confirm(alert) { [weak self] confirmed in
            guard let self, confirmed else {
                ready(false)
                return
            }
            running.forEach { $0.terminate() }
            isRemoving = true
            message = "Waiting for \(name) to quit…"

            let deadline = Date().addingTimeInterval(6)
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
                let stillOpen = running.contains { !$0.isTerminated }
                guard !stillOpen || Date() >= deadline else { return }
                timer.invalidate()
                self?.isRemoving = false
                if stillOpen {
                    self?.message = "\(name) did not quit. Quit it yourself, then try again."
                    ready(false)
                } else {
                    self?.message = nil
                    ready(true)
                }
            }
        }
    }

    private static func summary(_ report: AppRemover.Report, name: String) -> String {
        var parts = ["Moved \(report.removed.count) item\(report.removed.count == 1 ? "" : "s") "
            + "(\(formattedBytes(report.freedBytes))) to the Trash."]
        if report.resetPrivacy { parts.append("Reset \(name)'s privacy permissions.") }
        if report.adminCancelled { parts.append("System items were skipped: no password given.") }
        let others = report.failed.filter { $0.reason != "Administrator password not given." }
        if !others.isEmpty {
            parts.append("\(others.count) could not be moved: \(others.first!.reason)")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - View

/// Apps on the left, the chosen app's files on the right — the layout of
/// Mail or Notes, so it reads at a glance.
struct UninstallView: View {
    @ObservedObject var model: UninstallModel
    @ObservedObject private var settings = Settings.shared
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            appList
                .frame(width: 250)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.loadAppsIfNeeded() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { model.select(droppedURL: url) }
            }
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.06))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.reloadApps()
                } label: {
                    Label("Reload Apps", systemImage: "arrow.clockwise")
                }
                .help("Look for apps again")
            }
        }
    }

    // MARK: App list

    private var appList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter", text: $model.query)
                    .textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(0.5)))
            .padding(10)

            if model.isLoadingApps {
                ToolProgress(text: "Finding apps…")
            } else {
                List(selection: Binding(
                    get: { model.selectedAppID },
                    set: { id in
                        if let id, let app = model.apps.first(where: { $0.id == id }) { model.select(app) }
                    }
                )) {
                    ForEach(model.filteredApps) { app in
                        AppRow(app: app, size: model.appSizes[app.id])
                            .tag(app.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            Divider()
            Toggle("Offer to clean up after removed apps", isOn: $settings.watchRemovedApps)
                .toggleStyle(.checkbox)
                .font(.callout)
                .help("When an app leaves Applications, KlipKlik lists the files it left behind "
                    + "for you to review. Nothing is removed without asking.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
        }
        .background(.background.opacity(0.4))
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let target = model.target {
            VStack(spacing: 0) {
                header(for: target)
                Divider()
                if model.isScanning {
                    ToolProgress(text: "Looking for everything \(target.name) keeps…")
                } else if model.leftovers.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing Left Behind", systemImage: "checkmark.seal")
                    } description: {
                        Text(model.message ?? "\(target.name) keeps no files outside its app.")
                    }
                } else {
                    LeftoverTable(items: model.leftovers, checked: $model.checked)
                }
                ToolActionBar {
                    ToolMessage(text: model.message)
                } trailing: {
                    if !model.leftovers.isEmpty {
                        Text("\(model.checked.count) of \(model.leftovers.count) · "
                            + formattedBytes(model.selectedBytes))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if model.isRemoving { ProgressView().controlSize(.small) }
                    Button(removesApp ? "Uninstall" : "Move to Trash", role: .destructive) {
                        model.removeChecked()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.checked.isEmpty || model.isRemoving || model.isScanning)
                }
            }
        } else {
            ContentUnavailableView {
                Label("Choose an App", systemImage: "trash")
            } description: {
                Text(model.message ?? "Pick an app to see everything it keeps on this Mac — support "
                    + "files, caches, preferences, containers, helpers and installer receipts — and "
                    + "remove it all at once. You can also drop an app here.")
            }
        }
    }

    private var removesApp: Bool {
        model.leftovers.contains { $0.kind == .appBundle && model.checked.contains($0.id) }
    }

    private func header(for target: UninstallModel.Target) -> some View {
        HStack(spacing: 14) {
            Group {
                if case .app(let app) = target {
                    Image(nsImage: app.icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
                }
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(target.name).font(.title2.weight(.semibold))
                Text(subtitle(for: target))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !model.leftovers.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formattedBytes(model.leftovers.reduce(0) { $0 + ($1.size ?? 0) }))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text("\(model.leftovers.count) items found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func subtitle(for target: UninstallModel.Target) -> String {
        switch target {
        case .app(let app):
            return [app.version.map { "Version \($0)" }, app.bundleID].compactMap(\.self).joined(separator: "  ·  ")
        case .removed(_, let identity):
            return "Already removed  ·  \(identity.bundleID)"
        }
    }
}

private struct AppRow: View {
    let app: AppBundle
    let size: Int64?

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: app.icon).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).lineLimit(1)
                Text(size.map { formattedBytes($0) } ?? "Measuring…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }
}

/// Found files in a native table: tick, name, where, size — sortable by
/// size, the column people actually sort by.
struct LeftoverTable: View {
    let items: [Leftover]
    @Binding var checked: Set<String>

    var body: some View {
        Table(items) {
            TableColumn("") { item in
                Toggle("", isOn: Binding(
                    get: { checked.contains(item.id) },
                    set: { on in if on { checked.insert(item.id) } else { checked.remove(item.id) } }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
            }
            .width(22)

            TableColumn("Name") { item in
                HStack(spacing: 7) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    if item.strength == .related {
                        ToolTag(text: "Maybe", color: .orange)
                            .help("The name is close, not certain. Check before removing.")
                    }
                    if item.needsAdmin {
                        ToolTag(text: "System", color: .purple)
                            .help("Removing it needs your password.")
                    }
                }
                .contextMenu {
                    Button("Show in Finder") { revealInFinder(item.url) }
                }
            }
            .width(min: 200, ideal: 280)

            TableColumn("Location") { item in
                Text(item.displayFolder)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(item.url.path)
            }
            .width(min: 140, ideal: 220)

            TableColumn("Size") { item in
                Text(formattedBytes(item.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 80, max: 100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
}

// MARK: - Leftover files of apps already gone

final class OrphanModel: ObservableObject {
    @Published private(set) var groups: [OrphanScanner.Group] = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var isRemoving = false
    @Published var checked: Set<String> = []
    @Published var message: String?

    var selectedItems: [Leftover] {
        groups.flatMap(\.items).filter { checked.contains($0.id) }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let groups = OrphanScanner.scan(installed: InstalledApps.allBundleIDs())
            DispatchQueue.main.async { [weak self] in
                self?.groups = groups
                self?.checked = []
                self?.isScanning = false
                self?.hasScanned = true
            }
        }
    }

    func toggle(_ group: OrphanScanner.Group) {
        let ids = Set(group.items.map(\.id))
        if ids.isSubset(of: checked) { checked.subtract(ids) } else { checked.formUnion(ids) }
    }

    func removeChecked() {
        let chosen = selectedItems
        guard !chosen.isEmpty, !isRemoving else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move \(chosen.count) item\(chosen.count == 1 ? "" : "s") to the Trash?"
        alert.informativeText = "They were left by apps that are no longer installed. You can put "
            + "them back from the Trash until it is emptied."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        ToolsAlert.confirm(alert) { [weak self] confirmed in
            guard confirmed else { return }
            self?.perform(chosen)
        }
    }

    private func perform(_ chosen: [Leftover]) {
        isRemoving = true
        AppRemover.remove(chosen, bundleID: nil) { [weak self] report in
            guard let self else { return }
            isRemoving = false
            let removed = Set(report.removed.map(\.path))
            groups = groups.compactMap { group in
                var group = group
                group.items.removeAll { removed.contains($0.url.path) }
                return group.items.isEmpty ? nil : group
            }
            checked.subtract(removed)
            message = "Moved \(report.removed.count) item\(report.removed.count == 1 ? "" : "s") "
                + "(\(formattedBytes(report.freedBytes))) to the Trash."
                + (report.failed.isEmpty ? "" : " \(report.failed.count) could not be moved.")
        }
    }
}

struct OrphanView: View {
    @ObservedObject var model: OrphanModel

    var body: some View {
        VStack(spacing: 0) {
            content
            if model.hasScanned, !model.groups.isEmpty {
                ToolActionBar {
                    ToolMessage(text: model.message)
                } trailing: {
                    Text("\(model.checked.count) selected · "
                        + formattedBytes(model.selectedItems.reduce(0) { $0 + ($1.size ?? 0) }))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if model.isRemoving { ProgressView().controlSize(.small) }
                    Button("Move to Trash", role: .destructive) { model.removeChecked() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(model.checked.isEmpty || model.isRemoving)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.scan()
                } label: {
                    Label(model.hasScanned ? "Scan Again" : "Scan", systemImage: "magnifyingglass")
                }
                .disabled(model.isScanning)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning {
            ToolProgress(text: "Looking through Library…")
        } else if !model.hasScanned {
            ContentUnavailableView {
                Label("Leftover Files", systemImage: "doc.badge.ellipsis")
            } description: {
                Text("Finds files named after apps that are no longer installed. Only names that "
                    + "say exactly whose they are are listed, never anything an installed app "
                    + "still uses, and nothing is ticked for you.")
            } actions: {
                Button("Scan") { model.scan() }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.groups.isEmpty {
            ContentUnavailableView {
                Label("No Leftovers", systemImage: "checkmark.seal")
            } description: {
                Text(model.message ?? "Nothing here belongs to a removed app.")
            }
        } else {
            Form {
                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            CheckRow(
                                isOn: Binding(
                                    get: { model.checked.contains(item.id) },
                                    set: { on in
                                        if on { model.checked.insert(item.id) } else { model.checked.remove(item.id) }
                                    }
                                ),
                                title: item.url.lastPathComponent,
                                subtitle: item.displayFolder,
                                trailing: formattedBytes(item.size),
                                url: item.url
                            )
                        }
                    } header: {
                        HStack {
                            Text(group.id).textCase(nil)
                            Spacer()
                            Text(formattedBytes(group.totalSize)).monospacedDigit()
                            Button("Select") { model.toggle(group) }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}

/// A ticked row inside a grouped form: checkbox, two lines of text, a figure.
struct CheckRow: View {
    @Binding var isOn: Bool
    let title: String
    let subtitle: String
    let trailing: String
    var note: String? = nil
    var url: URL? = nil

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).lineLimit(1)
                    if let note { ToolTag(text: note, color: .orange) }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(trailing)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .contextMenu {
            if let url { Button("Show in Finder") { revealInFinder(url) } }
        }
    }
}
