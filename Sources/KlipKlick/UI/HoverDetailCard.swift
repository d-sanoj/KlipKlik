import AppKit
import SwiftUI

/// The three-line card describing the focused row.
///
/// It replaces the per-type icon chips the rows used to carry: the same
/// information (what this item is, where it came from) without spending vertical
/// space on every row for it.
struct HoverDetailCard: View {
    let item: ClipboardItem
    let now: Date

    @Environment(\.colorScheme) private var colorScheme

    private var palette: Palette { .resolve(colorScheme) }

    /// Fixed, so the window can be sized and placed before SwiftUI lays it out.
    static let size = CGSize(width: 176, height: 58)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            line("Type", item.kind.label)
            line("App", item.sourceApp ?? "Unknown")
            line("Time", item.absoluteTime(from: now))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 30, alignment: .leading)

            Text(value)
                .font(.system(size: 10.5))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// Hosts `HoverDetailCard` in its own window, parked to the left of the popup.
///
/// A child window rather than an overlay inside the popup, so the card can sit
/// outside the panel's bounds. It must never take focus: the popup hides on
/// `windowDidResignKey`, so a card that could become key would dismiss the very
/// list it describes.
final class DetailCardWindow {
    /// Gap between the popup's edge and the card.
    private static let gap: CGFloat = 8

    private let panel: NSPanel
    private var attachedTo: NSWindow?

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: HoverDetailCard.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // Purely informational: it must never intercept the pointer, least of all
        // the hover it is reporting on.
        panel.ignoresMouseEvents = true
    }

    /// Shows the card for `item`, vertically centred on `rowFrame`.
    ///
    /// `rowFrame` is the row's frame in its window's SwiftUI coordinates —
    /// top-left origin, y increasing downwards.
    func show(item: ClipboardItem, now: Date, rowFrame: CGRect, parent: NSWindow) {
        panel.contentView = NSHostingView(rootView: HoverDetailCard(item: item, now: now))
        panel.setContentSize(HoverDetailCard.size)
        panel.setFrameOrigin(origin(for: rowFrame, parent: parent))

        if attachedTo !== parent {
            attachedTo?.removeChildWindow(panel)
            // A child window rides along when the popup moves and goes away with
            // it, which is exactly the lifetime the card should have.
            parent.addChildWindow(panel, ordered: .above)
            attachedTo = parent
        }
        panel.orderFront(nil)
    }

    /// Moves an already-visible card, e.g. as the arrow keys walk the list.
    func move(to rowFrame: CGRect, parent: NSWindow) {
        guard panel.isVisible else { return }
        panel.setFrameOrigin(origin(for: rowFrame, parent: parent))
    }

    func hide() {
        attachedTo?.removeChildWindow(panel)
        attachedTo = nil
        panel.orderOut(nil)
    }

    /// Left of the popup by default; flips to the right when there is no room,
    /// and stays on screen either way.
    private func origin(for rowFrame: CGRect, parent: NSWindow) -> NSPoint {
        let card = HoverDetailCard.size
        let parentFrame = parent.frame
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = parentFrame.minX - card.width - Self.gap
        if x < visible.minX + 4 {
            x = parentFrame.maxX + Self.gap
        }
        x = min(max(x, visible.minX + 4), visible.maxX - card.width - 4)

        // SwiftUI's y runs down from the window's top edge; the screen's runs up.
        let rowCentreY = parentFrame.maxY - rowFrame.midY
        var y = rowCentreY - card.height / 2
        y = min(max(y, visible.minY + 4), visible.maxY - card.height - 4)

        return NSPoint(x: x, y: y)
    }
}
