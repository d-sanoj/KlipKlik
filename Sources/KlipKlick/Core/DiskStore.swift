import Foundation

/// Where clipboard items live once they leave RAM.
///
/// Two tiers, deliberately different:
///
/// * **Pinned** items are an archive. They survive quitting, rebooting and the
///   daily purge, and go only when the user clears them.
/// * **Unpinned** items are swap. They are written out to free memory and
///   deleted wholesale on quit and at the purge, so the app keeps its promise
///   that ordinary clipboard content does not outlive a session.
///
/// Everything is AES-GCM encrypted (see `SecretBox`), because "offload to SSD"
/// otherwise means "write every password you copy to a plain file".
///
/// One file per item rather than a database: items are large, opaque blobs
/// written once and read rarely, which is the case a filesystem already handles
/// well. A single small index carries the metadata the popup needs to render and
/// search without touching a single blob.
final class DiskStore {
    static let shared = DiskStore()

    /// Metadata light enough to keep every item's copy in memory.
    struct Stub: Codable {
        let id: UUID
        let kind: ClipKind
        let title: String
        let plainText: String?
        let colorHex: String?
        let sourceApp: String?
        let createdAt: Date
        let fingerprint: String
        var pinned: Bool
        /// Optional so an index written before image compaction existed still
        /// decodes; absent means the blob holds its original TIFF.
        var restoresTIFF: Bool?
    }

    private let root: URL
    private let pinnedDir: URL
    private let cacheDir: URL
    private let indexURL: URL
    private let queue = DispatchQueue(label: "com.sanoj.KlipKlick.diskstore", qos: .utility)

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("KlipKlick", isDirectory: true)
        pinnedDir = root.appendingPathComponent("pinned", isDirectory: true)
        // Caches, not Application Support: this tier is disposable by definition,
        // and the location tells the system (and the user) exactly that.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = caches.appendingPathComponent("KlipKlick", isDirectory: true)
        indexURL = root.appendingPathComponent("pinned-index")

        for dir in [root, pinnedDir, cacheDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Nothing here should end up in Spotlight or a Time Machine snapshot.
        exclude(root)
        exclude(cacheDir)
    }

    private func exclude(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func blobURL(_ id: UUID, pinned: Bool) -> URL {
        (pinned ? pinnedDir : cacheDir).appendingPathComponent("\(id.uuidString).blob")
    }

    // MARK: Offload and recall

    /// Binary property list rather than JSON.
    ///
    /// JSON has no way to hold bytes, so `Data` goes in base64 — a 1.8 MB image
    /// encodes to 2.4 MB, and the string has to be built in memory before it can
    /// be encrypted. A binary plist stores the bytes as bytes: same payload out,
    /// 26% smaller, and encode and decode drop from ~5 ms each to under 0.1 ms.
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    /// Reads either format. JSON is what earlier versions wrote, and a pinned
    /// archive predating this change has to keep opening.
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        if let value = try? PropertyListDecoder().decode(type, from: data) { return value }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Writes an item's representations out and reports whether it worked, so the
    /// caller only drops them from memory once they are safely on disk.
    ///
    /// Synchronous, for pinning: the index must not claim a blob exists before it
    /// does. The idle offload uses the asynchronous form below.
    func offload(_ item: ClipboardItem) -> Bool {
        guard let representations = item.representations else { return true }
        do {
            let sealed = try SecretBox.seal(try Self.encode(representations))
            try sealed.write(to: blobURL(item.id, pinned: item.pinned), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The same write, off the main thread, reporting back on it.
    ///
    /// Encrypting and writing a multi-megabyte blob is housekeeping — it has no
    /// business running on the thread that draws the popup. The queue was already
    /// here and unused.
    func offload(_ item: ClipboardItem, completion: @escaping (Bool) -> Void) {
        guard let representations = item.representations else {
            completion(true)
            return
        }
        let url = blobURL(item.id, pinned: item.pinned)
        queue.async {
            var ok = false
            do {
                let sealed = try SecretBox.seal(try Self.encode(representations))
                try sealed.write(to: url, options: .atomic)
                ok = true
            } catch {
                ok = false
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Reads representations back. Checks both tiers, since pinning moves a file.
    func materialize(_ item: ClipboardItem) -> [[String: Data]]? {
        for pinned in [item.pinned, !item.pinned] {
            guard let sealed = try? Data(contentsOf: blobURL(item.id, pinned: pinned)),
                  let plain = try? SecretBox.open(sealed),
                  let bags = Self.decode([[String: Data]].self, from: plain)
            else { continue }
            return bags
        }
        return nil
    }

    /// Moves a blob between the archive and the swap when an item is pinned or
    /// unpinned, so its lifetime follows its new status.
    func move(_ item: ClipboardItem, toPinned pinned: Bool) {
        let from = blobURL(item.id, pinned: !pinned)
        let to = blobURL(item.id, pinned: pinned)
        try? FileManager.default.removeItem(at: to)
        try? FileManager.default.moveItem(at: from, to: to)
    }

    func delete(_ item: ClipboardItem) {
        for pinned in [true, false] {
            try? FileManager.default.removeItem(at: blobURL(item.id, pinned: pinned))
        }
    }

    // MARK: The pinned archive

    func saveIndex(_ items: [ClipboardItem]) {
        let stubs = items.filter(\.pinned).map {
            Stub(
                id: $0.id, kind: $0.kind, title: $0.title, plainText: $0.plainText,
                colorHex: $0.colorHex, sourceApp: $0.sourceApp, createdAt: $0.createdAt,
                fingerprint: $0.fingerprint, pinned: true, restoresTIFF: $0.restoresTIFF
            )
        }
        do {
            let sealed = try SecretBox.seal(try Self.encode(stubs))
            try sealed.write(to: indexURL, options: .atomic)
        } catch {
            // Losing the index costs the pinned list, not the app.
        }
    }

    /// Pinned items as of the last save, with their bytes still on disk.
    func loadPinned() -> [ClipboardItem] {
        guard let sealed = try? Data(contentsOf: indexURL) else { return [] }

        guard let plain = try? SecretBox.open(sealed),
              let stubs = Self.decode([Stub].self, from: plain)
        else {
            // Written under a key we no longer hold, so the blobs beside it are
            // just as unreadable. Clear them rather than leaving files that can
            // never be opened and never get cleaned up.
            clearPinned()
            return []
        }

        return stubs.map {
            ClipboardItem(
                id: $0.id, kind: $0.kind, title: $0.title, plainText: $0.plainText,
                colorHex: $0.colorHex, representations: nil, sourceApp: $0.sourceApp,
                createdAt: $0.createdAt, fingerprint: $0.fingerprint, pinned: true,
                restoresTIFF: $0.restoresTIFF ?? false
            )
        }
    }

    // MARK: Clearing

    /// Empties the swap tier. Called on quit and at the daily purge.
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        exclude(cacheDir)
    }

    /// Empties the archive.
    func clearPinned() {
        try? FileManager.default.removeItem(at: pinnedDir)
        try? FileManager.default.removeItem(at: indexURL)
        try? FileManager.default.createDirectory(at: pinnedDir, withIntermediateDirectories: true)
    }

    /// Removes both tiers and the key that made them readable.
    func destroyEverything() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cacheDir)
        SecretBox.destroyKey()
    }

    // MARK: Reporting

    func bytes(pinned: Bool) -> Int {
        let dir = pinned ? pinnedDir : cacheDir
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return 0
        }
        return names.reduce(0) { total, name in
            let path = dir.appendingPathComponent(name).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int
            return total + (size ?? 0)
        }
    }
}
