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
    var isSelected = false
    var tint: Color = .accentColor
    let onMouseDown: (NSEvent.ModifierFlags) -> Void
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDragBegan: () -> Void
    let onDragEnded: (NSDragOperation) -> Void
    let onOpen: () -> Void
    let onRemove: () -> Void
    let menuBuilder: () -> NSMenu?
    var urls: () -> [URL] = { [] }
    var operationMask: () -> NSDragOperation = { [.copy, .generic] }
    var onSelectItem: (UUID) -> Void = { _ in }
    var onClearSelection: () -> Void = {}
    var onSelectAll: () -> Void = {}
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
        .overlay(dragLayer)
        .help("\(item.name) — \(item.sizeLabel)")
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? tint.opacity(0.22) : (isHovering ? palette.rowHover : .clear))

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
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? tint.opacity(0.9) : .clear, lineWidth: 1.5)
        )
    }

    private var dragLayer: some View {
        FileDragSource(
            urls: urls,
            onSessionBegan: onDragBegan,
            onSessionEnded: onDragEnded,
            onMouseDown: onMouseDown,
            onClick: onClick,
            onDoubleClick: onOpen,
            menuBuilder: menuBuilder,
            operationMask: operationMask,
            itemID: item.id,
            onSelectItem: onSelectItem,
            onClearSelection: onClearSelection,
            onSelectAll: onSelectAll,
            onRemove: onRemove,
            onHover: { isHovering = $0 }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
