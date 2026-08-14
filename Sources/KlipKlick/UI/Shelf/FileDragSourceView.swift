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
/// Dragging out advertises copy for referenced files (the original stays on
/// disk) and prefers move for staged ones (cut onto the shelf, so the only
/// remaining copy should be wherever they land). The shelf row is removed by
/// the caller after a successful drop, not here.
final class FileDragSourceView: NSView, NSDraggingSource {
    /// What to drag. A closure, not a stored array, so a tile always drags the
    /// item it currently shows rather than the one it showed when it was built.
    var urls: () -> [URL] = { [] }
    var onSessionBegan: (() -> Void)?
    /// Reports the operation the destination performed, once it has.
    var onSessionEnded: ((NSDragOperation) -> Void)?
    /// Pointer down, before a drag is distinguished from a click — used to
    /// update the shelf's selection so a drag of a selected tile takes them all.
    var onMouseDown: ((NSEvent.ModifierFlags) -> Void)?
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    var onDoubleClick: (() -> Void)?
    var menuBuilder: (() -> NSMenu?)?
    var operationMask: () -> NSDragOperation = { [.copy, .generic] }
    var itemID: UUID?
    var onSelectItem: ((UUID) -> Void)?
    var onClearSelection: (() -> Void)?
    var onSelectAll: (() -> Void)?
    var onRemove: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private var mouseDownAt: NSPoint?
    private var pressedRemove = false
    private var hovering = false
    /// Top-right corner, matching the × badge. Clicks here remove the tile
    /// instead of selecting or dragging it.
    private var removeRect: CGRect {
        CGRect(x: bounds.maxX - 24, y: bounds.minY, width: 24, height: 24)
    }

    func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        needsDisplay = true
        onHover?(value)
    }

    /// See `ShelfCanvasView.acceptsFirstMouse(for:)` — the canvas hit-tests
    /// ahead of this view today, but a drag source that refuses the first click
    /// is the bug waiting to come back if that ever changes.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Below this the gesture is a click, not a drag. Matches the system's own
    /// slop, so a shaky click on a trackpad does not fling a file somewhere.
    private static let dragThreshold: CGFloat = 4

    /// Top-left origin, same as the SwiftUI tile, so the × badge sits in the
    /// corner the user sees rather than the opposite one.
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        let rect = removeRect.insetBy(dx: 4, dy: 4)
        guard let symbol = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove"),
              let image = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [
                        NSColor.windowBackgroundColor,
                        NSColor.secondaryLabelColor
                    ]))
              )
        else { return }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onClearSelection?()
            return
        }
        if event.isShelfSelectAll {
            onSelectAll?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        pressedRemove = removeRect.contains(local)
        if pressedRemove { return }
        mouseDownAt = event.locationInWindow
        // Become key before taking first responder, otherwise `canBecomeKey` is
        // still false and this click never owns the keyboard.
        onMouseDown?(Self.flags(from: event))
        window?.makeFirstResponder(self)
    }

    override func selectAll(_ sender: Any?) {
        onSelectAll?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.isShelfSelectAll {
            onSelectAll?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if pressedRemove { return }
        if let id = Self.itemID(at: event.locationInWindow, in: window) {
            onSelectItem?(id)
            return
        }
        if Self.isInsideItemGrid(event.locationInWindow, window: window) {
            return
        }
        guard mouseDownAt != nil else { return }
        let now = event.locationInWindow
        let start = mouseDownAt ?? now
        let distance = hypot(now.x - start.x, now.y - start.y)
        guard distance >= Self.dragThreshold else { return }
        mouseDownAt = nil
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownAt = nil
            pressedRemove = false
        }
        if pressedRemove {
            let local = convert(event.locationInWindow, from: nil)
            if removeRect.contains(local) { onRemove?() }
            return
        }
        guard mouseDownAt != nil else { return }
        event.clickCount >= 2 ? onDoubleClick?() : onClick?(Self.flags(from: event))
    }

    private static func flags(from event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.union(NSEvent.modifierFlags)
            .intersection(.deviceIndependentFlagsMask)
    }

    static func itemID(at windowPoint: NSPoint, in window: NSWindow?) -> UUID? {
        source(at: windowPoint, in: window)?.itemID
    }

    static func source(at windowPoint: NSPoint, in window: NSWindow?) -> FileDragSourceView? {
        guard let content = window?.contentView else { return nil }
        let inContent = content.convert(windowPoint, from: nil)
        var match: FileDragSourceView?
        func collect(_ view: NSView) {
            if view is ShelfCanvasView {
                for child in view.subviews { collect(child) }
                return
            }
            if let source = view as? FileDragSourceView {
                let frame = source.convert(source.bounds, to: content)
                if frame.contains(inContent) { match = source }
            }
            for child in view.subviews { collect(child) }
        }
        collect(content)
        return match
    }

    /// Gaps between tiles still count as "inside the grid", so a swipe across
    /// the shelf paints a selection instead of starting a file drag.
    private static func isInsideItemGrid(_ windowPoint: NSPoint, window: NSWindow?) -> Bool {
        guard let content = window?.contentView else { return false }
        var union = NSRect.null
        func walk(_ view: NSView) {
            if let source = view as? FileDragSourceView {
                union = union.union(source.convert(source.bounds, to: content))
            }
            for child in view.subviews { walk(child) }
        }
        walk(content)
        guard !union.isNull else { return false }
        let padded = union.insetBy(dx: -14, dy: -14)
        return padded.contains(content.convert(windowPoint, from: nil))
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
            return operationMask()
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

    /// Move the shelf on the first press, for the same reason its files drag on
    /// the first press — see `ShelfCanvasView.acceptsFirstMouse(for:)`. A shelf
    /// you have to wake before you can move it is the same extra click in a
    /// different place.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
    var onMouseDown: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var menuBuilder: () -> NSMenu? = { nil }
    var operationMask: () -> NSDragOperation = { [.copy, .generic] }
    var itemID: UUID?
    var onSelectItem: (UUID) -> Void = { _ in }
    var onClearSelection: () -> Void = {}
    var onSelectAll: () -> Void = {}
    var onRemove: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> FileDragSourceView {
        let view = FileDragSourceView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
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
        view.onMouseDown = onMouseDown
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.menuBuilder = menuBuilder
        view.operationMask = operationMask
        view.itemID = itemID
        view.onSelectItem = onSelectItem
        view.onClearSelection = onClearSelection
        view.onSelectAll = onSelectAll
        view.onRemove = onRemove
        view.onHover = onHover
    }
}

