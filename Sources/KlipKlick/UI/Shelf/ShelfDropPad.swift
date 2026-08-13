import AppKit
import SwiftUI

/// The shape that makes this look like the notch rather than a window near it.
///
/// The first `notchHeight` points are exactly as wide as the camera housing, so
/// the menu bar either side of it is never painted over. Below that the shape
/// flares out to the full width through a pair of *concave* shoulders and ends
/// in ordinary rounded bottom corners — so the black appears to pour out of the
/// housing instead of being a rectangle parked beneath it.
///
/// Square top corners are what sell it: the panel is flush with the top of the
/// screen, so those corners are off-screen and only the curves below are seen.
struct NotchShape: Shape {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var bottomRadius: CGFloat
    /// How far the concave flare reaches out from the housing's edge.
    var shoulderRadius: CGFloat = 12

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(notchWidth, bottomRadius) }
        set {
            notchWidth = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let bottom = min(bottomRadius, rect.height / 2, rect.width / 2)
        let left = (rect.width - notchWidth) / 2
        let right = rect.maxX - left

        var path = Path()

        // Waiting state: no wider than the housing, so there is nothing to flare
        // out of and the shoulders would render as noise.
        guard left > shoulderRadius + 1 else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - bottom, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - bottom),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            path.closeSubpath()
            return path
        }

        let shoulder = min(shoulderRadius, left - 1)

        path.move(to: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: rect.minY))
        // Down the housing's right edge, then curve *outwards* — control point on
        // the corner it is cutting away, which is what makes it read as concave.
        path.addLine(to: CGPoint(x: right, y: notchHeight - shoulder))
        path.addQuadCurve(
            to: CGPoint(x: right + shoulder, y: notchHeight),
            control: CGPoint(x: right, y: notchHeight)
        )
        path.addLine(to: CGPoint(x: rect.maxX - bottom, y: notchHeight))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: notchHeight + bottom),
            control: CGPoint(x: rect.maxX, y: notchHeight)
        )

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottom, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottom),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.minX, y: notchHeight + bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + bottom, y: notchHeight),
            control: CGPoint(x: rect.minX, y: notchHeight)
        )
        path.addLine(to: CGPoint(x: left - shoulder, y: notchHeight))
        path.addQuadCurve(
            to: CGPoint(x: left, y: notchHeight - shoulder),
            control: CGPoint(x: left, y: notchHeight)
        )

        path.closeSubpath()
        return path
    }
}

/// The drop target, docked to the notch.
///
/// Deliberately black rather than glass. Everything else in KlipKlick is a
/// translucent panel, but the camera housing is an actual hole in the display
/// and is always pure black — so the one way to look like part of it is to be
/// the same colour. Glass here would read as a window sitting near the notch,
/// which is exactly the effect being avoided.
///
/// Two states, and the window is resized between them:
///
/// * **Waiting** — the width of the housing, extending a few points below it.
///   On a MacBook the housing hides all but that sliver, so a drag you are not
///   aiming at the top of the screen sees almost nothing.
/// * **Targeted** — wide enough to say what it is, with the tray and a label.
struct ShelfDropPadView: View {
    let isTargeted: Bool
    /// The housing's own size, so the shape can keep clear of the menu bar and
    /// the content can sit below a hole it cannot draw into.
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            NotchShape(
                notchWidth: notchWidth,
                notchHeight: notchHeight,
                bottomRadius: isTargeted ? 20 : 10
            )
            .fill(.black)

            if isTargeted {
                VStack(spacing: 5) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 21, weight: .light))
                    Text("Release to Shelf")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.bottom, 14)
            } else {
                // A grab handle rather than text: the visible strip is only a few
                // points tall, and anything with words in it would be unreadable.
                Capsule()
                    .fill(.white.opacity(0.55))
                    .frame(width: 30, height: 4)
                    .padding(.bottom, 5)
            }
        }
        // The shape must reach the very top of the window or its housing section
        // lands below the real one. Nothing here may inset it: no top padding —
        // the content is bottom-aligned and clears the housing on its own — and
        // `ignoresSafeArea`, because a window overlapping the notch is handed a
        // 32pt top safe-area inset that would push the shape down by exactly the
        // height it is trying to line up with.
        .ignoresSafeArea()
    }
}

/// Hosts the pad, sizes it, and parks it under the notch.
final class ShelfDropPad {
    /// How long a drag has to last before the pad is worth showing. A drag that
    /// ends inside this — nudging an icon, dropping onto the folder right next to
    /// it — never sees the pad at all.
    private static let appearDelay: TimeInterval = 0.28

