import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

/// Scrolling screenshots: one tall picture of everything a view scrolls
/// through — a whole web page, a long chat, a document.
///
/// You drag a box over the scrolling part of a window. KlipKlik then scrolls
/// it a little over half a screen at a time, waits for it to settle, takes a
/// shot, and works out from the pixels how far the content moved (see
/// `ScrollStitcher`). It stops at the end of the content, when you press Done
/// or Esc, or at a size limit, and the result is copied and shown.
///
/// It works on anything that scrolls, signed-in pages included, because it
/// captures what is on screen rather than reloading the page. It needs Screen
/// Recording to see the pixels, and Accessibility to send the scrolls.
final class ScrollCapture {
    static let shared = ScrollCapture()

    private let selector = RegionSelector()
    private let hud = ScrollCaptureHUD()
    private let outline = SelectionOutline()
    private var escapeKey: CarbonHotKey?
    private var isRunning = false
    private var stopRequested = false
    private var cancelled = false

    /// Pixels; past this the picture gets unwieldy to paste anywhere.
    private static let maximumHeight = 30_000
    private static let maximumShots = 200

    private init() {
        hud.onDone = { [weak self] in self?.stopRequested = true }
        hud.onCancel = { [weak self] in
            self?.cancelled = true
            self?.stopRequested = true
        }
    }

    func start() {
        guard !isRunning else { return }
        guard TextGrab.isPermitted else {
            if !TextGrab.promptIfNeverAsked() { explainMissing("Screen Recording") }
            return
        }
        guard AccessibilityPermission.isTrusted else {
            explainMissing("Accessibility")
            return
        }
        selector.begin { [weak self] rect in
            guard let self, let rect else { return }
            capture(rect)
        }
    }

    /// Captures `rect` (Core Graphics screen coordinates) without asking for
    /// a drag first — `start()` after the drag, and scripted runs.
    func capture(_ rect: CGRect) {
        guard !isRunning else { return }
        guard rect.height >= 80, rect.width >= 80 else {
            ToolsAlert.inform("Area Too Small", "Drag over the part of the window that scrolls.")
            return
        }
        Task { @MainActor in await self.run(rect) }
    }

    // MARK: The capture loop

    @MainActor
    private func run(_ rect: CGRect) async {
        isRunning = true
        stopRequested = false
        cancelled = false
        defer { isRunning = false }

        guard let shooter = await Shooter(rect: rect) else {
            ToolsAlert.inform("Couldn't Capture the Screen",
                              "macOS refused the screenshot. Check Screen Recording in System Settings.")
            return
        }

        outline.show(around: rect)
        hud.show(near: rect)
        escapeKey = CarbonHotKey(keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in
            self?.cancelled = true
            self?.stopRequested = true
        }

        // The scroll goes to whatever is under the pointer, so the pointer
        // sits in the middle of the box until the end, then goes back.
        let savedPointer = CGEvent(source: nil)?.location
        let center = CGPoint(x: rect.midX, y: rect.midY)
        CGWarpMouseCursorPosition(center)
        CGAssociateMouseAndMouseCursorPosition(1)

        // Choosing the area made KlipKlik the active app, and an app that is
        // not in front does not take scrolls — the page stood still and the
        // capture gave up at once. Hand the front back to the window under
        // the area, and let it settle, before the first scroll.
        if let owner = Self.appOwningWindow(at: center) {
            owner.activate()
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        // A real move, so the app under the pointer knows where it is.
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: center,
                mouseButton: .left)?.post(tap: .cghidEventTap)

        let image = await capture(with: shooter, at: center)

        escapeKey = nil
        outline.hide()
        hud.hide()
        if let savedPointer { CGWarpMouseCursorPosition(savedPointer) }

        guard !cancelled else { return }
        guard let image else {
            ToolsAlert.inform("Nothing Scrolled",
                              "The area didn't scroll. Drag over the part of the window that moves "
                                + "when you scroll it.")
            return
        }
        // Pixels per point of the capture: 2 on a Retina screen. Carried into
        // every copy and file so the picture keeps its true size and sharpness.
        let scale = CGFloat(image.width) / rect.width
        Self.deliver(image, scale: scale)
    }

    /// Does what Settings asks for with a finished capture — by default just
    /// copies it, with a brief note to say so.
    private static func deliver(_ image: CGImage, scale: CGFloat) {
        let size = "\(image.width.formatted()) × \(image.height.formatted()) px"
        switch Settings.shared.scrollCaptureAction {
        case .copy:
            ScreenshotOutput.copy(image, scale: scale) { copied in
                CaptureToast.show(copied ? "Copied to Clipboard" : "Couldn't Copy", detail: size)
            }
        case .save:
            ScreenshotOutput.saveToDesktop(image, scale: scale) { url in
                CaptureToast.show(url == nil ? "Couldn't Save" : "Saved to Desktop",
                                  detail: url?.lastPathComponent ?? size)
            }
        case .copyAndSave:
            ScreenshotOutput.copy(image, scale: scale) { _ in
                ScreenshotOutput.saveToDesktop(image, scale: scale) { url in
                    CaptureToast.show(url == nil ? "Copied — Couldn't Save" : "Copied and Saved to Desktop",
                                      detail: size)
                }
            }
        case .window:
            ScrollResultWindow.show(image, scale: scale)
        }
    }

