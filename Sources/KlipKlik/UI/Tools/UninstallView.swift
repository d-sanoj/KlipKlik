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

struct UninstallView: View {
    @ObservedObject var model: UninstallModel
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
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(6)
            }
        }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search apps", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                Button {
                    model.reloadApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload the list")
            }
            .padding(10)

            if model.isLoadingApps {
                ToolsPlaceholder(symbol: "app", text: "Looking for apps…", busy: true)
            } else {
                List(model.filteredApps) { app in
                    AppRow(app: app, size: model.appSizes[app.id],
                           isSelected: model.target == .app(app))
                        .contentShape(Rectangle())
                        .onTapGesture { model.select(app) }
                }
                .listStyle(.plain)
            }

            Text("Or drop an app here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let target = model.target {
            VStack(spacing: 0) {
                ToolsHeader(
                    title: target.name,
                    detail: headerDetail(target)
                )
                if model.isScanning {
                    ToolsPlaceholder(symbol: "magnifyingglass", text: "Looking for its files…", busy: true)
                } else if model.leftovers.isEmpty {
                    ToolsPlaceholder(symbol: "checkmark.circle", text: model.message ?? "Nothing left behind.")
                } else {
                    leftoverList
                    footer
                }
            }
        } else {
            VStack {
                ToolsHeader(
                    title: "Uninstall Cleaner",
                    detail: "Pick an app to see everything it keeps on this Mac — support files, "
                        + "caches, preferences, containers, login helpers and installer receipts — "
                        + "and remove it all together. Everything goes to the Trash."
                )
                ToolsPlaceholder(
                    symbol: "trash",
                    text: model.message ?? "Choose an app on the left, or drop one here."
                )
            }
        }
    }

    private func headerDetail(_ target: UninstallModel.Target) -> String {
        switch target {
        case .app(let app):
            return [app.bundleID, app.version.map { "Version \($0)" }]
                .compactMap(\.self).joined(separator: " · ")
        case .removed(_, let identity):
            return "\(identity.bundleID) · The app has been removed; these are the files it left."
        }
    }

    private var leftoverList: some View {
        List {
            ForEach(model.leftovers) { item in
                LeftoverRow(item: item, isChecked: model.checked.contains(item.id)) {
                    model.toggle(item)
                }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let message = model.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text("\(model.checked.count) selected · \(formattedBytes(model.selectedBytes))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if model.isRemoving {
                ProgressView().controlSize(.small)
            }
            Button(model.leftovers.contains { $0.kind == .appBundle && model.checked.contains($0.id) }
                   ? "Uninstall" : "Move to Trash") {
                model.removeChecked()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.checked.isEmpty || model.isRemoving)
        }
        .padding(12)
    }
}

private struct AppRow: View {
    let app: AppBundle
    let size: Int64?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: app.icon).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.system(size: 12.5)).lineLimit(1)
                Text(formattedBytes(size))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5).fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        )
    }
}

/// One found item, with its tick box, where it is and how big.
struct LeftoverRow: View {
    let item: Leftover
    let isChecked: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { isChecked }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.url.lastPathComponent).font(.system(size: 12.5)).lineLimit(1)
                    if item.strength == .related {
                        badge("Maybe", help: "The name is close, not certain. Check before removing.")
                    }
                    if item.needsAdmin {
                        badge("System", help: "Removing it needs your password.")
                    }
                }
                Text(item.displayFolder)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(formattedBytes(item.size))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Show in Finder") { revealInFinder(item.url) }
        }
    }

    private func badge(_ text: String, help: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.18)))
            .help(help)
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
            ToolsHeader(
                title: "Leftover Files",
                detail: "Files named after apps that are no longer installed. Only names that say "
                    + "exactly whose they are (com.vendor.app) are listed, and nothing from a vendor "
                    + "that still has an app here. None is ticked — check each one."
            ) {
                Button(model.hasScanned ? "Scan Again" : "Scan") { model.scan() }
                    .disabled(model.isScanning)
            }

            if model.isScanning {
                ToolsPlaceholder(symbol: "magnifyingglass", text: "Looking through Library…", busy: true)
            } else if !model.hasScanned {
                ToolsPlaceholder(symbol: "doc.badge.ellipsis", text: "Scan to look for leftovers.")
            } else if model.groups.isEmpty {
                ToolsPlaceholder(symbol: "checkmark.circle",
                                 text: model.message ?? "No leftovers from removed apps.")
            } else {
                List {
                    ForEach(model.groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                LeftoverRow(item: item, isChecked: model.checked.contains(item.id)) {
                                    if model.checked.contains(item.id) {
                                        model.checked.remove(item.id)
                                    } else {
                                        model.checked.insert(item.id)
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text(group.id).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text(formattedBytes(group.totalSize)).foregroundStyle(.secondary)
                                Button("Select") { model.toggle(group) }
                                    .buttonStyle(.borderless)
                                    .font(.system(size: 11))
                            }
                        }
                    }
                }
                .listStyle(.inset)

                HStack {
                    if let message = model.message {
                        Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(model.checked.count) selected · "
                        + formattedBytes(model.selectedItems.reduce(0) { $0 + ($1.size ?? 0) }))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if model.isRemoving { ProgressView().controlSize(.small) }
                    Button("Move to Trash") { model.removeChecked() }
                        .disabled(model.checked.isEmpty || model.isRemoving)
                }
                .padding(12)
            }
        }
    }
}
