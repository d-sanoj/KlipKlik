import AppKit
import SwiftUI

final class CacheModel: ObservableObject {
    @Published private(set) var items: [CacheItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var isCleaning = false
    @Published var checked: Set<String> = []
    @Published var message: String?
    @Published private(set) var lastScanned: Date?

    var selectedBytes: Int64 {
        items.filter { checked.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func items(in category: CacheItem.Category) -> [CacheItem] {
        items.filter { $0.category == category }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        message = nil
        let context = CacheScanner.Context(
            skipped: Set(Settings.shared.cacheCleanerSkipped),
            running: CacheScanner.runningKeys(
                NSWorkspace.shared.runningApplications.map { ($0.localizedName, $0.bundleIdentifier) }
            )
        )
        DispatchQueue.global(qos: .userInitiated).async {
            let found = CacheScanner.scan(context)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                items = found
                checked = Set(found.filter(\.preselected).map(\.id))
                isScanning = false
                hasScanned = true
                lastScanned = Date()
            }
        }
    }

    /// Scans unless a scan finished in the last couple of minutes — the menu
    /// calls this every time it opens.
    func scanIfStale(maxAge: TimeInterval = 120) {
        guard !isScanning, !isCleaning else { return }
        if let lastScanned, Date().timeIntervalSince(lastScanned) < maxAge { return }
        scan()
    }

    /// What one click in the menu clears: the items ticked by default — never
    /// developer caches, never an app that is open.
    var safeItems: [CacheItem] { items.filter(\.preselected) }
    var safeBytes: Int64 { safeItems.reduce(0) { $0 + $1.size } }

    /// The menu's "Clear Safe Caches": the default selection, confirmed, then
    /// reported, since the menu is gone by the time it finishes.
    func cleanSafe() {
        checked = Set(safeItems.map(\.id))
        clean(announce: true)
    }

    func toggle(_ item: CacheItem) {
        if checked.contains(item.id) { checked.remove(item.id) } else { checked.insert(item.id) }
    }

    func setAll(_ category: CacheItem.Category, _ on: Bool) {
        let ids = Set(items(in: category).map(\.id))
        if on { checked.formUnion(ids) } else { checked.subtract(ids) }
    }

    /// "Never offer this again" — remembered in Settings.
    func skip(_ item: CacheItem) {
        if !Settings.shared.cacheCleanerSkipped.contains(item.url.path) {
            Settings.shared.cacheCleanerSkipped.append(item.url.path)
        }
        items.removeAll { $0.id == item.id }
        checked.remove(item.id)
    }

    func clean(announce: Bool = false) {
        let chosen = items.filter { checked.contains($0.id) }
        guard !chosen.isEmpty, !isCleaning else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear \(formattedBytes(selectedBytes)) of caches?"
        alert.informativeText = "\(chosen.count) item\(chosen.count == 1 ? "" : "s") will be emptied. "
            + "This is permanent — moving caches to the Trash would not free the space — but every "
            + "one of them is rebuilt by its app when needed. Logins, cookies and app data are not "
            + "touched."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        ToolsAlert.confirm(alert) { [weak self] confirmed in
            guard confirmed else { return }
            self?.perform(chosen, announce: announce)
        }
    }

    private func perform(_ chosen: [CacheItem], announce: Bool) {
        isCleaning = true
        CacheScanner.clean(chosen) { [weak self] report in
            guard let self else { return }
            isCleaning = false
            message = "Freed \(formattedBytes(report.freedBytes)) from \(report.cleaned) "
                + "item\(report.cleaned == 1 ? "" : "s")."
                + (report.failures.isEmpty ? ""
                    : " Some files in \(report.failures.prefix(3).joined(separator: ", ")) were in use and stayed.")
            let cleanedIDs = Set(chosen.map(\.id))
            items.removeAll { cleanedIDs.contains($0.id) }
            checked.subtract(cleanedIDs)
            if announce, let message { ToolsAlert.inform("Caches Cleared", message) }
        }
    }
}

struct CacheView: View {
    @ObservedObject var model: CacheModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        VStack(spacing: 0) {
            content.fillsToolArea()
            if model.hasScanned, !model.items.isEmpty {
                ToolActionBar {
                    ToolMessage(text: model.message)
                } trailing: {
                    if model.isCleaning { ProgressView().controlSize(.small) }
                    Button("Clear \(formattedBytes(model.selectedBytes))") { model.clean() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.checked.isEmpty || model.isCleaning)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.scan()
                } label: {
                    Label(model.hasScanned ? "Scan Again" : "Scan", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning || model.isCleaning)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning {
            ToolProgress(text: "Measuring caches…")
        } else if !model.hasScanned {
            ContentUnavailableView {
                Label("Cache Cleaner", systemImage: "sparkles")
            } description: {
                Text("Clears only what apps rebuild on their own — including the download caches "
                    + "of ChatGPT, Claude and other AI and web apps. Cookies, saved logins, local "
                    + "app data, the keychain and password managers are never touched.")
            } actions: {
                Button("Scan") { model.scan() }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.items.isEmpty {
            ContentUnavailableView {
                Label("All Clean", systemImage: "checkmark.seal")
            } description: {
                Text(model.message ?? "Nothing is worth clearing right now.")
            }
        } else {
            Form {
                Section {
                    CacheSummary(model: model)
                }

                ForEach(CacheItem.Category.allCases) { category in
                    let rows = model.items(in: category)
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { item in
                                CheckRow(
                                    isOn: Binding(
                                        get: { model.checked.contains(item.id) },
                                        set: { _ in model.toggle(item) }
                                    ),
                                    title: item.owner,
                                    subtitle: item.url.path.replacingOccurrences(
                                        of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"),
                                    trailing: formattedBytes(item.size),
                                    note: item.note,
                                    url: item.url
                                )
                                .contextMenu {
                                    Button("Show in Finder") { revealInFinder(item.url) }
                                    Button("Never Offer This Again") { model.skip(item) }
                                }
                            }
                        } header: {
                            HStack {
                                Circle().fill(category.color).frame(width: 8, height: 8)
                                Text(category.title)
                                Spacer()
                                Text(formattedBytes(rows.reduce(0) { $0 + $1.size })).monospacedDigit()
                                Menu {
                                    Button("Select All") { model.setAll(category, true) }
                                    Button("Select None") { model.setAll(category, false) }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                            }
                        } footer: {
                            Text(category.detail).foregroundStyle(.secondary)
                        }
                    }
                }

                if !settings.cacheCleanerSkipped.isEmpty {
                    Section("Never offered") {
                        ForEach(settings.cacheCleanerSkipped, id: \.self) { path in
                            LabeledContent {
                                Button("Offer Again") {
                                    settings.cacheCleanerSkipped.removeAll { $0 == path }
                                }
                                .buttonStyle(.borderless)
                            } label: {
                                Text(path).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}

/// How much was found, as a bar split by category — the way Storage in
/// System Settings shows a disk.
private struct CacheSummary: View {
    @ObservedObject var model: CacheModel

    private var total: Int64 { model.items.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(formattedBytes(model.selectedBytes))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("selected of \(formattedBytes(total)) found")
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(CacheItem.Category.allCases) { category in
                        let size = model.items(in: category).reduce(0) { $0 + $1.size }
                        if size > 0 {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(category.color.gradient)
                                .frame(width: max(4, geometry.size.width * CGFloat(size) / CGFloat(max(total, 1))))
                        }
                    }
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            HStack(spacing: 14) {
                ForEach(CacheItem.Category.allCases) { category in
                    let size = model.items(in: category).reduce(0) { $0 + $1.size }
                    if size > 0 {
                        HStack(spacing: 5) {
                            Circle().fill(category.color).frame(width: 7, height: 7)
                            Text(category.title).foregroundStyle(.secondary)
                            Text(formattedBytes(size)).monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

extension CacheItem.Category {
    var color: Color {
        switch self {
        case .appCaches: return .blue
        case .webCaches: return .purple
        case .logs: return .orange
        case .developer: return .teal
        }
    }
}
