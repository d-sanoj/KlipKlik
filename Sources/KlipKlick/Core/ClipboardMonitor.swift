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
    /// Frontmost app as of the previous tick, for the ignore-list lookback.
    private var previousFrontmost: FrontmostApp?

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
        let frontmost = Self.frontmostApp()
        // Remembered even on ticks with no change, so the next change can look
        // back one interval.
        defer { previousFrontmost = frontmost }

        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        if selfWrittenChangeCounts.remove(current) != nil { return }

        // Ignored apps. The frontmost app is read up to `interval` after the
        // ⌘C, so someone who copies and immediately switches away would
        // otherwise have the copy credited — and recorded — against the app
        // they switched *to*. Checking the previous tick as well means a fast
        // switch drops the item rather than storing it, which is the safe way
        // to be wrong about a password manager.
        let recent = [frontmost, previousFrontmost].compactMap(\.self)
        if recent.contains(where: { Settings.shared.isIgnored($0.bundleID) }) { return }

        guard let item = ClipboardItem.capture(from: pasteboard, sourceApp: frontmost?.name)
        else { return }
        if ProcessInfo.processInfo.environment["KLIPKLICK_DEBUG"] != nil {
            FileHandle.standardError.write(
                "capture #\(current) kind=\(item.kind) title=\(item.title) fp=\(item.fingerprint)\n"
                    .data(using: .utf8)!
            )
        }
        store.insert(item)
    }

    struct FrontmostApp {
        let name: String?
        let bundleID: String?
    }

    /// Who to credit the copy to, and who to check against the ignore list.
    private static func frontmostApp() -> FrontmostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return FrontmostApp(name: app.localizedName, bundleID: app.bundleIdentifier)
    }
}
