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

    /// Items whose write is in flight, so a later sweep does not start a second
    /// one for the same item.
    private var offloading: Set<UUID> = []

    init() {
        // Pinned items come back as metadata only; their bytes stay on disk
        // until something actually needs them.
        items = disk.loadPinned()
    }

    /// Runs only while something is actually waiting to be written.
    ///
    /// This used to tick every 60 seconds for the life of the process, almost
    /// always finding nothing: history is emptied on quit and at the purge, so
    /// the common state is an app with no bytes left to offload at all.
    private func startOffloadTimerIfNeeded() {
        guard offloadTimer == nil,
              items.contains(where: { $0.representations != nil })
        else { return }

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.offloadIdleItems()
        }
        RunLoop.main.add(timer, forMode: .common)
        offloadTimer = timer
    }

    private func stopOffloadTimerIfIdle() {
        guard offloading.isEmpty,
              !items.contains(where: { $0.representations != nil })
        else { return }
        offloadTimer?.invalidate()
        offloadTimer = nil
    }

    /// Writes out anything that has been sitting in memory long enough, and frees
    /// the bytes. Only ever drops what the disk confirms it has.
    private func offloadIdleItems() {
        let cutoff = Date().addingTimeInterval(-Self.offloadDelay)

        for item in items where item.representations != nil {
            guard item.createdAt < cutoff, !offloading.contains(item.id) else { continue }
            offloading.insert(item.id)

            // Encrypting and writing megabytes has no business on the thread
            // that draws the popup; the bytes are dropped once the disk confirms
            // it has them, exactly as before.
            disk.offload(item) { [weak self] written in
                guard let self else { return }
                offloading.remove(item.id)
                defer { stopOffloadTimerIfIdle() }

                guard written, let index = items.firstIndex(where: { $0.id == item.id })
                else { return }
                items[index].representations = nil
            }
        }

        stopOffloadTimerIfIdle()
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
        compactImageBytes(of: item)
        startOffloadTimerIfNeeded()
    }

    /// Shrinks an item's image bytes just after capture.
    ///
    /// Off the main thread deliberately: transcoding a full-screen TIFF takes
    /// ~85 ms, which on the capture path would be a visible hitch on every
    /// image copy. The item goes into the list immediately as captured, and its
    /// bytes are swapped for the smaller ones a moment later.
    private func compactImageBytes(of item: ClipboardItem) {
        guard let representations = item.representations else { return }
        let id = item.id

        let debug = ProcessInfo.processInfo.environment["KLIPKLIK_DEBUG"] != nil
        let before = debug
            ? representations.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
            : 0

        Self.compactionQueue.async {
            guard let result = ClipboardItem.compacting(representations) else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let index = items.firstIndex(where: { $0.id == id }),
                      // Offloaded, cleared or re-captured while we were working:
                      // whatever is there now is not what we compacted.
                      items[index].representations != nil
                else { return }
                items[index].representations = result.bags
                items[index].restoresTIFF = result.restoresTIFF

                if debug {
                    let after = result.bags.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
                    let line = String(
                        format: "compact %@ %.1f KB -> %.1f KB\n",
                        id.uuidString.prefix(8) as CVarArg,
                        Double(before) / 1024, Double(after) / 1024
                    )
                    FileHandle.standardError.write(line.data(using: .utf8)!)
                }
            }
        }
    }

    private static let compactionQueue = DispatchQueue(
        label: "com.sanoj.KlipKlik.compaction", qos: .utility
    )

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
