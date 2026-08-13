import AppKit
import SwiftUI

/// The window one shelf lives in.
///
/// Non-activating for the same reason the clipboard popup is: dropping a file
/// onto a shelf must not pull focus away from the Finder window you are working
/// in. It only becomes key while a name is being edited, because a text field in
/// a window that cannot take focus is a text field you cannot type into.
final class ShelfPanel: NSPanel {
    let shelfID: UUID
    /// Raised only for renaming. See `ShelfView.beginRename`.
    var wantsKey = false

    override var canBecomeKey: Bool { wantsKey }
    override var canBecomeMain: Bool { false }

    init(shelfID: UUID) {
        self.shelfID = shelfID
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: ShelfView.width, height: 160),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
    }
}

/// Owns one `ShelfPanel`: placing it, keeping its position in the store, and
/// tearing it down when the shelf goes.
final class ShelfWindowController: NSObject, NSWindowDelegate {
    let shelfID: UUID

    private let panel: ShelfPanel
    private let store: ShelfStore
    private weak var manager: ShelfManager?

    init(shelfID: UUID, store: ShelfStore, manager: ShelfManager) {
        self.shelfID = shelfID
        self.store = store
        self.manager = manager
        self.panel = ShelfPanel(shelfID: shelfID)
        super.init()
        configure()
    }

    private func configure() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above ordinary windows but below the clipboard popup, so opening the
        // popup over a shelf does not put the shelf on top of it.
        panel.level = .floating
        // Deliberately off — see `WindowDragHandleView`. The header drags the
        // window; everywhere else the pointer belongs to the tiles.
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        // `.stationary` and not `.transient`: a shelf is a place you are putting
        // things for later, so it has to survive Mission Control and an app
        // switch rather than being swept away with the other floating panels.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.delegate = self

        let view = ShelfView(
            store: store,
            shelfID: shelfID,
            onClose: { [weak self] in self?.close() },
            onNeedsKeyWindow: { [weak self] wants in self?.setWantsKey(wants) },
            onDragBegan: { [weak self] in self?.manager?.beginOwnDrag() },
            onDragEnded: { [weak self] _ in self?.manager?.endOwnDrag() }
        )

        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
    }

    func show() {
        panel.layoutIfNeeded()
        place()
        panel.orderFrontRegardless()
        store.pruneMissing(in: shelfID)
    }

    /// How far each new shelf is stepped down and right from the last.
    static var cascadeStep: CGFloat = 26

    func close() {
        panel.orderOut(nil)
        store.removeShelf(shelfID)
    }

    /// Takes the window off screen without discarding the shelf — used when the
    /// whole feature is switched off in Settings.
    func dismiss() {
        panel.orderOut(nil)
    }

    private func setWantsKey(_ wants: Bool) {
        panel.wantsKey = wants
        if wants {
            panel.makeKeyAndOrderFront(nil)
        } else {
            // Not `resignKey()` — that only posts the message and leaves the
            // panel key regardless. Taking focus for a rename is the one time
            // KlipKlick activates at all, so handing activation back to whatever
            // the user was actually working in is the honest way to give it up.
            NSApp.deactivate()
        }
    }

    /// Where the shelf was left, or near the pointer for a new one.
    ///
    /// New shelves cascade rather than stack: opening a second one directly on
    /// top of the first makes it look like nothing happened.
    private func place() {
        let saved = store.shelf(shelfID)?.windowTopLeft
        let target = saved ?? {
            let mouse = NSEvent.mouseLocation
            // Index among open shelves, so the step is stable rather than
            // depending on how many have been closed since.
            let rank = store.shelves.firstIndex { $0.id == shelfID } ?? 0
            let offset = CGFloat(rank % 6) * Self.cascadeStep
            return CGPoint(
                x: mouse.x - ShelfView.width / 2 + offset,
                y: mouse.y - 20 - offset
            )
        }()

        panel.setFrameTopLeftPoint(target)
        keepOnScreen()
    }

    /// Pulls the panel fully back onto whichever screen it is mostly on.
    ///
    /// Clamping at `place()` time is not enough on its own. SwiftUI sizes the
    /// window through `preferredContentSize`, which lands *after* the window has
    /// been positioned — so a shelf clamped while it was still the placeholder
    /// height grows past the bottom of the screen a moment later. Re-running this
    /// on every resize is what actually keeps it on screen.
    private func keepOnScreen() {
        let frame = panel.frame
        // The screen holding most of the window, not the one holding its corner:
        // a window straddling two displays should be clamped against the one it
        // is really on.
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.frame.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }

        let screen = NSScreen.screens.max { overlap($0) < overlap($1) }
            ?? NSScreen.main ?? NSScreen.screens[0]

        let visible = screen.visibleFrame
        let margin: CGFloat = 8
        var topLeft = CGPoint(x: frame.minX, y: frame.maxY)

        topLeft.x = min(topLeft.x, visible.maxX - frame.width - margin)
        topLeft.x = max(topLeft.x, visible.minX + margin)
        topLeft.y = min(topLeft.y, visible.maxY - margin)
        topLeft.y = max(topLeft.y, visible.minY + frame.height + margin)

        guard abs(topLeft.x - frame.minX) > 0.5 || abs(topLeft.y - frame.maxY) > 0.5 else { return }
        panel.setFrameTopLeftPoint(topLeft)
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        store.setWindowTopLeft(
            shelfID, CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        )
    }

    /// SwiftUI resizes the panel as items are added and removed, and a shelf that
    /// grew a row is exactly the one likely to have grown off the screen.
    func windowDidResize(_ notification: Notification) {
        keepOnScreen()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Renaming is the only thing that made it key, and clicking away is a
        // perfectly good way to finish.
        panel.wantsKey = false
    }
}
