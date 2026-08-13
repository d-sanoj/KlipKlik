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
            TextField("Search", text: $viewModel.query)
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
            },
            canShelve: viewModel.canShelve(item),
            onAddToShelf: { viewModel.addToShelf(item) }
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
                title: "Clear",
                idleColor: palette.textSecondary,
                hoverColor: palette.danger
            ) {
                viewModel.clearHistory()
            }

            Spacer(minLength: 6)

            HStack(spacing: 2) {
                EyedropperButton(palette: palette) { viewModel.onPickColor?() }

                FooterIconButton(
                    systemName: "text.viewfinder",
                    help: "Grab text from the screen",
                    palette: palette
                ) {
                    viewModel.onGrabText?()
                }
            }

            Spacer(minLength: 6)

            HStack(spacing: 8) {
                Text(viewModel.itemCountLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textTertiary)

                // Plain text like Clear, not a pill: it lights up accent on
                // hover, and stays lit while the shelf is the thing on screen.
                FooterTextButton(
                    title: viewModel.pinnedCount > 0
                        ? "Pinned \(viewModel.pinnedCount)" : "Pinned",
                    idleColor: viewModel.showingPinned
                        ? palette.accent : palette.textSecondary,
                    hoverColor: palette.accent
                ) {
                    viewModel.togglePinnedShelf()
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


/// Footer button for an SF Symbol, sized to sit beside the drawn eyedropper.
private struct FooterIconButton: View {
    let systemName: String
    let help: String
    let palette: Palette
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovering ? palette.rowHover : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// The eyedropper mark, drawn rather than taken from SF Symbols so it matches
/// the rest of the popup's line art. Laid out in a 512 box and scaled down.
private struct EyedropperGlyph: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 512
            let stroke = StrokeStyle(lineWidth: 22 * s, lineCap: .round, lineJoin: .round)

            // Bulb, and the collar crossing it at a right angle.
            capsule(&context, 396, 116, 104, 44, -45, s, stroke)
            capsule(&context, 330, 182, 104, 22, 45, s, stroke)

            // Barrel: two parallel edges with a horizontal step between them.
            var barrel = Path()
            barrel.move(to: point(276, 168, s));  barrel.addLine(to: point(150, 294, s))
            barrel.move(to: point(344, 236, s));  barrel.addLine(to: point(218, 362, s))
            barrel.move(to: point(186, 258, s));  barrel.addLine(to: point(310, 258, s))
            context.stroke(barrel, with: .color(color), style: stroke)

            // Tip: the edges close into a rounded nose.
            var tip = Path()
            tip.move(to: point(150, 294, s))
            tip.addCurve(to: point(108, 380, s), control1: point(108, 336, s), control2: point(96, 358, s))
            tip.addCurve(to: point(218, 362, s), control1: point(132, 416, s), control2: point(176, 404, s))
            context.stroke(tip, with: .color(color), style: stroke)

            // The drop below the tip.
            var drop = Path()
            drop.move(to: point(76, 408, s))
            drop.addCurve(to: point(36, 462, s), control1: point(66, 428, s), control2: point(36, 444, s))
            drop.addCurve(to: point(116, 462, s), control1: point(36, 494, s), control2: point(116, 494, s))
            drop.addCurve(to: point(76, 408, s), control1: point(116, 444, s), control2: point(86, 428, s))
            context.stroke(drop, with: .color(color), style: stroke)
        }
        .frame(width: 15, height: 15)
    }

    private func point(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) -> CGPoint {
        CGPoint(x: x * s, y: y * s)
    }

    /// A rounded bar of `halfLen` by `halfWide`, centred and rotated in place.
    private func capsule(
        _ context: inout GraphicsContext,
        _ cx: CGFloat, _ cy: CGFloat,
        _ halfLen: CGFloat, _ halfWide: CGFloat,
        _ degrees: CGFloat, _ s: CGFloat, _ stroke: StrokeStyle
    ) {
        let bar = Path(
            roundedRect: CGRect(x: -halfLen, y: -halfWide, width: halfLen * 2, height: halfWide * 2),
            cornerRadius: halfWide
        )
        let placed = CGAffineTransform(translationX: cx * s, y: cy * s)
            .rotated(by: degrees * .pi / 180)
            .scaledBy(x: s, y: s)
        context.stroke(bar.applying(placed), with: .color(color), style: stroke)
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

/// Footer eyedropper: samples a pixel anywhere on screen and copies its hex.
private struct EyedropperButton: View {
    let palette: Palette
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            EyedropperGlyph(color: palette.textSecondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovering ? palette.rowHover : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Pick a colour from the screen")
    }
}
