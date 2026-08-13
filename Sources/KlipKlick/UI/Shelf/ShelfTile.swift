import AppKit
import SwiftUI

/// One item on a shelf: its preview, its name, and every gesture that acts on it.
///
/// The SwiftUI here is purely what you see. All pointer handling belongs to the
/// `FileDragSource` laid over the top — see that type for why the two are not
/// mixed.
struct ShelfTile: View {
    let item: ShelfItem
    let palette: Palette
    let onDragBegan: () -> Void
    let onDragEnded: (NSDragOperation) -> Void
    let onOpen: () -> Void
    let onQuickLook: () -> Void
    let onRemove: () -> Void
    let menuBuilder: () -> NSMenu?

    @ObservedObject private var thumbnails = ShelfThumbnails.shared
    @State private var isHovering = false

    static let size: CGFloat = 62

    var body: some View {
        VStack(spacing: 3) {
            preview
            Text(item.name)
                .font(.system(size: 9.5))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.size)
        }
        .overlay(alignment: .topTrailing) { removeButton }
        .overlay(dragLayer)
        .onHover { isHovering = $0 }
        .help("\(item.name) — \(item.sizeLabel)")
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? palette.rowHover : .clear)

            Image(nsImage: thumbnails.image(for: item))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.size - 14, height: Self.size - 14)
                // A reference whose file has gone is shown, not silently dropped:
                // the user put it there, and a tile vanishing on its own is
                // indistinguishable from the shelf losing things at random.
                .opacity(item.stillExists ? 1 : 0.35)

            if !item.stillExists {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.danger)
                    .offset(y: 12)
            }
        }
        .frame(width: Self.size, height: Self.size)
    }

    /// Only on hover, and only 14pt — a permanent close badge on every tile turns
    /// a shelf of eight files into sixteen things competing for attention.
    @ViewBuilder
    private var removeButton: some View {
        if isHovering {
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(palette.surface, palette.textSecondary)
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
            .help(item.origin == .staged ? "Remove and delete" : "Remove from shelf")
        }
    }

    /// Covers the preview, with a hole punched at the top-right corner so the
    /// remove badge drawn underneath it still receives clicks.
    private var dragLayer: some View {
        FileDragSource(
            urls: { [item.url] },
            onSessionBegan: onDragBegan,
            onSessionEnded: onDragEnded,
            onClick: onQuickLook,
            onDoubleClick: onOpen,
            menuBuilder: menuBuilder,
            passthroughRect: {
                // Only while the badge is actually there — otherwise a corner of
                // every tile would quietly refuse to start a drag.
                isHovering
                    ? CGRect(x: Self.size - 22, y: 0, width: 26, height: 26)
                    : .zero
            }
        )
        .frame(width: Self.size, height: Self.size)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
