import AppKit

/// Dims the screens and lets the user drag out a rectangle.
///
/// Not `screencapture -i`: that draws a crosshair without dimming, and gives no
/// say over what happens on cancel. An overlay of our own also keeps the
/// selection rectangle on screen while the drag is live, which is the whole
/// point of dimming — you can see what you are about to grab.
final class RegionSelector {
    private var windows: [NSWindow] = []
    private var completion: ((CGRect?) -> Void)?

    /// Calls back with the chosen rectangle in Core Graphics screen coordinates
    /// — top-left origin, y downwards — or nil if the user cancelled.
    func begin(completion: @escaping (CGRect?) -> Void) {
        guard windows.isEmpty else { return }
        self.completion = completion

        for screen in NSScreen.screens {
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = OverlayView(
                onFinish: { [weak self] rect in self?.finish(rect) },
                onCancel: { [weak self] in self?.finish(nil) }
            )
            window.orderFrontRegardless()
            windows.append(window)
        }

        // Key so Escape reaches us; activating brings every overlay forward.
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
    }

    private func finish(_ rectInWindow: CGRect?) {
        let handler = completion
        completion = nil

        // Tear the overlays down before the caller captures, or the dim ends up
        // in the screenshot.
        for window in windows { window.orderOut(nil) }
        windows.removeAll()

        handler?(rectInWindow)
    }
}

/// Borderless windows refuse key by default, which would swallow Escape.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class OverlayView: NSView {
    private let onFinish: (CGRect?) -> Void
    private let onCancel: () -> Void

    private var anchor: NSPoint?
    private var current: NSPoint?

    init(onFinish: @escaping (CGRect?) -> Void, onCancel: @escaping () -> Void) {
        self.onFinish = onFinish
        self.onCancel = onCancel
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private var selection: NSRect? {
        guard let anchor, let current else { return nil }
        return NSRect(
            x: min(anchor.x, current.x),
            y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x),
            height: abs(current.y - anchor.y)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        guard let selection, selection.width > 0, selection.height > 0 else { return }

        // Punch the selection back to full brightness so you can read what you
        // are about to grab.
        NSColor.clear.setFill()
        selection.fill(using: .copy)

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        current = anchor
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        defer { anchor = nil; current = nil }

        // A click with no drag is a cancel, not a zero-sized grab.
        guard let selection, selection.width >= 4, selection.height >= 4 else {
            onCancel()
            return
        }
        onFinish(cgScreenRect(for: selection))
    }

    override func keyDown(with event: NSEvent) {
        // 53 is Escape.
        if event.keyCode == 53 { onCancel() } else { super.keyDown(with: event) }
    }

    /// View rect → Core Graphics screen rect: AppKit measures y up from the
    /// bottom of the primary screen, CG measures it down from the top.
    private func cgScreenRect(for rect: NSRect) -> CGRect {
        guard let window else { return rect }
        let onScreen = window.convertToScreen(convert(rect, to: nil))
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? onScreen.maxY
        return CGRect(
            x: onScreen.minX,
            y: primaryTop - onScreen.maxY,
            width: onScreen.width,
            height: onScreen.height
        )
    }
}
