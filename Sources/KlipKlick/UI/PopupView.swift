import SwiftUI

struct PopupView: View {
    @ObservedObject var viewModel: PopupViewModel
    @ObservedObject var settings = Settings.shared
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchFocused: Bool

    private var palette: Palette { .resolve(colorScheme) }

    var body: some View {
        // No rules between the header, list, and footer: the padding already
        // separates them, and hairlines over glass read as scratches.
        VStack(spacing: 0) {
            header
            list
            footer
        }
        .frame(width: settings.popupSize.width)
        // Frosted glass: blurred backdrop, Liquid Glass refraction, the user's
        // tint, and a specular sheen. No hairline border — the glass edge and
        // the sheen define the boundary.
        .background(
            GlassSurface(palette: palette, opacity: settings.glassOpacity)
        )
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
        .onAppear { searchFocused = true }
    }

    // MARK: Header

    private var header: some View {
        ZStack(alignment: .leading) {
            TextField("Search clipboard history", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(palette.textPrimary)
                .focused($searchFocused)
                .padding(.leading, 26)
                .padding(.trailing, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.searchCornerRadius, style: .continuous)
                        .fill(palette.searchBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.searchCornerRadius, style: .continuous)
                        .strokeBorder(palette.searchBorder, lineWidth: 1)
                )

            SearchGlyph(color: palette.textTertiary)
                .padding(.leading, 10)
                .allowsHitTesting(false)
        }
        .padding(Metrics.headerPadding)
    }

    // MARK: List

    private var listHeight: CGFloat {
        let height = CGFloat(viewModel.flatItems.count) * Metrics.rowHeight
            + Metrics.listPadding * 2
        return min(max(height, Metrics.listMinHeight), Metrics.maxListHeight)
    }

    private var list: some View {
        scrollingList
            .frame(height: listHeight)
            // Handed to PopupController, which parks the detail card beside the
            // focused row in a window of its own.
            .onPreferenceChange(FocusedRowKey.self) { viewModel.focusedRow = $0 }
    }

    private var scrollingList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // One flat list. Pinned items live behind the footer button
                // rather than in a section stacked on top of the history.
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.flatItems) { row(for: $0) }

                    if viewModel.isEmpty { emptyState }
                }
                .padding(Metrics.listPadding)
            }
            .scrollIndicators(.automatic)
            .onChange(of: viewModel.scrollTick) { _, _ in
                guard let id = viewModel.selectedItem?.id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func row(for item: ClipboardItem) -> some View {
        ItemRow(
            item: item,
            isSelected: viewModel.selectionVisible && viewModel.selectedItem?.id == item.id,
            isHovered: viewModel.hoveredID == item.id,
            now: viewModel.now,
            palette: palette,
            onActivate: { viewModel.activate(item, invertFormatting: $0) },
            onTogglePin: { viewModel.togglePin(item) },
            onHover: { hovering in
                if hovering {
                    viewModel.hoveredID = item.id
                    if let index = viewModel.flatIndex(of: item) {
                        viewModel.selection = index
                        // Reaching for a row counts as reaching for the list.
                        viewModel.selectionVisible = true
                    }
                } else if viewModel.hoveredID == item.id {
                    viewModel.hoveredID = nil
                }
            }
        )
        .id(item.id)
    }

    private var emptyState: some View {
        Text(viewModel.emptyMessage)
            .font(.system(size: 13))
            .foregroundStyle(palette.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 10)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 0) {
            FooterTextButton(
                title: "Clear History",
                idleColor: palette.textSecondary,
                hoverColor: palette.danger
            ) {
                viewModel.clearHistory()
            }

            Spacer(minLength: 6)

            PinnedShelfButton(
                count: viewModel.pinnedCount,
                isActive: viewModel.showingPinned,
                palette: palette
            ) {
                viewModel.togglePinnedShelf()
            }

            Spacer(minLength: 6)

            HStack(spacing: 10) {
                Text(viewModel.itemCountLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textTertiary)

                GearButton(palette: palette) {
                    viewModel.onClose?()
                    viewModel.onOpenPreferences?()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

// MARK: - Pieces

private struct SearchGlyph: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let s = size.width / 24
            context.stroke(
                Path(ellipseIn: CGRect(
                    x: 3 * s, y: 3 * s, width: 14 * s, height: 14 * s
                )),
                with: .color(color),
                lineWidth: 2 * s
            )
            var handle = Path()
            handle.move(to: CGPoint(x: 15.2 * s, y: 15.2 * s))
            handle.addLine(to: CGPoint(x: 21 * s, y: 21 * s))
            context.stroke(
                handle,
                with: .color(color),
                style: StrokeStyle(lineWidth: 2 * s, lineCap: .round)
            )
        }
        .frame(width: 13, height: 13)
    }
}

/// Footer toggle between the history and the pinned shelf.
private struct PinnedShelfButton: View {
    let count: Int
    let isActive: Bool
    let palette: Palette
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isActive ? "pin.fill" : "pin")
                    .font(.system(size: 10))
                Text("Pinned")
                    .font(.system(size: 12))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isActive ? palette.accent : palette.textTertiary)
                }
            }
            .foregroundStyle(isActive ? palette.accent : palette.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isActive || isHovering ? palette.rowHover : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isActive ? "Back to history" : "Show pinned items")
    }
}

private struct FooterTextButton: View {
    let title: String
    let idleColor: Color
    let hoverColor: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(isHovering ? hoverColor : idleColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct GearButton: View {
    let palette: Palette
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text("⚙")
                .font(.system(size: 15))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovering ? palette.rowHover : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Preferences")
    }
}
