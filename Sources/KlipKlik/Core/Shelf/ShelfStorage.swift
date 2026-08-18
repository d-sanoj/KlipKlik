import AppKit

/// Where shelves live between launches, and where staged bytes go.
///
/// Two things are stored, and only one of them is encrypted. That asymmetry is
/// deliberate and worth stating plainly, because it departs from how
/// `DiskStore` treats clipboard history:
///
/// * **The index** — shelf names, tints, window positions, and the *paths* of
///   referenced files — is AES-GCM sealed like everything else KlipKlik writes.
///   It is small, it is metadata, and nothing ever needs to read it but us.
/// * **Staged bytes** — the image you dragged out of a web page — are written as
///   ordinary files, in the clear. They have to be: dragging an item off a shelf
///   hands a real `file://` URL to another application, and a sealed blob is not
///   a file any other app can open. Encrypting them would mean decrypting to a
///   temporary file at drag time, which puts the same plaintext on the same disk
///   a moment later and buys nothing.
///
/// So the honest scope is narrower than history's: a shelf's *structure* is
/// private, its staged contents are as private as the folder they sit in. That
/// is why staging is only ever used for content that had no file of its own —
/// everything dragged in from Finder stays a reference, and nothing is copied.
enum ShelfStorage {
    /// Root for shelf data, alongside the pinned archive.
    private static var root: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return support.appendingPathComponent("KlipKlik", isDirectory: true)
    }

    private static var stagingDirectory: URL {
        root.appendingPathComponent("staged", isDirectory: true)
    }

    private static var indexURL: URL {
        root.appendingPathComponent("shelves-index")
    }

    private static func prepare() {
        try? FileManager.default.createDirectory(
            at: stagingDirectory, withIntermediateDirectories: true
        )
    }

    // MARK: Staging

    /// Writes bytes that have no file behind them into the shelf's own storage.
    ///
    /// Each item gets its own subdirectory named by its id, so two screenshots
    /// both called "Image.png" can sit on the same shelf without one silently
    /// overwriting the other — and so removing an item is a single directory
    /// delete with nothing else in it.
    static func stage(_ data: Data, as name: String, id: UUID) -> URL? {
        prepare()
        let directory = stagingDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(sanitised(name))
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Copies a file the source app only materialised for the drag — a promised
    /// file lands in a temporary directory that the system reclaims, so it has to
    /// be taken out of there before the drag ends.
    static func stage(copying source: URL, id: UUID) -> URL? {
        prepare()
        let directory = stagingDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent(sanitised(source.lastPathComponent))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Directory a staged item owns, for the drop handler to write promises into.
    static func stagingDirectory(for id: UUID) -> URL? {
        prepare()
        let directory = stagingDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }

    /// Drops a staged item's bytes. A no-op for referenced items — their file
    /// belongs to the user, and taking something off a shelf must never delete it.
    static func discard(_ item: ShelfItem) {
        guard item.origin == .staged else { return }
        let directory = stagingDirectory.appendingPathComponent(item.id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes staged directories no surviving shelf refers to.
    ///
    /// Run at load and on quit: a crash between staging a file and saving the
    /// index would otherwise leave bytes on disk that nothing can ever reach or
    /// clean up.
    static func collectGarbage(keeping items: [ShelfItem]) {
        let live = Set(items.filter { $0.origin == .staged }.map(\.id.uuidString))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path))
        for name in names ?? [] where !live.contains(name) {
            try? FileManager.default.removeItem(
                at: stagingDirectory.appendingPathComponent(name)
            )
        }
    }

    /// Slashes are the only character a file name genuinely cannot carry, and a
    /// leading dot would hide the file from the user in every Finder window.
    private static func sanitised(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let trimmed = cleaned.hasPrefix(".") ? String(cleaned.dropFirst()) : cleaned
        return trimmed.isEmpty ? "Item" : trimmed
    }

    // MARK: The index

    static func save(_ shelves: [Shelf]) {
        prepare()
        do {
            let sealed = try SecretBox.seal(try JSONEncoder().encode(shelves))
            try sealed.write(to: indexURL, options: .atomic)
        } catch {
            // Losing the index costs the shelf list, not the app.
        }
    }

    /// Shelves as of the last save, with dead references already dropped.
    ///
    /// A referenced file may have been moved or deleted since the last launch,
    /// and a shelf full of items that cannot be dragged anywhere is worse than a
    /// shelf that quietly lost them — so they are filtered here rather than
    /// shown broken forever.
    static func load() -> [Shelf] {
        guard let sealed = try? Data(contentsOf: indexURL) else { return [] }
        guard let plain = try? SecretBox.open(sealed),
              var shelves = try? JSONDecoder().decode([Shelf].self, from: plain)
        else {
            // Written under a key we no longer hold. The staged files beside it
            // are orphaned by definition, so clear the lot.
            clearEverything()
            return []
        }

        for index in shelves.indices {
            shelves[index].items.removeAll { !$0.stillExists }
        }
        collectGarbage(keeping: shelves.flatMap(\.items))
        return shelves
    }

    static func clearEverything() {
        try? FileManager.default.removeItem(at: stagingDirectory)
        try? FileManager.default.removeItem(at: indexURL)
        prepare()
    }

    /// Total bytes the shelf feature is responsible for — staged content only,
    /// since referenced files were already on disk and are not ours to count.
    static func stagedBytes() -> Int {
        guard let walker = FileManager.default.enumerator(
            at: stagingDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += values?.fileSize ?? 0
        }
        return total
    }
}
