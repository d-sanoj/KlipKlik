import AppKit
import SwiftUI

/// The window one shelf lives in.
///
/// Non-activating so a drop from Finder does not pull focus away from the
/// window you are working in. It *can* become key after a click, which is
/// what lets ⌘A select every file on the shelf without activating the app.
final class ShelfPanel: NSPanel {
    let shelfID: UUID
    /// Raised only for renaming. See `ShelfView.beginRename`.
    var wantsKey = false

    override var canBecomeKey: Bool { true }
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

/// How a shelf window first appears. Driven from the window controller so the
/// SwiftUI body can spring without knowing about AppKit's order-front.
final class ShelfAppearance: ObservableObject {
    enum Entrance {
        /// Already on screen (restored, or the feature toggled back on).
        case none
        /// Grew out of the notch after a drop on the pad.
        case fromNotch
        /// A milder pop, for the hot key and "Add to Shelf".
        case appear
    }

    var entrance: Entrance = .none
    @Published var revealed = true

    var hiddenScaleX: CGFloat {
        switch entrance {
        case .none: return 1
        case .fromNotch: return 0.9
        case .appear: return 0.94
        }
    }

    var hiddenScaleY: CGFloat {
        switch entrance {
        case .none: return 1
        case .fromNotch: return 0.36
        case .appear: return 0.94
        }
    }

    var hiddenOffset: CGFloat {
        switch entrance {
        case .none: return 0
        case .fromNotch: return 0
        case .appear: return 8
        }
    }

    var revealAnimation: Animation {
        switch entrance {
        case .fromNotch:
            return .spring(response: 0.34, dampingFraction: 1.0)
        default:
            return .spring(response: 0.42, dampingFraction: 0.9)
        }
    }
}

/// Owns one `ShelfPanel`: placing it, keeping its position in the store, and
/// tearing it down when the shelf goes.
final class ShelfWindowController: NSObject, NSWindowDelegate {
    let shelfID: UUID

    private let panel: ShelfPanel
    private let store: ShelfStore
    private weak var manager: ShelfManager?
    private let appearance = ShelfAppearance()
    /// SwiftUI resizes from the bottom-left; this is the top-left we re-pin to,
    /// the same trick the clipboard popup uses.
    private var anchorTopLeft: NSPoint = .zero
    private var isAdjustingFrame = false
    private var isAnimatingBirth = false
    private var keyMonitor: Any?

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
        panel.hasShadow = false
        // Above ordinary windows but below the clipboard popup, so opening the
        // popup over a shelf does not put the shelf on top of it.
        panel.level = .floating
        // Deliberately off — see `WindowDragHandleView`. The header drags the
        // window; everywhere else the pointer belongs to the tiles.
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // `.none`, not `.utilityWindow`. The utility animation interpolates from
        // the panel's birth rect — which is `(0, 0)` at the bottom-left of the
        // screen — so a new shelf used to crawl up from there instead of
        // appearing where we placed it.
        panel.animationBehavior = .none
        // `.stationary` and not `.transient`: a shelf is a place you are putting
        // things for later, so it has to survive Mission Control and an app
        // switch rather than being swept away with the other floating panels.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.delegate = self

        let view = ShelfView(
            store: store,
            appearance: appearance,
            shelfID: shelfID,
            onClose: { [weak self] in self?.close() },
            onNeedsKeyWindow: { [weak self] wants in self?.setWantsKey(wants) },
            onDragBegan: { [weak self] in self?.manager?.beginOwnDrag() },
            onDragEnded: { [weak self] _ in self?.manager?.endOwnDrag() }
        )

        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting

        // The glass is an `NSGlassEffectView` — a real AppKit view, and SwiftUI's
        // `.clipShape` cannot mask one: a clip shape only bounds SwiftUI's own
        // drawing, so the glass went on rendering its square edge past the
        // rounded corners as a hairline overshoot on all four sides.
        //
        // Masking the content view's layer clips the actual view hierarchy, glass
        // included. `.continuous` so the curve matches the squircle `ShelfView`
        // draws its border and clip shape with, rather than the circular arc a
        // bare `cornerRadius` would give.
        if let content = panel.contentView {
            content.wantsLayer = true
            content.layer?.cornerRadius = Metrics.cornerRadius
            content.layer?.cornerCurve = .continuous
            content.layer?.masksToBounds = true
            // Belt and braces with `focusEffectDisabled()` in `ShelfView`: this
            // is the AppKit half, for a ring drawn by the hosting view itself.
            content.focusRingType = .none
        }

        installKeyMonitor()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func show(entrance: ShelfAppearance.Entrance = .none) {
        appearance.entrance = entrance
        appearance.revealed = entrance == .none
        panel.hasShadow = false

        isAdjustingFrame = true
        panel.layoutIfNeeded()
        if entrance == .fromNotch {
            playNotchBirth()
            return
        }

        place()
        panel.layoutIfNeeded()
        place()
        panel.orderFrontRegardless()
        isAdjustingFrame = false
        store.setWindowTopLeft(shelfID, anchorTopLeft)

        if entrance == .appear {
            DispatchQueue.main.async { [weak self] in
                self?.appearance.revealed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                self?.enableShadow()
            }
        } else {
            appearance.revealed = true
            enableShadow()
        }

        store.pruneMissing(in: shelfID)
    }

