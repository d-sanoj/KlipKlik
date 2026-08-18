import AppKit
import SwiftUI

/// The black island, drawn in AppKit so its housing is locked to the camera
/// every frame via `convertFromScreen`. SwiftUI layout was shifting it left of
/// the real notch.
///
/// The blob starts the size of the camera housing and springs wider and down
/// from there, so the notch itself appears to expand rather than a bar sliding
/// in from the top of the screen.
final class NotchIslandView: NSView {
    var screenDock: NSRect = .zero
    /// `nil` idle, `false` Copy, `true` Move.
    var hoverMove: Bool? {
        didSet { needsDisplay = true }
    }

    @objc dynamic var blobWidth: CGFloat = 185 {
        didSet { needsDisplay = true }
    }
    @objc dynamic var blobHeight: CGFloat = 32 {
        didSet { needsDisplay = true }
    }
    @objc dynamic var blobRadius: CGFloat = 8 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        switch key {
        case "blobWidth", "blobHeight", "blobRadius":
            return islandSpring()
        default:
            return super.defaultAnimation(forKey: key)
        }
    }

    static func islandSpring() -> CASpringAnimation {
        let spring = CASpringAnimation()
        spring.mass = 0.65
        spring.stiffness = 260
        spring.damping = 30
        spring.duration = spring.settlingDuration
        return spring
    }

    override func draw(_ dirtyRect: NSRect) {
        let house = dockInView()
        guard house.width > 0.5, blobWidth > 0.5, blobHeight > 0.5 else { return }

        let radius = min(max(blobRadius, 0), blobHeight, blobWidth / 2)
        let x = house.midX - blobWidth / 2
        let rect = NSRect(x: x, y: -radius, width: blobWidth, height: blobHeight + radius)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.black.setFill()
        path.fill()

        let expanded = blobWidth > house.width + 8
        if expanded, let hoverMove {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSColor.white.withAlphaComponent(0.1).setFill()
            let half = NSRect(
                x: hoverMove ? x + blobWidth / 2 : x,
                y: 0,
                width: blobWidth / 2,
                height: blobHeight
            )
            half.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        if expanded {
            NSColor.white.withAlphaComponent(0.22).setFill()
            let divider = NSRect(
                x: house.midX - 0.5,
                y: house.height + 6,
                width: 1,
                height: max(0, blobHeight - house.height - 16)
            )
            divider.fill()
        }
    }

    /// Mid-X of the blob in another view's coordinates — the Copy/Move split.
    func blobMidX(in view: NSView) -> CGFloat {
        let house = dockInView()
        return convert(NSPoint(x: house.midX, y: 0), to: view).x
    }

    private func dockInView() -> NSRect {
        guard let window, screenDock.width > 0 else { return .zero }
        let inWindow = window.convertFromScreen(screenDock)
        return convert(inWindow, from: nil)
    }
}

/// Label layer only. The black island is an AppKit view underneath, because
/// SwiftUI's layout was not a reliable place to aim at the camera housing.
final class ShelfDropPadModel: ObservableObject {
    enum Phase: Equatable {
        case hidden, waiting, targeted
    }

    @Published var phase: Phase = .hidden
    @Published var labelVisible = false
    /// `nil` until the pointer is over a half; `false` Copy, `true` Move.
    @Published var hoverMove: Bool?
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 32

    static let waitingDrop: CGFloat = 48
    static let targetedDrop: CGFloat = 48
    static let islandRadius: CGFloat = 26

    /// Housing plus 20% of its width on the left and 20% on the right, with a
    /// little extra so Copy and Move each have a clear half.
    var expandedWidth: CGFloat { max(notchWidth * 1.5, notchWidth + 80) }

    /// Hidden matches the camera housing so the expand reads as the notch growing.
    var shapeWidth: CGFloat {
        switch phase {
        case .hidden: return notchWidth
        case .waiting, .targeted: return expandedWidth
        }
    }

    var shapeHeight: CGFloat {
        switch phase {
        case .hidden: return notchHeight
        case .waiting: return notchHeight + Self.waitingDrop
        case .targeted: return notchHeight + Self.targetedDrop
        }
    }