/// Fills the empty area of a shelf so a click off the tiles clears the
/// selection, and a drag there rubber-bands like Finder.
final class ShelfCanvasView: NSView {
    var onApplySelection: ((Set<UUID>) -> Void)?
    var currentSelection: () -> Set<UUID> = { [] }
    var onPress: (() -> Void)?
    var onSelectAll: (() -> Void)?

    private var start: NSPoint?
    private var base: Set<UUID> = []
    private var liveRect: NSRect?
    private weak var mouseTarget: FileDragSourceView?
    private weak var hoveredSource: FileDragSourceView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return self
    }

    /// Drag a file straight out of a shelf that is not the key window.
    ///
    /// Without this, AppKit swallows the first click of an inactive window to
    /// make it key and never delivers it — so picking a file off a shelf after
    /// working in Finder took a click to wake the shelf and *then* a drag. The
    /// shelf is a floating panel you reach across to, and needing to knock
    /// before opening the door is the whole cost.
    ///
    /// `mouseDown` still makes the window key, so nothing else changes; the
    /// click is simply also handed to the view that was under it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredSource?.setHovering(false)
        hoveredSource = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onApplySelection?([])
            return
        }
        if event.isShelfSelectAll {
            onSelectAll?()
            return
        }
        super.keyDown(with: event)
    }

    override func selectAll(_ sender: Any?) {
        onSelectAll?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.isShelfSelectAll {
            onSelectAll?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        updateHover(with: event)
        if let source = source(at: event.locationInWindow) {
            mouseTarget = source
            source.mouseDown(with: event)
            return
        }
        mouseTarget = nil
        onPress?()
        window?.makeFirstResponder(self)
        start = convert(event.locationInWindow, from: nil)
        let additive = event.modifierFlags.contains(.shift)
            || event.modifierFlags.contains(.command)
        base = additive ? currentSelection() : []
        if !additive {
            onApplySelection?([])
        }
        liveRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let source = mouseTarget {
            source.mouseDragged(with: event)
            return
        }
        guard let start else { return }
        let now = convert(event.locationInWindow, from: nil)
        let rect = NSRect(
            x: min(start.x, now.x),
            y: min(start.y, now.y),
            width: abs(now.x - start.x),
            height: abs(now.y - start.y)
        )
        liveRect = rect
        needsDisplay = true
        onApplySelection?(base.union(ids(intersecting: rect)))
    }

    override func mouseUp(with event: NSEvent) {
        if let source = mouseTarget {
            source.mouseUp(with: event)
            mouseTarget = nil
            return
        }
        start = nil
        liveRect = nil
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        source(at: event.locationInWindow)?.rightMouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let liveRect, liveRect.width > 2, liveRect.height > 2 else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        liveRect.fill()
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: liveRect)
        path.lineWidth = 1
        path.stroke()
    }

    private func updateHover(with event: NSEvent) {
        let next = source(at: event.locationInWindow)
        if hoveredSource !== next {
            hoveredSource?.setHovering(false)
            next?.setHovering(true)
            hoveredSource = next
        }
    }

    private func source(at windowPoint: NSPoint) -> FileDragSourceView? {
        FileDragSourceView.source(at: windowPoint, in: window)
    }

    private func ids(intersecting rect: NSRect) -> Set<UUID> {
        guard let content = window?.contentView else { return [] }
        var ids: Set<UUID> = []
        func walk(_ view: NSView) {
            if let source = view as? FileDragSourceView, let id = source.itemID {
                let frame = source.convert(source.bounds, to: self)
                if frame.intersects(rect) { ids.insert(id) }
            }
            for child in view.subviews { walk(child) }
        }
        walk(content)
        return ids
    }
}

struct ShelfCanvas: NSViewRepresentable {
    var currentSelection: () -> Set<UUID>
    var onApplySelection: (Set<UUID>) -> Void
    var onPress: () -> Void = {}
    var onSelectAll: () -> Void = {}

    func makeNSView(context: Context) -> ShelfCanvasView {
        let view = ShelfCanvasView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        apply(to: view)
        return view
    }

    func updateNSView(_ view: ShelfCanvasView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: ShelfCanvasView) {
        view.currentSelection = currentSelection
        view.onApplySelection = onApplySelection
        view.onPress = onPress
        view.onSelectAll = onSelectAll
        view.autoresizingMask = [.width, .height]
    }
}

extension NSEvent {
    /// ⌘A, ignoring Caps Lock / Fn / numeric-pad bits that otherwise make a
    /// straight `.command` comparison fail.
    var isShelfSelectAll: Bool {
        let mods = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        return mods == .command && charactersIgnoringModifiers?.lowercased() == "a"
    }
}

extension Notification.Name {
    static let shelfSelectAll = Notification.Name("KlipKlick.shelfSelectAll")
    static let shelfDeselectAll = Notification.Name("KlipKlick.shelfDeselectAll")
}