    @MainActor
    private func capture(with shooter: Shooter, at point: CGPoint) async -> CGImage? {
        guard let first = await shooter.shot(),
              var previous = ScrollStitcher.signatures(of: first)
        else { return nil }

        let builder = ScrollStitcher.Builder(first: first)
        let scale = Double(first.height) / shooter.rect.height
        // A little over half of what is showing, so consecutive shots share
        // plenty to match on. Re-measured once sticky bars are known.
        var stepPoints = shooter.rect.height * 0.55
        var shots = 1
        var misses = 0

        while !stopRequested, shots < Self.maximumShots, builder.height < Self.maximumHeight {
            Scroller.scroll(by: stepPoints, at: point)
            guard let (next, signature) = await settledShot(shooter, after: previous) else { break }
            if stopRequested { break }

            guard let step = ScrollStitcher.step(
                from: previous, to: signature, expected: Int(stepPoints * scale)
            ) else {
                // Something changed besides the scroll — a popover, an ad
                // animating. One more try before giving up.
                misses += 1
                if misses >= 2 { break }
                continue
            }
            misses = 0
            if step.shift == 0 { break }

            builder.add(next, step: step)
            previous = signature
            shots += 1
            hud.update(shots: shots, height: builder.height)

            let moving = Double(first.height - step.header - step.footer) / scale
            stepPoints = max(60, moving * 0.55)
        }

        return shots > 1 ? builder.finish() : nil
    }

    /// Waits for the view to stop moving after a scroll — smooth scrolling
    /// takes a few frames to land — and returns the settled shot.
    @MainActor
    private func settledShot(_ shooter: Shooter, after previous: ScrollStitcher.Signatures)
        async -> (CGImage, ScrollStitcher.Signatures)? {
        try? await Task.sleep(nanoseconds: 220_000_000)
        guard var image = await shooter.shot(), var signature = ScrollStitcher.signatures(of: image) else {
            return nil
        }
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let again = await shooter.shot(), let againSignature = ScrollStitcher.signatures(of: again)
            else { return nil }
            if ScrollStitcher.isSettled(signature, againSignature) { return (again, againSignature) }
            image = again
            signature = againSignature
        }
        return (image, signature)
    }

    /// The app whose window is frontmost at `point` (top-left screen
    /// coordinates), leaving out KlipKlik's own.
    static func appOwningWindow(at point: CGPoint) -> NSRunningApplication? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        // Front to back; the first ordinary window under the point is it.
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.contains(point)
            else { continue }
            return NSRunningApplication(processIdentifier: pid)
        }
        return nil
    }

    private func explainMissing(_ permission: String) {
        let alert = NSAlert()
        alert.messageText = "Scrolling screenshots need \(permission)"
        alert.informativeText = permission == "Accessibility"
            ? "KlipKlik scrolls the window for you, which needs Accessibility."
            : "KlipKlik reads the screen's pixels, which needs Screen Recording. Grant it, then reopen KlipKlik."
        alert.addButton(withTitle: "Open Settings…")
        alert.addButton(withTitle: "Later")
        guard FloatingAlert.run(alert) == .alertFirstButtonReturn else { return }
        permission == "Accessibility" ? AccessibilityPermission.allow() : TextGrab.openSettingsPane()
    }
}

/// Takes shots of one area of one display, leaving KlipKlik's own windows —
/// the outline and the control panel — out of the picture.
private struct Shooter {
    let rect: CGRect
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration

    init?(rect: CGRect) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.frame.intersects(rect) }) ?? content.displays.first
        else { return nil }
        let ownApp = content.applications.filter { $0.processID == getpid() }
        filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])

        let scale = NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == display.displayID
        }?.backingScaleFactor ?? 2
        configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: rect.minX - display.frame.minX, y: rect.minY - display.frame.minY,
            width: rect.width, height: rect.height
        )
        configuration.width = Int(rect.width * scale)
        configuration.height = Int(rect.height * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        self.rect = rect
    }

    func shot() async -> CGImage? {
        try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

/// Sends scroll-wheel events to whatever is under `point`.
private enum Scroller {
    /// Scrolls the content down by about `points`, in a few small events —
    /// one big jump is ignored or clamped by some apps.
    static func scroll(by points: Double, at point: CGPoint) {
        let pieces = 6
        let each = Int32(-(points / Double(pieces)).rounded())
        for _ in 0..<pieces {
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: each, wheel2: 0, wheel3: 0
            ) else { continue }
            event.location = point
            event.post(tap: .cghidEventTap)
            usleep(6_000)
        }
    }
}

// MARK: - On-screen pieces

/// A thin outline around the area being captured. It ignores the pointer, so
/// the scroll reaches the window underneath, and it is left out of the shots.
private final class SelectionOutline {
    private var window: NSWindow?

    func show(around rect: CGRect) {
        let frame = Self.appKitFrame(for: rect).insetBy(dx: -3, dy: -3)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 4
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }

    /// Core Graphics (top-left origin) → AppKit (bottom-left origin).
    static func appKitFrame(for rect: CGRect) -> NSRect {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? rect.maxY
        return NSRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
}

