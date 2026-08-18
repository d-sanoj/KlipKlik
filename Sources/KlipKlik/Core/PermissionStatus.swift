import AppKit
import Combine

/// Live Accessibility and Screen Recording status for the two windows that
/// display it.
///
/// Deliberately not on a free-running clock. Both answers are synchronous XPC
/// calls into `tccd` — `AXIsProcessTrusted` and `CGPreflightScreenCaptureAccess`
/// — and the previous version subscribed a 1 Hz timer from inside a SwiftUI
/// body. That subscription outlived the window it belonged to (the controllers
/// are retained, and the windows are `isReleasedWhenClosed = false`), so a
/// welcome window closed on first launch went on waking the daemon once a
/// second for the life of the process.
///
/// Both grants are made in System Settings, which means leaving KlipKlik and
/// coming back — so app activation is the real signal, not time. A slow poll
/// runs alongside it for the case where the window sits on a second display and
/// never gets activated again, but only while a window is actually up: an idle
/// KlipKlik polls nothing at all.
final class PermissionStatus: ObservableObject {
    /// One instance, so two open windows cost one query rather than two.
    static let shared = PermissionStatus()

    @Published private(set) var isTrusted: Bool
    @Published private(set) var canRecordScreen: Bool

    /// Backstop for a grant made without ever re-activating KlipKlik.
    private static let pollInterval: TimeInterval = 2

    private var timer: Timer?
    private var observer: Any?
    /// Balanced by `begin()`/`end()`, because both windows can be open at once.
    private var depth = 0

    private init() {
        isTrusted = AccessibilityPermission.isTrusted
        canRecordScreen = TextGrab.isPermitted
    }

    /// Starts watching, until a matching `end()`.
    ///
    /// Driven by the window controllers rather than by SwiftUI's `onAppear` /
    /// `onDisappear`: an `NSWindow` ordering out is a fact the controller
    /// already knows, and the leak this replaces came from inferring it.
    func begin() {
        depth += 1
        guard depth == 1 else { return }
        refresh()

        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() }

        // Accessibility only. `CGPreflightScreenCaptureAccess` costs ~6 ms,
        // almost all of it blocked on `tccd`, and it cannot change its answer
        // within the life of the process — a grant made now still reads as
        // denied until relaunch, which is exactly why `needsRestart` exists in
        // `OnboardingView`. Polling it would be a main-thread stall in exchange
        // for a value that is guaranteed not to have moved.
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refreshAccessibility()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func end() {
        depth = max(0, depth - 1)
        guard depth == 0 else { return }
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Both values. Worth the screen-recording call on the rare events that can
    /// plausibly have changed it — opening a window, or coming back from
    /// System Settings.
    func refresh() {
        refreshAccessibility()
        let record = TextGrab.isPermitted
        if record != canRecordScreen { canRecordScreen = record }
    }

    /// `AXIsProcessTrusted` is sub-microsecond and genuinely does go live the
    /// moment the grant is made, so this is the one worth watching on a clock.
    private func refreshAccessibility() {
        // Assigned only on a real change: publishing an identical value would
        // still push a SwiftUI update through on every tick.
        let trusted = AccessibilityPermission.isTrusted
        if trusted != isTrusted { isTrusted = trusted }
    }
}