    var bottomRadius: CGFloat {
        switch phase {
        case .hidden: return min(12, notchHeight * 0.4)
        case .waiting, .targeted: return Self.islandRadius
        }
    }

    func setPhase(_ phase: Phase, animated: Bool = true) {
        guard self.phase != phase else { return }
        if animated {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.84)) {
                self.phase = phase
            }
        } else {
            self.phase = phase
        }
    }
}

struct ShelfDropPadView: View {
    @ObservedObject var model: ShelfDropPadModel

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            labels
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    private var labels: some View {
        HStack(spacing: 0) {
            sideLabel(symbol: "plus", title: "Copy", isMove: false)
            sideLabel(symbol: "arrow.right", title: "Move", isMove: true)
        }
        .opacity(model.labelVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.1), value: model.labelVisible)
        .padding(.top, model.notchHeight)
        .padding(.bottom, 22)
        .frame(width: model.shapeWidth, height: model.shapeHeight, alignment: .bottom)
    }

    private func sideLabel(symbol: String, title: String, isMove: Bool) -> some View {
        let active = model.hoverMove == nil || model.hoverMove == isMove
        return HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.2)
        }
        .foregroundStyle(.white.opacity(active ? 0.96 : 0.38))
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.12), value: model.hoverMove)
    }
}

private final class ClearHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }
}

/// Hosts the pad, sizes it, and parks it under the notch.
final class ShelfDropPad {
    private static let appearDelay: TimeInterval = 0.28
    private static let islandAnimationDuration: TimeInterval = min(
        max(NotchIslandView.islandSpring().settlingDuration, 0.22),
        0.32
    )
    private static let labelRevealDelay: TimeInterval = 0.12

    var onDropFiles: (([URL], NSPoint) -> Void)?
    var onDropMovingFiles: (([URL], NSPoint) -> Void)?
    var onDropStagedFile: ((URL, NSPoint) -> Void)?

    private let panel: NSPanel
    private let dropView = ShelfDropView()
    private let island = NotchIslandView()
    private let model = ShelfDropPadModel()
    private let hosting: ClearHostingView<ShelfDropPadView>
    private var appearWork: DispatchWorkItem?
    private var generation = 0
    private var labelToken = 0
    private var dock: NSRect = .zero

    var isVisible: Bool { panel.isVisible }

    var shelfOrigin: NSPoint {
        CGPoint(
            x: dock.midX - ShelfView.width / 2,
            y: dock.minY - 12
        )
    }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        hosting = ClearHostingView(rootView: ShelfDropPadView(model: model))

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false

        dropView.autoresizingMask = [.width, .height]
        island.autoresizingMask = [.width, .height]
        hosting.autoresizingMask = [.width, .height]
        dropView.wantsLayer = true
        dropView.layer?.backgroundColor = NSColor.clear.cgColor
        island.wantsLayer = true
        island.clipsToBounds = true
        island.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        hosting.safeAreaRegions = []

        dropView.addSubview(island)
        dropView.addSubview(hosting)
        panel.contentView = dropView
        island.frame = dropView.bounds
        hosting.frame = dropView.bounds

