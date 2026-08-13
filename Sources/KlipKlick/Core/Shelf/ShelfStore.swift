import AppKit
import Combine

/// Every open shelf, and the only thing allowed to change one.
///
/// Windows observe this rather than owning their contents, so a shelf survives
/// its window being closed and reopened, and so two views of the same shelf can
/// never disagree.
///
/// Saves are debounced rather than immediate: dropping forty files fires forty
/// mutations in a few milliseconds, and sealing and rewriting the index forty
/// times is pure waste when only the last one is observable.
final class ShelfStore: ObservableObject {
    @Published private(set) var shelves: [Shelf] = []

    /// Fires when a shelf is added, so the manager can put a window on screen.
    var onShelfAdded: ((Shelf) -> Void)?
    /// Fires when a shelf goes away, so its window can be torn down.
    var onShelfRemoved: ((UUID) -> Void)?

    private var saveWork: DispatchWorkItem?

    init() {
        // Persistence is opt-in per the setting, but the index is always read:
        // turning the setting off should not strand files that were staged while
        // it was on. Loading and then clearing hands them to the garbage
        // collector instead of leaking them.
        let loaded = ShelfStorage.load()
        if Settings.shared.shelvesPersist {
            shelves = loaded
        } else {
            ShelfStorage.clearEverything()
        }
    }

    // MARK: Shelves

    func shelf(_ id: UUID) -> Shelf? {
        shelves.first { $0.id == id }
    }

    @discardableResult
    func addShelf(at topLeft: CGPoint? = nil, intake: Shelf.Intake = .copy) -> Shelf {
        // Tints cycle rather than repeat, so two shelves opened back to back are
        // never the same colour — which is the entire reason for having tints.
        let tint = (shelves.last?.tintIndex).map { ($0 + 1) % Shelf.tints.count } ?? 0
        let shelf = Shelf(tintIndex: tint, windowTopLeft: topLeft, intake: intake)
        shelves.append(shelf)
        onShelfAdded?(shelf)
        scheduleSave()
        return shelf
    }

    func removeShelf(_ id: UUID) {
        guard let index = shelves.firstIndex(where: { $0.id == id }) else { return }
        // Staged bytes belong to the shelf; referenced files never do.
        for item in shelves[index].items { ShelfStorage.discard(item) }
        shelves.remove(at: index)
        onShelfRemoved?(id)
        scheduleSave()
    }