    /// Grows the shelf out of the expanded island: same rest position, scaled
    /// from the top so it reads as the notch bubbling downward into a panel.
    /// The pad stays in front for a beat and recedes into the housing, which is
    /// what makes the two feel like one motion.
    private func playNotchBirth() {
        let seed = store.shelf(shelfID)?.windowTopLeft ?? NSEvent.mouseLocation
        let screen = NotchGeometry.screen(containing: seed)
        let dock = NotchGeometry.dock(on: screen)
        let rest = restFrame(on: screen, dock: dock)

        isAnimatingBirth = true
        panel.level = .statusBar
        panel.setFrame(rest, display: true)
        anchorTopLeft = CGPoint(x: rest.minX, y: rest.maxY)
        panel.orderFrontRegardless()
        store.pruneMissing(in: shelfID)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appearance.revealed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                self.panel.level = .floating
                self.enableShadow()
                self.anchorTopLeft = CGPoint(x: rest.minX, y: rest.maxY)
                self.store.setWindowTopLeft(self.shelfID, self.anchorTopLeft)
                self.isAdjustingFrame = false
                self.isAnimatingBirth = false
            }
        }
    }

    /// Turns the shadow on and forces it to be recomputed.
    ///
    /// AppKit derives a borderless window's shadow from the alpha of its content
    /// and then caches the result. Flipping `hasShadow` during the entrance
    /// animation baked in the shape the content had at that instant — a square —
    /// which is the dark outline that showed just outside the rounded corners.
    /// It never got recomputed afterwards, so it outlived the animation.
    private func enableShadow() {
        panel.hasShadow = true
        panel.invalidateShadow()
    }

    /// Centred on the housing, a clear gap below the menu bar so the shelf is
    /// a panel in the room rather than a thing pressed against the ceiling.
    private func restFrame(on screen: NSScreen, dock: NSRect) -> NSRect {
        let rank = store.shelves.firstIndex { $0.id == shelfID } ?? 0
        let offset = CGFloat(rank % 6) * Self.cascadeStep
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let x = NotchGeometry.snap(dock.midX - size.width / 2 + offset, on: screen)
        let top = visible.maxY - 22 - offset
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
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
            // KlipKlik activates at all, so handing activation back to whatever
            // the user was actually working in is the honest way to give it up.
            NSApp.deactivate()
        }
    }

    /// ⌘A / Escape while this shelf is the key window. The first responder is
    /// often a SwiftUI host that never sees `selectAll`, so the window listens.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel || self.panel.isKeyWindow else {
                return event
            }
            if self.panel.firstResponder is NSTextView { return event }
            if event.isShelfSelectAll {
                NotificationCenter.default.post(name: .shelfSelectAll, object: self.shelfID)
                return nil
            }
            if event.keyCode == 53 {
                NotificationCenter.default.post(name: .shelfDeselectAll, object: self.shelfID)
                return nil
            }
            return event
        }
    }

    /// Where the shelf was left, or near the pointer for a new one.
    ///
    /// New shelves cascade rather than stack: opening a second one directly on
    /// top of the first makes it look like nothing happened.
    private func place() {
        let rank = store.shelves.firstIndex { $0.id == shelfID } ?? 0
        let offset = CGFloat(rank % 6) * Self.cascadeStep

        let target: CGPoint
        if let saved = store.shelf(shelfID)?.windowTopLeft {
            target = saved
        } else {
            let mouse = NSEvent.mouseLocation
            target = CGPoint(
                x: mouse.x - ShelfView.width / 2 + offset,
                y: mouse.y - 20 - offset
            )
        }

        anchorTopLeft = target
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
        anchorTopLeft = topLeft
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard !isAdjustingFrame, !isAnimatingBirth else { return }
        let point = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        anchorTopLeft = point
        store.setWindowTopLeft(shelfID, point)
    }

    /// SwiftUI resizes the panel as items are added and removed, and a shelf that
    /// grew a row is exactly the one likely to have grown off the screen.
    func windowDidResize(_ notification: Notification) {
        guard !isAdjustingFrame, !isAnimatingBirth, panel.isVisible else { return }
        isAdjustingFrame = true
        let current = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        if abs(current.y - anchorTopLeft.y) > 0.5 || abs(current.x - anchorTopLeft.x) > 0.5 {
            panel.setFrameTopLeftPoint(anchorTopLeft)
        }
        keepOnScreen()
        isAdjustingFrame = false
        // The cached shadow is for the old size — a shelf that grew a row would
        // otherwise keep the previous outline until it was moved.
        if panel.hasShadow { panel.invalidateShadow() }
    }

    /// macOS swaps a key window onto a deeper shadow, recomputed at that moment
    /// — which is what made a stale square one jump out as soon as the shelf was
    /// clicked, and stay subtle before.
    func windowDidBecomeKey(_ notification: Notification) {
        if panel.hasShadow { panel.invalidateShadow() }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Renaming is the only thing that made it key, and clicking away is a
        // perfectly good way to finish.
        panel.wantsKey = false
        if panel.hasShadow { panel.invalidateShadow() }
    }
}