        dropView.splitMidX = { [weak self] in
            guard let self else { return 0 }
            return self.island.blobMidX(in: self.dropView)
        }
        dropView.onHoverMove = { [weak self] move in
            self?.model.hoverMove = move
            self?.island.hoverMove = move
        }
        dropView.onTargetingChanged = { [weak self] targeted in
            guard let self, self.panel.isVisible, self.model.phase != .hidden else { return }
            if targeted { self.apply(.targeted) }
        }
        dropView.onDropFiles = { [weak self] urls in
            guard let self else { return }
            onDropFiles?(urls, shelfOrigin)
            handoffToShelf()
        }
        dropView.onDropMovingFiles = { [weak self] urls in
            guard let self else { return }
            onDropMovingFiles?(urls, shelfOrigin)
            handoffToShelf()
        }
        dropView.onDropStagedFile = { [weak self] url in
            guard let self else { return }
            onDropStagedFile?(url, shelfOrigin)
            handoffToShelf()
        }
    }

    func arm(near point: NSPoint) {
        appearWork?.cancel()
        generation += 1

        if panel.isVisible {
            apply(.targeted)
            return
        }

        let work = DispatchWorkItem { [weak self] in self?.present(on: point) }
        appearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.appearDelay, execute: work)
    }

    func presentForPreview(targeted: Bool) {
        appearWork?.cancel()
        present(on: NSEvent.mouseLocation)
        if targeted { apply(.targeted) }
    }

    private func present(on point: NSPoint) {
        let screen = NotchGeometry.screen(containing: point)
        dock = NotchGeometry.dock(on: screen)
        layoutPad(on: screen)
        apply(.hidden, animated: false)
        panel.orderFrontRegardless()
        panel.layoutIfNeeded()
        island.screenDock = dock
        island.needsDisplay = true

        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.island.screenDock = self.dock
            self.island.needsDisplay = true
            // One frame at housing size, then the notch itself expands.
            self.apply(.targeted)
        }
    }

    /// The window is the *expanded* island's size and is centred on the housing.
    /// Only the black blob inside moves, so the spring is a shape change, not a
    /// window resize.
    private func layoutPad(on screen: NSScreen) {
        let scale = max(screen.backingScaleFactor, 1)
        model.notchWidth = dock.width
        model.notchHeight = dock.height

        var extra = max(model.expandedWidth - dock.width, 0)
        extra = (extra * scale).rounded() / scale
        if Int((extra * scale).rounded()) % 2 != 0 {
            extra += 1 / scale
        }

        let width = dock.width + extra
        let height = dock.height + ShelfDropPadModel.targetedDrop
        let x = (dock.minX * scale).rounded() / scale - extra / 2
        let y = (dock.maxY * scale).rounded() / scale - height
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        island.frame = dropView.bounds
        hosting.frame = dropView.bounds
        island.screenDock = dock
    }

    private func apply(_ phase: ShelfDropPadModel.Phase, animated: Bool = true) {
        if animated, model.phase == phase { return }

        labelToken += 1
        let token = labelToken
        if phase == .hidden {
            model.labelVisible = false
            model.hoverMove = nil
            island.hoverMove = nil
        }
        if model.phase != phase {
            model.setPhase(phase, animated: animated)
        }
        let width = model.shapeWidth
        let height = model.shapeHeight
        let radius = model.bottomRadius
        let revealLabel = phase != .hidden
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.allowsImplicitAnimation = true
                context.duration = Self.islandAnimationDuration
                island.animator().blobWidth = width
                island.animator().blobHeight = height
                island.animator().blobRadius = radius
            }
            if revealLabel {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.labelRevealDelay) { [weak self] in
                    guard let self, token == self.labelToken, self.model.phase != .hidden else { return }
                    self.model.labelVisible = true
                }
            }
        } else {
            island.blobWidth = width
            island.blobHeight = height
            island.blobRadius = radius
            model.labelVisible = revealLabel
        }
        island.needsDisplay = true
    }

    /// Drop accepted: hold the expanded island so the shelf can grow out of it,
    /// then ease the blob back into the housing.
    func handoffToShelf() {
        appearWork?.cancel()
        appearWork = nil
        guard panel.isVisible, model.phase != .hidden else { return }

        model.labelVisible = false
        generation += 1
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.generation == token, self.panel.isVisible else { return }
            self.apply(.hidden)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.islandAnimationDuration) { [weak self] in
                guard let self, self.generation == token, self.model.phase == .hidden else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    func retract() {
        appearWork?.cancel()
        appearWork = nil
        guard panel.isVisible else {
            apply(.hidden, animated: false)
            return
        }
        guard model.phase != .hidden else { return }

        apply(.hidden)
        generation += 1
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.islandAnimationDuration) { [weak self] in
            guard let self, self.generation == token, self.model.phase == .hidden else { return }
            self.panel.orderOut(nil)
        }
    }

    func dismiss() {
        retract()
    }
}
