import AppKit
import SwiftUI

final class CacheModel: ObservableObject {
    @Published private(set) var items: [CacheItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var isCleaning = false
    @Published var checked: Set<String> = []
    @Published var message: String?

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
            }
        }
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

    func clean() {
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
            self?.perform(chosen)
        }
    }

    private func perform(_ chosen: [CacheItem]) {
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
        }
    }
}

struct CacheView: View {
    @ObservedObject var model: CacheModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        VStack(spacing: 0) {
            ToolsHeader(
                title: "Cache Cleaner",
                detail: "Only what apps rebuild on their own. Cookies, saved logins, Local Storage, "
                    + "IndexedDB, the keychain and password managers are never listed."
            ) {
                Button(model.hasScanned ? "Scan Again" : "Scan") { model.scan() }
                    .disabled(model.isScanning || model.isCleaning)
            }

            if model.isScanning {
                ToolsPlaceholder(symbol: "magnifyingglass", text: "Measuring caches…", busy: true)
            } else if !model.hasScanned {
                ToolsPlaceholder(
                    symbol: "sparkles",
                    text: "Scan to see what can be cleared. Nothing is deleted until you choose."
                )
            } else if model.items.isEmpty {
                ToolsPlaceholder(symbol: "checkmark.circle", text: model.message ?? "Nothing worth clearing.")
            } else {
                list
                footer
            }
        }
    }

    private var list: some View {
        List {
            ForEach(CacheItem.Category.allCases) { category in
                let rows = model.items(in: category)
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { item in row(item) }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(category.title).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text(formattedBytes(rows.reduce(0) { $0 + $1.size }))
                                    .foregroundStyle(.secondary)
                                Button("All") { model.setAll(category, true) }
                                    .buttonStyle(.borderless)
                                Button("None") { model.setAll(category, false) }
                                    .buttonStyle(.borderless)
                            }
                            Text(category.detail)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !settings.cacheCleanerSkipped.isEmpty {
                Section("Never offered") {
                    ForEach(settings.cacheCleanerSkipped, id: \.self) { path in
                        HStack {
                            Text(path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Offer again") {
                                settings.cacheCleanerSkipped.removeAll { $0 == path }
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func row(_ item: CacheItem) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { model.checked.contains(item.id) },
                set: { _ in model.toggle(item) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(item.owner).font(.system(size: 12.5)).lineLimit(1)
                Text(item.note ?? item.url.path.replacingOccurrences(
                    of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(item.note == nil ? .secondary : Color.orange)
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
            Button("Never Offer This Again") { model.skip(item) }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let message = model.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text("\(model.checked.count) selected · \(formattedBytes(model.selectedBytes))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if model.isCleaning { ProgressView().controlSize(.small) }
            Button("Clear Selected") { model.clean() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.checked.isEmpty || model.isCleaning)
        }
        .padding(12)
    }
}
