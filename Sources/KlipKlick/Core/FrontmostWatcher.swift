import AppKit

/// Who is frontmost, tracked by notification rather than by asking.
///
/// `NSWorkspace.frontmostApplication` looks cheap, but the properties worth
/// having off it — `localizedName`, `bundleIdentifier`, `processIdentifier` —
/// each go out to LaunchServices over *synchronous* XPC. Asking on the 0.4 s
/// clipboard tick meant a cross-process round trip 2.5 times a second, forever,
/// for a value that changes a few dozen times an hour.
///
/// `didActivateApplicationNotification` carries the `NSRunningApplication`
/// itself, so the properties are read once per switch and kept as plain
/// strings. The clipboard tick then costs one integer comparison.
final class FrontmostWatcher {
    /// Just the two fields anyone here needs, flattened out of
    /// `NSRunningApplication` so nothing later re-reads a live property.
    struct App: Equatable {
        let name: String?
        let bundleID: String?
    }

    /// The app in front right now. Nil while KlipKlick itself is frontmost — a
    /// copy is never credited to us.
    private(set) var current: App?
    /// The app in front before this one.
    private(set) var previous: App?
    /// When the switch to `current` happened, so `previous` can go stale.
    private var switchedAt = Date.distantPast

    private var observer: Any?

    func start() {
        stop()
        current = Self.read(NSWorkspace.shared.frontmostApplication)

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.record(Self.read(app))
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    deinit { stop() }

    private func record(_ app: App?) {
        guard app != current else { return }
        previous = current
        current = app
        switchedAt = Date()
    }

    /// `current`, plus `previous` when the switch is recent enough that a copy
    /// noticed now could have been made before it.
    ///
    /// A copy is spotted up to one poll interval after the ⌘C, so someone who
    /// copies and immediately switches away would otherwise have it credited —
    /// and recorded — against the app they switched *to*. Checking the app they
    /// came from means a fast switch drops the item rather than storing it,
    /// which is the safe way to be wrong about a password manager.
    ///
    /// The window matters: the previous implementation kept exactly one tick of
    /// history, so this reproduces it. Without a bound, an app left hours ago
    /// would go on suppressing copies for the life of the process.
    func recent(within window: TimeInterval) -> [App] {
        var apps = [current].compactMap(\.self)
        if let previous, Date().timeIntervalSince(switchedAt) <= window {
            apps.append(previous)
        }
        return apps
    }

    private static func read(_ app: NSRunningApplication?) -> App? {
        guard let app,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return App(name: app.localizedName, bundleID: app.bundleIdentifier)
    }
}
