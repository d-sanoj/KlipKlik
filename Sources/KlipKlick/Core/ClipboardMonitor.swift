import AppKit

/// Watches `NSPasteboard.general` for new content.
///
/// macOS has no change notification for the pasteboard, so the only route is to
/// poll `changeCount`, which is cheap — it is a counter read, not a data read.
///
/// Nothing else runs on the tick. Who is frontmost used to be read here too,
/// which quietly made each tick a synchronous LaunchServices round trip;
/// `FrontmostWatcher` now tracks that by notification instead.
final class ClipboardMonitor {
    private let store: HistoryStore
    private let frontmost = FrontmostWatcher()
    private var timer: Timer?
    /// Kept so the ignore-list lookback can be bounded to one tick.
    private var interval: TimeInterval = 0.4
    private var lastChangeCount: Int
    /// Change counts produced by our own writes, so restoring an item doesn't
    /// bounce straight back into the history as a "new" copy.
    private var selfWrittenChangeCounts: Set<Int> = []

    init(store: HistoryStore) {
        self.store = store
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start(interval: TimeInterval = 0.4) {
        timer?.invalidate()
        self.interval = interval
        frontmost.start()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // .common so polling continues while a menu or panel tracking loop is up.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        frontmost.stop()
    }

    /// Tells the monitor that `changeCount` came from KlipKlick itself.
    func ignoreChangeCount(_ changeCount: Int) {
        selfWrittenChangeCounts.insert(changeCount)
        lastChangeCount = max(lastChangeCount, changeCount)
    }

    private func poll() {
        // The whole tick, on the overwhelmingly common path: read a counter,
        // compare it, return. Everything below runs only on an actual copy.
        let pasteboard = NSPasteboard.general
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        if selfWrittenChangeCounts.remove(current) != nil { return }

        // Ignored apps, checked against both the app in front and the one just
        // switched away from — see `FrontmostWatcher.recent(within:)`.
        let recent = frontmost.recent(within: interval)
        if recent.contains(where: { Settings.shared.isIgnored($0.bundleID) }) { return }

        guard let item = ClipboardItem.capture(from: pasteboard, sourceApp: frontmost.current?.name)
        else { return }
        if ProcessInfo.processInfo.environment["KLIPKLICK_DEBUG"] != nil {
            let line = "capture #\(current) kind=\(item.kind) title=\(item.title)"
                + " fp=\(item.fingerprint) from=\(item.sourceApp ?? "—")"
                + " recent=\(recent.map { $0.bundleID ?? "—" })\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        store.insert(item)
    }
}
