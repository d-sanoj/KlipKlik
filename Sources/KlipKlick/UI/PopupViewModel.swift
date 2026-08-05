import Combine
import SwiftUI

/// Drives the popup: what's on screen, what's selected, and what the keyboard
/// and mouse do about it.
final class PopupViewModel: ObservableObject {
    @Published var query: String = ""
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

    private var cancellables = Set<AnyCancellable>()

    init(store: HistoryStore) {
        self.store = store

        Publishers.CombineLatest(store.$items, $query)
            .sink { [weak self] items, query in
                guard let self else { return }
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                let filtered = trimmed.isEmpty ? items : items.filter {
                    $0.title.range(
                        of: trimmed,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) != nil
                }
                pinnedItems = filtered.filter(\.pinned)
                recentItems = filtered.filter { !$0.pinned }
                // Keep the selection in range as the list shrinks under a search.
                selection = min(selection, max(pinnedItems.count + recentItems.count - 1, 0))
            }
            .store(in: &cancellables)
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
