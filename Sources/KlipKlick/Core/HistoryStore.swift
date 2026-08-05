import AppKit
import Combine

/// In-memory clipboard history. Nothing here is ever written to disk, so quitting
/// the app or rebooting the machine loses the history by design.
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    var pinned: [ClipboardItem] { items.filter(\.pinned) }
    var unpinned: [ClipboardItem] { items.filter { !$0.pinned } }

    func insert(_ item: ClipboardItem) {
        // A re-copy of something already recorded moves back to the top rather
        // than creating a duplicate row, and keeps its pinned state.
        if let existing = items.firstIndex(where: { $0.fingerprint == item.fingerprint }) {
            let moved = items.remove(at: existing)
            items.insert(moved, at: 0)
            return
        }

        items.insert(item, at: 0)
        applyLimit()
    }

    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned.toggle()
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
    }

    /// The footer's "Clear History" — pinned items are deliberately kept.
    func clearUnpinned() {
        items.removeAll { !$0.pinned }
    }

    /// Storage ▸ "Clear All History", and the daily purge. Removes everything.
    func clearAll() {
        items.removeAll()
    }

    /// Trims to the configured history size, evicting oldest first. Pinned items
    /// are never evicted — the user asked for them explicitly.
    func applyLimit() {
        let limit = Settings.shared.historySize
        var overflow = items.count - limit
        guard overflow > 0 else { return }

        var index = items.count - 1
        while overflow > 0, index >= 0 {
            if !items[index].pinned {
                items.remove(at: index)
                overflow -= 1
            }
            index -= 1
        }
    }
}
