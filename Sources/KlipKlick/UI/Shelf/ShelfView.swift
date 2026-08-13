import AppKit
import SwiftUI

/// The contents of one shelf window.
///
/// Reads its shelf out of the store by id on every redraw rather than holding a
/// copy, so a window can never show a stale name or a row that has already been
/// removed somewhere else.
struct ShelfView: View {
    @ObservedObject var store: ShelfStore
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

    private var palette: Palette { .resolve(colorScheme) }
    private var shelf: Shelf? { store.shelf(shelfID) }
    private var urls: [URL] { shelf?.items.map(\.url) ?? [] }

    /// Four tiles to a row. Wide enough to be worth opening, narrow enough that
    /// three shelves fit side by side without covering the window underneath.
    static let columns = 4
    static let width: CGFloat = 288
    private static let gridSpacing: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.divider)
            content
            if isHoveringShelf, shelf?.isEmpty == false {
                Divider().overlay(palette.divider)
                actionBar
            }
        }
        .frame(width: Self.width)
        .background(GlassSurface(palette: palette, opacity: Settings.shared.glassOpacity))
        .overlay(edge)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
        .background(dropCatcher)
        .onHover { isHoveringShelf = $0 }
        .animation(.easeInOut(duration: 0.14), value: isHoveringShelf)
        .animation(.easeInOut(duration: 0.14), value: isTargeted)
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
                // The handle covers the title area only, so the two buttons to
                // its right stay clickable without any hit-testing tricks.
                .overlay(dragHandle)

            headerButton("trash", "Empty this shelf") {
                store.removeAllItems(from: shelfID)
            }
            .opacity(shelf?.isEmpty == false ? 1 : 0)

            headerButton("xmark", "Close shelf", action: onClose)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
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
                    .foregroundStyle(status == nil ? palette.textSecondary : palette.accent)
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
            }
            // Three rows before it scrolls. Past that a shelf stops being a
            // glance and becomes a file browser, which is not what it is for.
            .frame(maxHeight: 3 * (ShelfTile.size + 14) + 2 * Self.gridSpacing + 20)
        } else {
            emptyState
        }
    }

    private func tile(_ item: ShelfItem) -> some View {
        ShelfTile(
            item: item,
            palette: palette,
            onDragBegan: onDragBegan,
            onDragEnded: { operation in
                onDragEnded(operation)
                // The destination may have moved the file rather than copied it.
                // Rather than guess which, look: `pruneMissing` drops rows whose
                // file is genuinely gone and leaves the rest alone.
                if operation.contains(.move) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        store.pruneMissing(in: shelfID)
                    }
                }
            },
            onOpen: { ShelfActions.open([item.url]) },
            onQuickLook: { ShelfActions.quickLook([item.url]) },
            onRemove: { store.remove(item: item.id, from: shelfID) },
            menuBuilder: { itemMenu(for: item) }
        )
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

    private var actionBar: some View {
        HStack(spacing: 2) {
            action("arrow.down.doc", "Move to the front Finder window") {
                moveToFinder()
            }
            action("doc.on.doc", "Copy files to the clipboard") {
                ShelfActions.copyToClipboard(urls)
                flash("Copied \(urls.count)")
            }
            action("eye", "Quick Look") { ShelfActions.quickLook(urls) }
            action("folder", "Reveal in Finder") { ShelfActions.revealInFinder(urls) }
            action("archivebox", "Compress to a zip") { compress() }

            Spacer(minLength: 0)

            action("square.and.arrow.up", "Share") { share() }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
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
        let count = urls.count
        ShelfActions.moveToFrontFinderWindow(urls) { sent in
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
        ShelfActions.compress(urls, named: name) { archive in
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
        ShelfActions.share(urls, from: view)
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
