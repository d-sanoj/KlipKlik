import SwiftUI

/// One clipboard entry.
///
/// Hovering swaps the timestamp for the pin button in place — the trailing slot
/// is a fixed width so nothing shifts during the crossfade. Deleting is ⌘⌫ on
/// the selected row; there is no per-row button for it.
struct ItemRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let isHovered: Bool
    let now: Date
    let palette: Palette
    let onActivate: (_ invertFormatting: Bool) -> Void
    let onTogglePin: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: Metrics.rowSpacing) {
            Text(item.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(palette.textPrimary)

            Spacer(minLength: 6)

            trailingSlot
        }
        .padding(.horizontal, Metrics.rowHorizontalPadding)
        .frame(height: Metrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Metrics.rowCornerRadius, style: .continuous)
                .fill(rowBackground)
        )
        // Rows are never dimmed. The design fades un-hovered rows to 0.7, which
        // it can afford over an opaque panel; over clear glass that fights
        // whatever shows through, so every row stays fully opaque.
        .background(focusFrameReporter)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            // SwiftUI taps carry no modifier info, so read the live flags:
            // ⌥⇧ inverts the strip-formatting setting, matching the key handling.
            let flags = NSEvent.modifierFlags
            onActivate(flags.contains(.option) && flags.contains(.shift))
        }
        .onHover(perform: onHover)
    }

    private var rowBackground: Color {
        if isSelected { return palette.rowSelected }
        if isHovered { return palette.rowHover }
        return .clear
    }

    /// Publishes the focused row's position so the detail card can be parked
    /// beside it. Keyed off selection, not hover: hovering moves the selection
    /// too, so this covers the mouse and the arrow keys alike.
    @ViewBuilder
    private var focusFrameReporter: some View {
        if isSelected {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: FocusedRowKey.self,
                    // `.global` is the window's own space, which is what the
                    // card's window needs to place itself on screen.
                    value: FocusedRow(id: item.id, frame: geometry.frame(in: .global))
                )
            }
        }
    }

    /// A pinned row shows its pin whether or not the pointer is on it, so the
    /// pin is both the state and the way to undo it — one click to unpin.
    private var showsPin: Bool { isHovered || item.pinned }

    private var trailingSlot: some View {
        ZStack(alignment: .trailing) {
            Text(item.relativeTime(from: now))
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .opacity(showsPin ? 0 : 1)

            IconButton(action: onTogglePin) {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundStyle(item.pinned ? palette.accent : palette.textPrimary)
            }
            .help(item.pinned ? "Unpin" : "Pin")
            .opacity(showsPin ? 1 : 0)
            .allowsHitTesting(showsPin)
        }
        .frame(width: Metrics.trailingSlotWidth, height: 22, alignment: .trailing)
        .animation(.easeInOut(duration: 0.12), value: showsPin)
    }
}

/// Which row is focused and where it sits in the popup's window.
struct FocusedRow: Equatable {
    let id: UUID
    let frame: CGRect
}

struct FocusedRowKey: PreferenceKey {
    static let defaultValue: FocusedRow? = nil

    static func reduce(value: inout FocusedRow?, nextValue: () -> FocusedRow?) {
        value = value ?? nextValue()
    }
}

/// A 22pt borderless button that brightens on hover, as the design's
/// `style-hover="opacity: 1"` does.
private struct IconButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content

    @State private var isHovering = false

    var body: some View {
        Button(action: action) { content }
            .buttonStyle(.plain)
            .frame(width: 22, height: 22)
            .opacity(isHovering ? 1 : 0.75)
            .onHover { isHovering = $0 }
    }
}
