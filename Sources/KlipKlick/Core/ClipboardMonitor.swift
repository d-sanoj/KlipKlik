import AppKit

/// Watches `NSPasteboard.general` for new content.
///
/// macOS has no change notification for the pasteboard, so the only route is to
/// poll `changeCount`, which is cheap — it is a counter read, not a data read.
final class ClipboardMonitor {
    private let store: HistoryStore
    private var timer: Timer?
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
    }

    /// Tells the monitor that `changeCount` came from KlipKlick itself.
    func ignoreChangeCount(_ changeCount: Int) {
        selfWrittenChangeCounts.insert(changeCount)
        lastChangeCount = max(lastChangeCount, changeCount)
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        if selfWrittenChangeCounts.remove(current) != nil { return }

        guard let item = ClipboardItem.capture(from: pasteboard, sourceApp: Self.sourceAppName())
        else { return }
        if ProcessInfo.processInfo.environment["KLIPKLICK_DEBUG"] != nil {
            FileHandle.standardError.write(
                "capture #\(current) kind=\(item.kind) title=\(item.title) fp=\(item.fingerprint)\n"
                    .data(using: .utf8)!
            )
        }
        store.insert(item)
    }

    /// Who to credit the copy to. Polling means this is read up to `interval`
    /// after the ⌘C, so a fast app switch can misattribute an item — the name is
    /// informational only, and nothing depends on it being right.
    private static func sourceAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return app.localizedName
    }
}
