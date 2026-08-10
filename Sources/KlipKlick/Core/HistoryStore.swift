import AppKit
import Combine

/// Clipboard history, held in memory and backed by `DiskStore`.
///
/// Items keep their bytes in RAM for `offloadDelay` after being copied — long
/// enough to cover the pastes that follow a copy — then the bytes are written
/// out encrypted and dropped from memory. Metadata stays, so the list still
/// renders and searches without touching the disk.
///
/// Pinned items are an archive that survives quitting; everything else is swap,
/// deleted on quit and at the daily purge.
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    /// How long an item's bytes stay in RAM after it is copied.
    private static let offloadDelay: TimeInterval = 5 * 60

    private let disk = DiskStore.shared
    private var offloadTimer: Timer?

    init() {
        // Pinned items come back as metadata only; their bytes stay on disk
        // until something actually needs them.
        items = disk.loadPinned()

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.offloadIdleItems()
        }
        RunLoop.main.add(timer, forMode: .common)
        offloadTimer = timer
    }

    /// Writes out anything that has been sitting in memory long enough, and frees
    /// the bytes. Only ever drops what the disk confirms it has.
    private func offloadIdleItems() {
        let cutoff = Date().addingTimeInterval(-Self.offloadDelay)
        for index in items.indices where items[index].representations != nil {
            guard items[index].createdAt < cutoff else { continue }
            if disk.offload(items[index]) {
                items[index].representations = nil
            }
        }
    }

    /// Brings an item's bytes back, if they were offloaded. Called just before a
    /// paste, which is the only moment they are actually needed.
    func materialized(_ item: ClipboardItem) -> ClipboardItem {
        guard item.representations == nil else { return item }
        var copy = item
        copy.representations = disk.materialize(item)
        return copy
    }

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

        // Pinning promotes the item from swap to archive, so its bytes have to
        // exist on disk before the index claims they do.
        if items[index].pinned, items[index].representations != nil {
            _ = disk.offload(items[index])
        } else {
            disk.move(items[index], toPinned: items[index].pinned)
        }
        disk.saveIndex(items)
    }

    func remove(_ item: ClipboardItem) {
        disk.delete(item)
        items.removeAll { $0.id == item.id }
        if item.pinned { disk.saveIndex(items) }
    }

    /// The footer's "Clear History" — pinned items are deliberately kept.
    func clearUnpinned() {
        items.removeAll { !$0.pinned }
        disk.clearCache()
    }

    /// Storage ▸ "Clear All History", and the daily purge. Clears the session
    /// and its swap, but leaves the pinned archive alone — pinned items are the
    /// one thing the user asked to keep, and a daily timer should not decide
    /// otherwise.
    func clearAll() {
        items.removeAll { !$0.pinned }
        disk.clearCache()
    }

    /// Drops the pinned archive as well. The only route to this is an explicit,
    /// confirmed action in Settings.
    func clearPinned() {
        items.removeAll(where: \.pinned)
        disk.clearPinned()
    }

    /// Quit: the swap tier goes, the archive stays.
    func endSession() {
        offloadTimer?.invalidate()
        items.removeAll { !$0.pinned }
        disk.clearCache()
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