    func removeAllShelves() {
        for shelf in shelves { onShelfRemoved?(shelf.id) }
        shelves.removeAll()
        ShelfStorage.clearEverything()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.name = trimmed.isEmpty ? $0.name : trimmed }
    }

    func setTint(_ id: UUID, to index: Int) {
        update(id) { $0.tintIndex = index }
    }

    func setCollapsed(_ id: UUID, _ collapsed: Bool) {
        update(id) { $0.isCollapsed = collapsed }
    }

    /// Records where the user dragged the window to, so a persisted shelf comes
    /// back in the same place.
    func setWindowTopLeft(_ id: UUID, _ point: CGPoint) {
        // Not routed through `update`: this fires continuously while a window is
        // being dragged, and republishing the whole array on every frame would
        // rebuild every shelf view on screen.
        guard let index = shelves.firstIndex(where: { $0.id == id }) else { return }
        shelves[index].windowTopLeft = point
        scheduleSave()
    }

    // MARK: Items

    /// Adds files to a shelf, skipping anything already on it.
    ///
    /// Duplicates are checked by path rather than by id: dragging the same file
    /// in twice produces two different `ShelfItem`s, and a shelf showing the same
    /// name twice looks like a bug even when it technically is not.
    @discardableResult
    func add(urls: [URL], to id: UUID) -> Int {
        guard let index = shelves.firstIndex(where: { $0.id == id }) else { return 0 }

        let existing = Set(shelves[index].items.map(\.url.standardizedFileURL.path))
        let fresh = urls
            .map(\.standardizedFileURL)
            .filter { !existing.contains($0.path) && FileManager.default.fileExists(atPath: $0.path) }
            // A single drag can carry the same file twice; keep the first.
            .reduce(into: [URL]()) { unique, url in
                if !unique.contains(where: { $0.path == url.path }) { unique.append(url) }
            }

        guard !fresh.isEmpty else { return 0 }
        shelves[index].items.append(contentsOf: fresh.map { ShelfItem(url: $0, origin: .referenced) })
        scheduleSave()
        return fresh.count
    }

    /// Adds content that had no file behind it, writing it into staging first.
    @discardableResult
    func add(data: Data, name: String, to id: UUID) -> Bool {
        guard shelves.contains(where: { $0.id == id }) else { return false }
        let itemID = UUID()
        guard let url = ShelfStorage.stage(data, as: name, id: itemID) else { return false }
        append(ShelfItem(id: itemID, url: url, origin: .staged), to: id)
        return true
    }

    /// Adds a file the source app only materialised for the drag, taking it out
    /// of the system's temporary directory before that directory is reclaimed.
    @discardableResult
    func add(promised source: URL, to id: UUID) -> Bool {
        guard shelves.contains(where: { $0.id == id }) else { return false }
        let itemID = UUID()
        guard let url = ShelfStorage.stage(copying: source, id: itemID) else { return false }
        append(ShelfItem(id: itemID, url: url, origin: .staged), to: id)
        return true
    }

    /// Parks files on a Move shelf as references. The originals stay where they
    /// are until a later drag-out completes the cut — closing the shelf must not
    /// take them off disk.
    @discardableResult
    func addMoving(urls: [URL], to id: UUID) -> Int {
        add(urls: urls, to: id)
    }

    private func append(_ item: ShelfItem, to id: UUID) {
        guard let index = shelves.firstIndex(where: { $0.id == id }) else { return }
        shelves[index].items.append(item)
        scheduleSave()
    }

    func remove(item itemID: UUID, from shelfID: UUID) {
        guard let index = shelves.firstIndex(where: { $0.id == shelfID }),
              let itemIndex = shelves[index].items.firstIndex(where: { $0.id == itemID })
        else { return }
        ShelfStorage.discard(shelves[index].items[itemIndex])
        shelves[index].items.remove(at: itemIndex)
        scheduleSave()
        closeIfEmpty(shelfID)
    }

    /// A successful drag *out* of a shelf. The row always goes; the last item
    /// takes the shelf with it.
    ///
    /// Copy shelves leave the original on disk. Move shelves complete the cut:
    /// if Finder did not already relocate the file, it is put in the Trash so
    /// only the destination copy remains. Closing a Move shelf never does this.
    func takeOut(item itemID: UUID, from shelfID: UUID) {
        takeOut(items: [itemID], from: shelfID)
    }

    /// A successful drag *out* of a shelf. The rows always go; the last item
    /// takes the shelf with it.
    ///
    /// Copy shelves leave the original on disk. Move shelves complete the cut:
    /// if Finder did not already relocate the file, it is put in the Trash so
    /// only the destination copy remains. Closing a Move shelf never does this.
    func takeOut(items ids: [UUID], from shelfID: UUID) {
        guard let index = shelves.firstIndex(where: { $0.id == shelfID }) else { return }
        let wanted = Set(ids)
        let leaving = shelves[index].items.filter { wanted.contains($0.id) }
        guard !leaving.isEmpty else { return }
        let intake = shelves[index].intake
        shelves[index].items.removeAll { wanted.contains($0.id) }
        scheduleSave()
        closeIfEmpty(shelfID)
        for item in leaving {
            if item.origin == .staged {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    ShelfStorage.discard(item)
                }
            } else if intake == .move {
                let leftover = item.url
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard FileManager.default.fileExists(atPath: leftover.path) else { return }
                    try? FileManager.default.trashItem(at: leftover, resultingItemURL: nil)
                }
            }
        }
    }

    func removeAllItems(from shelfID: UUID) {
        update(shelfID) { shelf in
            for item in shelf.items { ShelfStorage.discard(item) }
            shelf.items.removeAll()
        }
        closeIfEmpty(shelfID)
    }

    /// An empty shelf is just a box. The last file leaving — ×, Empty, or a
    /// drag-out — takes the window with it.
    private func closeIfEmpty(_ shelfID: UUID) {
        guard let shelf = shelf(shelfID), shelf.items.isEmpty else { return }
        removeShelf(shelfID)
    }

    /// Drops references whose file has since been moved or deleted. Called when a
    /// shelf window comes back to the front, which is the moment the user is
    /// about to act on what it shows.
    func pruneMissing(in shelfID: UUID) {
        guard let index = shelves.firstIndex(where: { $0.id == shelfID }) else { return }
        let survivors = shelves[index].items.filter(\.stillExists)
        guard survivors.count != shelves[index].items.count else { return }
        shelves[index].items = survivors
        scheduleSave()
    }

    private func update(_ id: UUID, _ mutate: (inout Shelf) -> Void) {
        guard let index = shelves.firstIndex(where: { $0.id == id }) else { return }
        mutate(&shelves[index])
        scheduleSave()
    }

    // MARK: Persistence

    /// Coalesces a burst of mutations into one write.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveNow() {
        guard Settings.shared.shelvesPersist else { return }
        ShelfStorage.save(shelves)
    }

    /// Quit. Shelves either survive or they do not, and the staged bytes have to
    /// follow whichever it is — leaving them behind after a non-persistent
    /// session would put files on disk that nothing will ever reclaim.
    func endSession() {
        saveWork?.cancel()
        if Settings.shared.shelvesPersist {
            ShelfStorage.save(shelves)
            ShelfStorage.collectGarbage(keeping: shelves.flatMap(\.items))
        } else {
            ShelfStorage.clearEverything()
        }
    }
}