    /// Visible sliver below the housing while waiting to be aimed at.
    private static let waitingLip: CGFloat = 15
    /// Height below the housing once the pad is being targeted.
    private static let targetedDrop: CGFloat = 84
    private static let targetedMinWidth: CGFloat = 300

    /// Files were dropped. The point is where the resulting shelf should open.
    var onDropFiles: (([URL], NSPoint) -> Void)?
    var onDropStagedFile: ((URL, NSPoint) -> Void)?

    private let panel: NSPanel
    private let dropView = ShelfDropView()
    private var hosting: NSHostingView<ShelfDropPadView>
    private var appearWork: DispatchWorkItem?
    /// Where a shelf made from this drop should appear — below the pad, not at it.
    private var shelfOrigin: NSPoint = .zero
    private var dock: NSRect = .zero
    private var isTargeted = false {
        didSet {
            guard isTargeted != oldValue else { return }
            hosting.rootView = ShelfDropPadView(
                isTargeted: isTargeted, notchWidth: dock.width, notchHeight: dock.height
            )
            resize(targeted: isTargeted)
        }
    }

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 48),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        hosting = NSHostingView(rootView: ShelfDropPadView(isTargeted: false, notchWidth: 185, notchHeight: 32))

        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No shadow: a shadow under the housing is the one thing that would give
        // away that this is a window.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Above the menu bar, which sits at `.mainMenu` (24). The old
        // `.modalPanel` (8) is *below* it, so a pad at the notch would have been
        // covered by the menu bar it is supposed to grow out of.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false

        dropView.autoresizingMask = [.width, .height]
        hosting.autoresizingMask = [.width, .height]
        // Belt and braces alongside `ignoresSafeArea`: the hosting view is what
        // would apply the notch inset in the first place.
        hosting.safeAreaRegions = []
        dropView.addSubview(hosting)
        panel.contentView = dropView

        dropView.onTargetingChanged = { [weak self] targeted in
            self?.isTargeted = targeted
        }
        dropView.onDropFiles = { [weak self] urls in
            guard let self else { return }
            onDropFiles?(urls, shelfOrigin)
        }
        dropView.onDropStagedFile = { [weak self] url in
            guard let self else { return }
            onDropStagedFile?(url, shelfOrigin)
        }
    }

    /// Arms the pad. It only appears if the drag is still running when
    /// `appearDelay` elapses.
    ///
    /// `point` is where the drag *started*, not where the pointer is when the pad
    /// appears — on a two-display setup the pad belongs on the screen you picked
    /// the files up from, not on whichever one you have drifted onto since.
    func arm(near point: NSPoint) {
        guard !panel.isVisible else { return }
        appearWork?.cancel()

        let work = DispatchWorkItem { [weak self] in self?.present(on: point) }
        appearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.appearDelay, execute: work)
    }

    /// Shows the pad immediately, for the scripted development trigger. A drag
    /// cannot be synthesised, so this is the only way to look at it.
    func presentForPreview(targeted: Bool) {
        appearWork?.cancel()
        present(on: NSEvent.mouseLocation)
        if targeted { isTargeted = true }
    }

    private func present(on point: NSPoint) {
        dock = NotchGeometry.dock(on: NotchGeometry.screen(containing: point))

        // A shelf made here opens below the pad rather than behind it, centred on
        // the housing so it lines up with what the user just dropped onto.
        shelfOrigin = CGPoint(
            x: dock.midX - ShelfView.width / 2,
            y: dock.minY - Self.waitingLip - 10
        )

        isTargeted = false
        hosting.rootView = ShelfDropPadView(
            isTargeted: false, notchWidth: dock.width, notchHeight: dock.height
        )
        panel.setFrame(frame(targeted: false), display: true)
        // `orderFrontRegardless`, not `orderFront`: KlipKlick is not the active
        // application during someone else's drag, and a background app's ordinary
        // order-front is ignored.
        panel.orderFrontRegardless()
    }

    /// Panel frame for each state — always flush with the top of the screen and
    /// centred on the housing, so only the bottom edge moves.
    private func frame(targeted: Bool) -> NSRect {
        let width = targeted ? max(dock.width + 110, Self.targetedMinWidth) : dock.width
        let height = dock.height + (targeted ? Self.targetedDrop : Self.waitingLip)
        return NSRect(
            x: dock.midX - width / 2,
            y: dock.maxY - height,
            width: width,
            height: height
        )
    }

    /// Grows and shrinks the window itself. SwiftUI cannot animate this — the
    /// shape is the window, so the frame is what has to move.
    private func resize(targeted: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame(targeted: targeted), display: true)
        }
    }

    func dismiss() {
        appearWork?.cancel()
        appearWork = nil
        isTargeted = false
        panel.orderOut(nil)
    }
}
