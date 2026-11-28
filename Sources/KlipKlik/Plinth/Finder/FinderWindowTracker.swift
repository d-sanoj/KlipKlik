import AppKit
import ApplicationServices

/// Follows Finder's front window, so the bar can sit under it.
///
/// The frame itself always comes from the window server
/// (`CGWindowListCopyWindowInfo`), which needs no permission. What changes is
/// how promptly a move is noticed:
///
/// * with Accessibility (which KlipKlik already asks for), Finder's own
///   moved / resized / focus-changed notifications drive it, event by event;
/// * a mouse drag anywhere — a window being dragged by its title bar — is
///   followed through a global mouse monitor, which needs no permission;
/// * a slow timer is the safety net for keyboard moves and closed windows.
///
/// All of it runs only while Finder is frontmost and the bar is on.
final class FinderWindowTracker {
    static let finderBundleID = "com.apple.finder"

    /// The front Finder window in Quartz coordinates, or nil when it has none.
    var onChange: ((CGRect?) -> Void)?
    private(set) var frame: CGRect?

    private var finderPID: pid_t?
    private var observer: AXObserver?
    private var monitors: [Any] = []
    private var timer: Timer?
    private var lastDragRefresh = Date.distantPast

    var isRunning: Bool { finderPID != nil }

    func start() {
        guard !isRunning,
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: Self.finderBundleID).first
        else { refresh(); return }
        finderPID = finder.processIdentifier

        if AXIsProcessTrusted() { attachObserver(to: finder.processIdentifier) }

        // Drags at display rate, at most 60 times a second.
        let drag = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(lastDragRefresh) >= 1.0 / 60 else { return }
            lastDragRefresh = now
            refresh()
        }
        let release = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.refresh()
        }
        monitors = [drag, release].compactMap { $0 }

        let interval: TimeInterval = observer == nil ? 0.25 : 1
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        refresh()
    }

    func stop() {
        detachObserver()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        timer?.invalidate()
        timer = nil
        finderPID = nil
        if frame != nil {
            frame = nil
            onChange?(nil)
        }
    }

    deinit { stop() }

    /// Re-reads the front window; reports only when it moved, resized,
    /// appeared or went away.
    func refresh() {
        let current = finderPID.flatMap(Self.frontWindowFrame(pid:))
        guard current != frame else { return }
        frame = current
        onChange?(current)
    }

    /// The first ordinary on-screen window Finder owns. The list is front to
    /// back, so that is the one in front. Small windows — Get Info, progress
    /// sheets — are passed over: a command bar under them makes no sense.
    static func frontWindowFrame(pid: pid_t) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 300, rect.height >= 200
            else { continue }
            return rect
        }
        return nil
    }

    // MARK: Accessibility notifications

    private static let notifications = [
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXWindowCreatedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification
    ]

    private func attachObserver(to pid: pid_t) {
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            Unmanaged<FinderWindowTracker>.fromOpaque(context).takeUnretainedValue().refresh()
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }

        let application = AXUIElementCreateApplication(pid)
        // Unretained: `stop()` — called from `deinit` at the latest — removes
        // the observer before this object can go away.
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(created, application, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
    }

    private func detachObserver() {
        guard let observer, let pid = finderPID else { return }
        let application = AXUIElementCreateApplication(pid)
        for name in Self.notifications {
            AXObserverRemoveNotification(observer, application, name as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }
}
