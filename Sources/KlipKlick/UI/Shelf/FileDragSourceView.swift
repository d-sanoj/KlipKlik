import AppKit
import SwiftUI

/// Starts a real file drag out of a shelf, and owns every pointer gesture on the
/// thing it covers.
///
/// It sits *over* the SwiftUI tile rather than beside it, and handles clicks,
/// double-clicks and the context menu itself. That looks heavy-handed next to a
/// SwiftUI `Button`, but the alternative does not work: an `NSView` hosted in
/// SwiftUI is a real view in the hierarchy and wins hit-testing against anything
/// SwiftUI draws above it, so a mix of the two ends with buttons that only
/// sometimes respond. One view owning all of it is predictable.
///
/// ## Copy, move, and who actually does the moving
///
/// The session advertises `[.copy, .move]`, so the destination and the modifier
/// keys decide — the same bargain every other macOS app strikes, and the reason
/// dragging to another volume copies while dragging within one moves.
///
/// What it deliberately does *not* do is delete the source itself when the
/// operation comes back as `.move`. Two different things can have happened by
/// then: Finder may have performed the move already, or the destination may
/// expect the source to finish the job. Guessing wrong in one direction leaves a
/// duplicate, and in the other destroys the user's only copy. So the file is
/// asked instead of assumed — if it is gone, the move happened and the shelf
/// drops the row; if it is still there, the shelf keeps it.
final class FileDragSourceView: NSView, NSDraggingSource {
    /// What to drag. A closure, not a stored array, so a tile always drags the
    /// item it currently shows rather than the one it showed when it was built.
    var urls: () -> [URL] = { [] }
    var onSessionBegan: (() -> Void)?
    /// Reports the operation the destination performed, once it has.
    var onSessionEnded: ((NSDragOperation) -> Void)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var menuBuilder: (() -> NSMenu?)?
    /// Area, in this view's own coordinates, that should fall through to the
    /// SwiftUI underneath.
    ///
    /// This is how the tile's remove badge stays clickable. Covering a SwiftUI
    /// button with an `NSView` and hoping z-order sorts it out does not work —
    /// AppKit hit-tests real subviews before SwiftUI ever sees the click, so the
    /// button would be dead. Punching a hole is the only reliable fix.
    var passthroughRect: () -> CGRect = { .zero }

    private var mouseDownAt: NSPoint?
    /// Below this the gesture is a click, not a drag. Matches the system's own
    /// slop, so a shaky click on a trackpad does not fling a file somewhere.
    private static let dragThreshold: CGFloat = 4

    /// Top-left origin, so `passthroughRect` is expressed the same way the
    /// SwiftUI tile above it thinks about its own corners. AppKit's default
    /// bottom-left origin would silently put the hole in the wrong corner.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !passthroughRect().contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownAt else { return }
        let now = event.locationInWindow
        let distance = hypot(now.x - start.x, now.y - start.y)
        guard distance >= Self.dragThreshold else { return }

        mouseDownAt = nil
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownAt = nil }
        guard mouseDownAt != nil else { return }
        event.clickCount >= 2 ? onDoubleClick?() : onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuBuilder?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func beginDrag(with event: NSEvent) {
        let files = urls().filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }

        let items: [NSDraggingItem] = files.enumerated().map { offset, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 48, height: 48)
            // Fanned slightly, so dragging six files reads as six things rather
            // than one icon with a badge.
            let origin = NSPoint(
                x: bounds.midX - 24 + CGFloat(offset) * 6,
                y: bounds.midY - 24 - CGFloat(offset) * 6
            )
            item.setDraggingFrame(NSRect(origin: origin, size: icon.size), contents: icon)
            return item
        }

        onSessionBegan?()
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .stack
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            // `.generic` is included because a fair number of applications only
            // advertise that, and without it they refuse the drop outright.
            return [.copy, .move, .link, .generic]
        case .withinApplication:
            // Between two shelves: the file is referenced twice, never moved.
            return .copy
        @unknown default:
            return .copy
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onSessionEnded?(operation)
    }
}

/// Moves the shelf window, and nothing else.
///
/// `isMovableByWindowBackground` cannot be used here. AppKit resolves it at the
/// window level, before the mouse-down reaches any view, so it swallows the
/// press that should have started a file drag — the tiles become impossible to
/// drag out of and the whole window slides around instead. Restricting the
/// gesture to an explicit handle on the header is what makes both work.
final class WindowDragHandleView: NSView {
    var onDoubleClick: (() -> Void)?
    var menuBuilder: (() -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        // Blocks until the drag finishes, which is how AppKit expects this to be
        // driven — the window follows the pointer for us.
        window?.performDrag(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuBuilder?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

struct WindowDragHandle: NSViewRepresentable {
    var onDoubleClick: () -> Void = {}
    var menuBuilder: () -> NSMenu? = { nil }

    func makeNSView(context: Context) -> WindowDragHandleView {
        let view = WindowDragHandleView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: WindowDragHandleView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: WindowDragHandleView) {
        view.onDoubleClick = onDoubleClick
        view.menuBuilder = menuBuilder
    }
}

/// Lays a `FileDragSourceView` over a SwiftUI tile.
struct FileDragSource: NSViewRepresentable {
    let urls: () -> [URL]
    var onSessionBegan: () -> Void = {}
    var onSessionEnded: (NSDragOperation) -> Void = { _ in }
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var menuBuilder: () -> NSMenu? = { nil }
    var passthroughRect: () -> CGRect = { .zero }

    func makeNSView(context: Context) -> FileDragSourceView {
        let view = FileDragSourceView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: FileDragSourceView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: FileDragSourceView) {
        view.urls = urls
        view.onSessionBegan = onSessionBegan
        view.onSessionEnded = onSessionEnded
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.menuBuilder = menuBuilder
        view.passthroughRect = passthroughRect
    }
}
