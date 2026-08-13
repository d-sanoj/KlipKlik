import AppKit
import SwiftUI

/// The contents of one shelf window.
///
/// Reads its shelf out of the store by id on every redraw rather than holding a
/// copy, so a window can never show a stale name or a row that has already been
/// removed somewhere else.
struct ShelfView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var appearance: ShelfAppearance
    let shelfID: UUID
    let onClose: () -> Void
    /// Asks the window to take focus, which renaming needs and nothing else does.
    let onNeedsKeyWindow: (Bool) -> Void
    let onDragBegan: () -> Void
    let onDragEnded: (NSDragOperation) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isTargeted = false
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var isHoveringShelf = false
    @State private var status: String?
    @State private var selectedIDs: Set<UUID> = []
    @State private var selectionAnchor: UUID?

    private var palette: Palette { .resolve(colorScheme) }
    private var shelf: Shelf? { store.shelf(shelfID) }
    private var urls: [URL] { shelf?.items.map(\.url) ?? [] }

    /// Action-bar and bulk gestures use the selection when there is one.
    private var activeItems: [ShelfItem] {
        guard let items = shelf?.items else { return [] }
        if selectedIDs.isEmpty { return items }
        return items.filter { selectedIDs.contains($0.id) }
    }

    private var activeURLs: [URL] { activeItems.map(\.url) }

    /// Four tiles to a row. Wide enough to be worth opening, narrow enough that
    /// three shelves fit side by side without covering the window underneath.
    static let columns = 4
    static let width: CGFloat = 288
    private static let gridSpacing: CGFloat = 8
    /// After this many rows the grid scrolls instead of growing the window.
    private static let maxVisibleRows = 3
    /// Icon plus the caption under it.
    private static let tileRowHeight: CGFloat = ShelfTile.size + 16
    private static let gridPadding: CGFloat = 20

    /// One row for 1–4 files, two for 5–8, three for 9+, then it scrolls.
    static func gridHeight(for itemCount: Int) -> CGFloat {
        let rows = max(1, Int(ceil(Double(itemCount) / Double(columns))))
        let visible = min(rows, maxVisibleRows)
        return CGFloat(visible) * tileRowHeight
            + CGFloat(max(0, visible - 1)) * gridSpacing
            + gridPadding
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.divider)
            content
            if shelf?.isEmpty == false {
                hoverActions
            }
        }
        .frame(width: Self.width)
        .background(GlassSurface(palette: palette, opacity: Settings.shared.glassOpacity))
        .overlay(edge)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
        .background(dropCatcher)
        .onHover { isHoveringShelf = $0 }
        .scaleEffect(
            x: appearance.revealed ? 1 : appearance.hiddenScaleX,
            y: appearance.revealed ? 1 : appearance.hiddenScaleY,
            anchor: .top
        )
        .offset(y: appearance.revealed ? 0 : appearance.hiddenOffset)
        .opacity(appearance.revealed ? 1 : 0)
        .animation(appearance.revealAnimation, value: appearance.revealed)
        .animation(.easeInOut(duration: 0.14), value: isTargeted)
        .onKeyPress(.escape) {
            selectedIDs = []
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .shelfSelectAll)) { note in
            guard note.object as? UUID == shelfID else { return }
            selectedIDs = Set(shelf?.items.map(\.id) ?? [])
        }
        .onReceive(NotificationCenter.default.publisher(for: .shelfDeselectAll)) { note in
            guard note.object as? UUID == shelfID else { return }
            selectedIDs = []
        }
        .focusable()
    }

    // MARK: Chrome

    /// The shelf's tint as a hairline, brightening to a full ring while a drag is
    /// over it — the only feedback that says "let go here" before you let go.
    private var edge: some View {
        RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
            .strokeBorder(
                Color(nsColor: shelf?.tint ?? .controlAccentColor)
                    .opacity(isTargeted ? 0.95 : 0.35),
                lineWidth: isTargeted ? 2.5 : 1
            )
    }

    private var header: some View {
        HStack(spacing: 7) {
            title
                // The handle covers the title area only, so the close button to
                // its right stays clickable without any hit-testing tricks.
                .overlay(dragHandle)

            intakeBadge
            headerButton("xmark", "Close shelf", action: onClose)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    private var intakeBadge: some View {
        let intake = shelf?.intake ?? .copy
        let tint = Color(nsColor: shelf?.tint ?? .controlAccentColor)
        return HStack(spacing: 3) {
            Image(systemName: intake.symbol)
                .font(.system(size: 8, weight: .bold))
            Text(intake.title)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.16))
        )
        .help(intake.help)
    }

    private var title: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(nsColor: shelf?.tint ?? .controlAccentColor))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("", text: $draftName, onCommit: commitRename)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                } else {
                    Text(shelf?.name ?? "Shelf")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                }

                Text(status ?? shelf?.summary ?? "Empty")
                    .font(.system(size: 10))
                    .foregroundStyle(
                        status != nil
                            ? palette.accent
                            : palette.textSecondary
                    )
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
    }

    /// Dropped while renaming, or the text field could never be clicked into.
    @ViewBuilder
    private var dragHandle: some View {
        if !isRenaming {
            WindowDragHandle(onDoubleClick: beginRename, menuBuilder: shelfMenu)
        }
    }

    private func headerButton(
        _ symbol: String, _ help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        if let shelf, !shelf.items.isEmpty {
            let height = Self.gridHeight(for: shelf.items.count)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(ShelfTile.size), spacing: Self.gridSpacing),
                        count: Self.columns
                    ),
                    spacing: Self.gridSpacing
                ) {
                    ForEach(shelf.items) { item in
                        tile(item)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .top)
                .overlay {
                    // On top of the grid so empty space is clickable, with
                    // hit-testing punched through the tiles themselves.
                    ShelfCanvas(
                        currentSelection: { selectedIDs },
                        onApplySelection: { selectedIDs = $0 },
                        onPress: { onNeedsKeyWindow(true) },
                        onSelectAll: { selectedIDs = Set(shelf.items.map(\.id)) }
                    )
                }
            }
            .frame(height: height)
            .onChange(of: shelf.items.map(\.id)) { _, ids in
                selectedIDs = selectedIDs.intersection(ids)
            }
        } else {
            emptyState
        }
    }

    private func tile(_ item: ShelfItem) -> some View {
        let tint = Color(nsColor: shelf?.tint ?? .controlAccentColor)
        return ShelfTile(
            item: item,
            palette: palette,
            isSelected: selectedIDs.contains(item.id),
            tint: tint,
            onMouseDown: { flags in
                onNeedsKeyWindow(true)
                select(item, modifiers: flags, collapsing: false)
            },
            onClick: { select(item, modifiers: $0, collapsing: true) },
            onDragBegan: {
                onDragBegan()
            },
            onDragEnded: { operation in
                onDragEnded(operation)
                guard !operation.isEmpty else { return }
                let ids = dragIDs(startingAt: item)
                store.takeOut(items: ids, from: shelfID)
                selectedIDs.subtract(ids)
            },
            onOpen: {
                let targets = selectedIDs.contains(item.id)
                    ? activeURLs
                    : [item.url]
                ShelfActions.open(targets)
            },
            onRemove: { store.remove(item: item.id, from: shelfID) },
            menuBuilder: { itemMenu(for: item) },
            urls: { dragURLs(startingAt: item) },
            operationMask: {
                shelf?.intake == .move
                    ? [.move, .copy, .generic]
                    : [.copy, .generic]
            },
            onSelectItem: { selectedIDs.insert($0) },
            onClearSelection: { selectedIDs = [] },
            onSelectAll: { selectedIDs = Set(shelf?.items.map(\.id) ?? []) }
        )
    }

    private func select(_ item: ShelfItem, modifiers: NSEvent.ModifierFlags, collapsing: Bool) {
        let items = shelf?.items ?? []
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)

        // ⌘ and ⇧ are applied on mouse-down only. Applying them again on mouse-up
        // toggled the same tile twice, so a ⌘-click appeared to do nothing.
        if collapsing {
            if command || shift { return }
            selectedIDs = [item.id]
            selectionAnchor = item.id
            return
        }

        if command {
            if selectedIDs.contains(item.id) {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
            selectionAnchor = item.id
        } else if shift,
                  let anchor = selectionAnchor,
                  let from = items.firstIndex(where: { $0.id == anchor }),
                  let to = items.firstIndex(where: { $0.id == item.id }) {
            let slice = items[min(from, to)...max(from, to)]
            selectedIDs = Set(slice.map(\.id))
        } else if !selectedIDs.contains(item.id) {
            selectedIDs = [item.id]
            selectionAnchor = item.id
        }
    }

    private func dragIDs(startingAt item: ShelfItem) -> [UUID] {
        if selectedIDs.contains(item.id) { return Array(selectedIDs) }
        return [item.id]
    }

    private func dragURLs(startingAt item: ShelfItem) -> [URL] {
        let wanted = Set(dragIDs(startingAt: item))
        return (shelf?.items ?? []).filter { wanted.contains($0.id) }.map(\.url)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(palette.textTertiary)
            Text("Drop files here")
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 92)
    }

    // MARK: Actions

    /// Always occupies a row so hover only fades the buttons in — inserting
    /// this on the way in, and removing it on the way out, is what made the
    /// whole panel bounce.
    private var hoverActions: some View {
        VStack(spacing: 0) {
            Divider().overlay(palette.divider)
                .opacity(isHoveringShelf ? 1 : 0)
            HStack(spacing: 2) {
                action("arrow.down.doc", "Move to the front Finder window") {
                    moveToFinder()
                }
                action("doc.on.doc", "Copy files to the clipboard") {
                    ShelfActions.copyToClipboard(activeURLs)
                    flash("Copied \(activeURLs.count)")
                }
                action("eye", "Quick Look") { ShelfActions.quickLook(activeURLs) }
                action("folder", "Reveal in Finder") { ShelfActions.revealInFinder(activeURLs) }
                action("archivebox", "Compress to a zip") { compress() }

                Spacer(minLength: 0)

                action("square.and.arrow.up", "Share") { share() }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .opacity(isHoveringShelf ? 1 : 0)
            .allowsHitTesting(isHoveringShelf)
            .animation(.easeOut(duration: 0.12), value: isHoveringShelf)
        }
    }

    private func action(
        _ symbol: String, _ help: String, perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Menus

    /// AppKit, because `WindowDragHandleView` owns the right-click on the header
    /// and pops this itself — the same arrangement the tiles use.
    private func shelfMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ShelfMenuItem(title: "Rename…") { beginRename() })

        let colours = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, tint) in Shelf.tints.enumerated() {
            let entry = ShelfMenuItem(title: tint.name) { store.setTint(shelfID, to: index) }
            entry.state = shelf?.tintIndex == index ? .on : .off
            submenu.addItem(entry)
        }
        colours.submenu = submenu
        menu.addItem(colours)

        menu.addItem(.separator())
        menu.addItem(ShelfMenuItem(title: "Copy Paths") { ShelfActions.copyPaths(urls) })
        menu.addItem(ShelfMenuItem(title: "Reveal in Finder") {
            ShelfActions.revealInFinder(urls)
        })

        menu.addItem(.separator())
        menu.addItem(ShelfMenuItem(title: "Empty Shelf") {
            store.removeAllItems(from: shelfID)
        })
        menu.addItem(ShelfMenuItem(title: "Close Shelf") { onClose() })
        return menu
    }

    /// AppKit rather than SwiftUI, because `FileDragSourceView` owns the
    /// right-click on a tile and pops this itself.
    private func itemMenu(for item: ShelfItem) -> NSMenu {
        let menu = NSMenu()

        menu.addItem(ShelfMenuItem(title: "Open") { ShelfActions.open([item.url]) })
        menu.addItem(ShelfMenuItem(title: "Quick Look") { ShelfActions.quickLook([item.url]) })
        menu.addItem(
            ShelfMenuItem(title: "Reveal in Finder") { ShelfActions.revealInFinder([item.url]) }
        )

        let openers = ShelfActions.openers(for: item.url)
        if !openers.isEmpty {
            let parent = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for application in openers.prefix(12) {
                let name = FileManager.default.displayName(atPath: application.path)
                submenu.addItem(ShelfMenuItem(title: name) {
                    ShelfActions.open([item.url], withApplicationAt: application)
                })
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }

        menu.addItem(.separator())
        menu.addItem(ShelfMenuItem(title: "Copy") { ShelfActions.copyToClipboard([item.url]) })
        menu.addItem(ShelfMenuItem(title: "Copy Path") { ShelfActions.copyPaths([item.url]) })

        menu.addItem(.separator())
        let removeTitle = item.origin == .staged ? "Delete" : "Remove from Shelf"
        menu.addItem(ShelfMenuItem(title: removeTitle) {
            store.remove(item: item.id, from: shelfID)
        })

        return menu
    }

    // MARK: Behaviour

    private func beginRename() {
        draftName = shelf?.name ?? ""
        onNeedsKeyWindow(true)
        isRenaming = true
    }

    private func commitRename() {
        store.rename(shelfID, to: draftName)
        isRenaming = false
        onNeedsKeyWindow(false)
    }

    private func moveToFinder() {
        guard ShelfActions.canMoveToFrontFinderWindow else {
            flash(
                AccessibilityPermission.isTrusted
                    ? "Open a Finder window first"
                    : "Needs Accessibility"
            )
            return
        }
        let count = activeURLs.count
        ShelfActions.moveToFrontFinderWindow(activeURLs) { sent in
            guard sent else { return }
            flash("Moving \(count)…")
            // Finder does the move; the shelf finds out the same way it does for
            // a dropped move — by looking at whether the files are still there.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                store.pruneMissing(in: shelfID)
            }
        }
    }

    private func compress() {
        let name = shelf?.name ?? "Shelf"
        flash("Compressing…")
        ShelfActions.compress(activeURLs, named: name) { archive in
            guard let archive else {
                flash("Couldn't compress")
                return
            }
            store.add(urls: [archive], to: shelfID)
            flash("Zipped")
        }
    }

    private func share() {
        // The picker needs a real view to hang off; the window's content view is
        // the only one this layer can reach.
        guard let view = NSApp.windows
            .first(where: { ($0 as? ShelfPanel)?.shelfID == shelfID })?.contentView
        else { return }
        ShelfActions.share(activeURLs, from: view)
    }

    /// Replaces the summary line for a moment. A shelf has no room for alerts,
    /// and an action that produces no visible change reads as a broken button.
    private func flash(_ message: String) {
        status = message
        let shown = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if status == shown { status = nil }
        }
    }

    // MARK: Drops

    private var dropCatcher: some View {
        ShelfDropCatcher(
            onFiles: { store.add(urls: $0, to: shelfID) },
            onStagedFile: { store.add(promised: $0, to: shelfID) },
            onTargeting: { isTargeted = $0 }
        )
    }
}

/// An `NSMenuItem` that runs a closure, so shelf menus can be built inline
/// instead of routing every entry through a selector on some controller.
final class ShelfMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
