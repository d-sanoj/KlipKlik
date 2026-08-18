import AppKit
import Carbon.HIToolbox
import Combine

/// Runs the shelf feature: one store, one drag watcher, one landing pad, and a
/// window per shelf.
///
/// Everything that crosses between those lives here, so no shelf window knows
/// about the watcher and the watcher knows about no windows.
final class ShelfManager {
    let store = ShelfStore()

    /// Reports pasteboard writes made by shelf actions, so `ClipboardMonitor`
    /// does not record KlipKlik's own copies as new history entries.
    var onDidWriteToPasteboard: ((Int) -> Void)?

    private let watcher = DragWatcher()
    private let pad = ShelfDropPad()
    private var controllers: [UUID: ShelfWindowController] = [:]
    /// Shelf the current pad drop is filling. One drag can deliver several items
    /// asynchronously, and they all belong on the same shelf.
    private var padShelfID: UUID?
    /// Consumed by `openWindow` so a pad drop can grow out of the notch and a
    /// hot-key shelf can pop, without every restored window replaying either.
    private var pendingEntrance: ShelfAppearance.Entrance = .none
    private var hotKey: CarbonHotKey?
    private var cancellables = Set<AnyCancellable>()

    // MARK: Lifecycle

    func start() {
        store.onShelfAdded = { [weak self] shelf in self?.openWindow(for: shelf.id) }
        store.onShelfRemoved = { [weak self] id in self?.closeWindow(for: id) }

        ShelfActions.onPasteboardWrite = { [weak self] changeCount in
            self?.onDidWriteToPasteboard?(changeCount)
        }

        pad.onDropFiles = { [weak self] urls, point in
            guard let self, let id = padShelf(at: point, intake: .copy) else { return }
            store.add(urls: urls, to: id)
        }
        pad.onDropMovingFiles = { [weak self] urls, point in
            guard let self, let id = padShelf(at: point, intake: .move) else { return }
            store.addMoving(urls: urls, to: id)
        }
        pad.onDropStagedFile = { [weak self] url, point in
            guard let self, let id = padShelf(at: point, intake: .copy) else { return }
            store.add(promised: url, to: id)
        }

        watcher.onDragBegan = { [weak self] payload, point in
            self?.dragBegan(payload, at: point)
        }
        watcher.onDragEnded = { [weak self] in self?.dragEnded() }

        // Shelves restored from a previous session need their windows back.
        for shelf in store.shelves { openWindow(for: shelf.id) }

        installHotKey()
        applyEnabledState()

        Settings.shared.$shelvesEnabled
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.applyEnabledState() }
            }
            .store(in: &cancellables)

        Settings.shared.$shelfTrigger
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.applyEnabledState() }
            }
            .store(in: &cancellables)
    }

    func stop() {
        watcher.stop()
        pad.dismiss()
        store.endSession()
    }

    /// The watcher only runs when something can come of it — there is no reason
    /// to poll the mouse for a feature that is switched off, or whose trigger is
    /// set to open shelves by hand.
    private func applyEnabledState() {
        let enabled = Settings.shared.shelvesEnabled
        if enabled, Settings.shared.shelfTrigger == .automatic {
            watcher.start()
        } else {
            watcher.stop()
            pad.dismiss()
        }

        for controller in controllers.values {
            enabled ? controller.show() : controller.dismiss()
        }
    }

    // MARK: Drags

    private func dragBegan(_ payload: DragWatcher.Payload, at point: NSPoint) {
        guard Settings.shared.shelvesEnabled else { return }
        padShelfID = nil
        pad.arm(near: point)
    }

    private func dragEnded() {
        // A beat before the pad goes: the drop is delivered as the button comes
        // up, and the watcher notices the button on its own schedule. Tearing the
        // window down first would sometimes cancel the drop that was landing on
        // it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.pad.dismiss()
        }
    }

    /// Called while KlipKlik is itself the source of a drag, so picking an item
    /// off one shelf does not immediately offer a pad to put it on another.
    func beginOwnDrag() {
        watcher.beginSuppression()
        pad.dismiss()
    }

    func endOwnDrag() {
        watcher.endSuppression()
    }

    /// The shelf a pad drop belongs to, created on the first item of that drop.
    private func padShelf(at point: NSPoint, intake: Shelf.Intake) -> UUID? {
        if let padShelfID, store.shelf(padShelfID) != nil { return padShelfID }
        pendingEntrance = .fromNotch
        let shelf = store.addShelf(at: point, intake: intake)
        pendingEntrance = .none
        padShelfID = shelf.id
        return shelf.id
    }

    // MARK: Shelves

    /// A new empty shelf under the pointer — the menu item and the hot key.
    func newShelf() {
        guard Settings.shared.shelvesEnabled else { return }
        pendingEntrance = .appear
        store.addShelf()
        pendingEntrance = .none
    }

    func closeAllShelves() {
        store.removeAllShelves()
    }

    /// Shows the drop pad without a drag, for the scripted development trigger.
    func previewPad(targeted: Bool) {
        pad.presentForPreview(targeted: targeted)
    }

    func dismissPad() {
        pad.dismiss()
    }

    /// Puts a history entry's files on a shelf. Only file items have anything to
    /// contribute, which is why this reports whether it did.
    @discardableResult
    func addToShelf(_ item: ClipboardItem, from history: HistoryStore) -> Bool {
        let ready = history.materialized(item)
        let urls = Self.fileURLs(in: ready)
        guard !urls.isEmpty else { return false }

        // The newest shelf, or a new one — dropping into whichever shelf is
        // already open is what the user means by "add to shelf" when there is one.
        let id: UUID
        if let existing = store.shelves.last?.id {
            id = existing
        } else {
            pendingEntrance = .appear
            id = store.addShelf().id
            pendingEntrance = .none
        }
        store.add(urls: urls, to: id)
        controllers[id]?.show()
        return true
    }

    /// Whether an "Add to Shelf" action would do anything for this item.
    static func canShelve(_ item: ClipboardItem, from history: HistoryStore) -> Bool {
        switch item.kind {
        case .file, .folder, .image, .video, .audio:
            return !fileURLs(in: history.materialized(item)).isEmpty
        default:
            return false
        }
    }

    private static func fileURLs(in item: ClipboardItem) -> [URL] {
        let key = NSPasteboard.PasteboardType.fileURL.rawValue
        return (item.representations ?? []).compactMap { bag in
            guard let data = bag[key],
                  let string = String(data: data, encoding: .utf8),
                  let url = URL(string: string), url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path)
            else { return nil }
            return url.standardizedFileURL
        }
    }

    // MARK: Windows

    private func openWindow(for id: UUID) {
        let entrance = pendingEntrance
        if let existing = controllers[id] {
            existing.show(entrance: entrance)
            return
        }
        let controller = ShelfWindowController(shelfID: id, store: store, manager: self)
        controllers[id] = controller
        controller.show(entrance: entrance)
    }

    private func closeWindow(for id: UUID) {
        controllers[id]?.dismiss()
        controllers[id] = nil
    }

    // MARK: Hot key

    /// ⌥⌘S. A Carbon hot key, so it needs no Accessibility — the same reason
    /// ⇧⌘C exists alongside the double-tap trigger.
    private func installHotKey() {
        hotKey = CarbonHotKey(
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: UInt32(cmdKey | optionKey)
        ) { [weak self] in
            self?.newShelf()
        }
    }
}
