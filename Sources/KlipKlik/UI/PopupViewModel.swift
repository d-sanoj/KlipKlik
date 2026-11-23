import Combine
import SwiftUI

/// The popup's type filter: which kinds of item the list shows.
enum KindFilter: String, CaseIterable, Identifiable {
    case all, text, links, images, colors, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .text: return "Text"
        case .links: return "Links"
        case .images: return "Images"
        case .colors: return "Colours"
        case .files: return "Files"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .text: return "text.alignleft"
        case .links: return "link"
        case .images: return "photo"
        case .colors: return "paintpalette"
        case .files: return "doc"
        }
    }

    func includes(_ kind: ClipKind) -> Bool {
        switch self {
        case .all: return true
        case .text: return kind == .text || kind == .rich
        case .links: return kind == .link
        case .images: return kind == .image
        case .colors: return kind == .color
        case .files: return [.file, .folder, .video, .audio].contains(kind)
        }
    }
}

/// Drives the popup: what's on screen, what's selected, and what the keyboard
/// and mouse do about it.
final class PopupViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var kindFilter: KindFilter = .all
    /// Index into `flatItems` — pinned first, then recent, matching reading order.
    @Published var selection: Int = 0
    @Published var pinnedItems: [ClipboardItem] = []
    @Published var recentItems: [ClipboardItem] = []
    @Published var hoveredID: UUID?
    /// The selected row and where it sits, reported by the list. Drives the
    /// detail card, so it tracks the arrow keys as well as the pointer.
    @Published var focusedRow: FocusedRow?
    /// Footer toggle: the list shows pinned items instead of the history.
    @Published var showingPinned = false
    /// Nothing is highlighted until the user reaches for the list. Opening onto
    /// a pre-selected first row reads as noise; ↩ still pastes it regardless.
    @Published var selectionVisible = false
    /// Bumped to ask the view to scroll the selected row into sight.
    @Published var scrollTick: Int = 0
    /// Re-read when the popup opens so relative timestamps are fresh.
    @Published var now: Date = Date()

    let store: HistoryStore

    /// (item, invertFormatting) — see `Settings.stripFormatting`.
    var onActivate: ((ClipboardItem, Bool) -> Void)?
    var onClose: (() -> Void)?
    var onOpenPreferences: (() -> Void)?
    var onPickColor: (() -> Void)?
    var onGrabText: (() -> Void)?
    var onScrollCapture: (() -> Void)?
    /// Puts a file item's files on a shelf. Returns false when there was nothing
    /// shelvable, so the caller can leave the popup open rather than closing it
    /// on an action that did nothing.
    var onAddToShelf: ((ClipboardItem) -> Bool)?
    /// Whether the shelf action should be offered for this item at all.
    var canAddToShelf: ((ClipboardItem) -> Bool)?
    /// Copies text the popup produced itself (a colour in another notation).
    var onCopyText: ((String) -> Void)?
    /// Opens or retargets the preview beside the popup.
    var onPreview: ((ClipboardItem) -> Void)?
    /// Floats an item on the screen, above every window.
    var onFloat: ((ClipboardItem) -> Void)?

    private var cancellables = Set<AnyCancellable>()

    init(store: HistoryStore) {
        self.store = store

        Publishers.CombineLatest3(store.$items, $query, $kindFilter)
            .sink { [weak self] items, query, kindFilter in
                guard let self else { return }
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                let filtered = items.filter {
                    kindFilter.includes($0.kind) && (trimmed.isEmpty || Self.matches($0, trimmed))
                }
                pinnedItems = filtered.filter(\.pinned)
                recentItems = filtered.filter { !$0.pinned }
                // Keep the selection in range as the list shrinks under a search.
                selection = min(selection, max(pinnedItems.count + recentItems.count - 1, 0))
            }
            .store(in: &cancellables)
    }

    /// The search matches the row's title, the full text, and the words read
    /// out of a copied picture — so a screenshot is found by what it says.
    private static func matches(_ item: ClipboardItem, _ query: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if item.title.range(of: query, options: options) != nil { return true }
        // The first 50,000 characters: enough for anything a person searches a
        // clipboard for, and a cap on the cost of a huge copy per keystroke.
        if let text = item.plainText, text.prefix(50_000).range(of: query, options: options) != nil {
            return true
        }
        if let text = item.recognizedText, text.range(of: query, options: options) != nil { return true }
        return false
    }

    /// Tab and ⇧Tab step through the type filters.
    func cycleKindFilter(by step: Int) {
        let all = KindFilter.allCases
        let index = all.firstIndex(of: kindFilter) ?? 0
        kindFilter = all[(index + step + all.count) % all.count]
        selection = 0
        selectionVisible = false
        scrollTick += 1
    }

    /// What the list is actually showing: the history, or the pinned shelf
    /// behind the footer button.
    var flatItems: [ClipboardItem] { showingPinned ? pinnedItems : recentItems }

    var totalCount: Int { store.items.count }

    var pinnedCount: Int { store.items.count { $0.pinned } }

    var isEmpty: Bool { flatItems.isEmpty }

    /// What to say when the list has nothing in it.
    var emptyMessage: String {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return "No matches" }
        if kindFilter != .all { return "No \(kindFilter.title.lowercased()) yet" }
        return showingPinned ? "Nothing pinned yet" : "Nothing copied yet"
    }

    func togglePinnedShelf() {
        showingPinned.toggle()
        selection = 0
        selectionVisible = false
        scrollTick += 1
    }

    var itemCountLabel: String {
        let count = totalCount
        return "\(count) item\(count == 1 ? "" : "s")"
    }

    var selectedItem: ClipboardItem? {
        let items = flatItems
        guard items.indices.contains(selection) else { return nil }
        return items[selection]
    }

    /// Position of an item in the flattened list, for keyboard/mouse agreement.
    func flatIndex(of item: ClipboardItem) -> Int? {
        flatItems.firstIndex { $0.id == item.id }
    }

    func resetForShow() {
        query = ""
        kindFilter = .all
        selection = 0
        selectionVisible = false
        showingPinned = false
        hoveredID = nil
        // `focusedRow` is deliberately left alone: it is fed by a SwiftUI
        // preference, which only re-fires when the reported value *changes*.
        // Clearing it here would strand the detail card on any reopen that
        // lands on the same row with the same layout.
        now = Date()
        scrollTick += 1
    }

    // MARK: Navigation

    func moveSelection(by delta: Int) {
        let count = flatItems.count
        guard count > 0 else { return }

        // The first keypress reveals the selection where it already sits rather
        // than stepping past it, so ↓ lands on the first row, not the second.
        guard selectionVisible else {
            selectionVisible = true
            selection = delta > 0 ? 0 : count - 1
            scrollTick += 1
            return
        }

        // Clamp rather than wrap — wrapping past the end of a long history is
        // disorienting when you're holding the arrow key down.
        selection = min(max(selection + delta, 0), count - 1)
        scrollTick += 1
    }

    func select(index: Int) {
        guard flatItems.indices.contains(index) else { return }
        selection = index
        selectionVisible = true
        scrollTick += 1
    }

    // MARK: Actions

    func activateSelected(invertFormatting: Bool = false) {
        guard let item = selectedItem else { return }
        onActivate?(item, invertFormatting)
    }

    func activate(_ item: ClipboardItem, invertFormatting: Bool = false) {
        onActivate?(item, invertFormatting)
    }

    func togglePin(_ item: ClipboardItem) {
        store.togglePin(item)
    }

    func togglePinSelected() {
        guard let item = selectedItem else { return }
        store.togglePin(item)
    }

    func deleteSelected() {
        guard let item = selectedItem else { return }
        store.remove(item)
    }

    func canShelve(_ item: ClipboardItem) -> Bool {
        canAddToShelf?(item) ?? false
    }

    /// ⌥S on the selected row, and the row's context menu.
    func addToShelf(_ item: ClipboardItem) {
        guard onAddToShelf?(item) == true else { return }
        onClose?()
    }

    func addSelectedToShelf() {
        guard let item = selectedItem else { return }
        addToShelf(item)
    }

    /// The context menu's "Copy Colour As".
    func copyColor(_ item: ClipboardItem, as format: ColorFormat) {
        guard let hex = item.colorHex, let components = ColorFormat.components(fromHex: hex)
        else { return }
        onCopyText?(format.string(for: components))
    }

    func preview(_ item: ClipboardItem) {
        onPreview?(item)
    }

    func float(_ item: ClipboardItem) {
        onFloat?(item)
    }

    /// ⌥F on the selected row.
    func floatSelected() {
        guard let item = selectedItem else { return }
        onFloat?(item)
    }

    /// Space and ⌘Y. Reveals the selection too, so it is clear which row the
    /// preview belongs to.
    func previewSelected() {
        guard let item = selectedItem else { return }
        selectionVisible = true
        onPreview?(item)
    }

    /// Footer "Clear History" — keeps pinned items.
    func clearHistory() {
        store.clearUnpinned()
        selection = 0
        selectionVisible = false
    }

    func clearAll() {
        store.clearAll()
        selection = 0
        selectionVisible = false
    }
}
