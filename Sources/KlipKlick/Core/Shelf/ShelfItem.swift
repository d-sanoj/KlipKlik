import AppKit
import UniformTypeIdentifiers

/// One thing parked on a shelf.
///
/// Provenance is stored rather than inferred, because it decides lifetime:
///
/// * **Referenced** — a file that already exists where the user put it. The shelf
///   keeps its path and nothing else, so shelving a 4 GB video costs a string.
///   Dragging it back out reads from wherever it actually lives.
/// * **Staged** — content with no file behind it: an image dragged out of a web
///   page, a snippet of text, or a promised file the source app only ever
///   materialises into the drag itself. The source is gone the instant the drag
///   ends, so these are written into the shelf's own directory on the way in.
///
/// It also decides what removing means. Taking a referenced item off the shelf
/// leaves the user's file alone; a staged item's copy is the only one there is,
/// so its bytes go with it.
struct ShelfItem: Identifiable, Equatable, Codable {
    enum Origin: String, Codable {
        case referenced
        case staged
    }

    let id: UUID
    /// Where the bytes are now — the user's own file, or ours under `staged/`.
    var url: URL
    let origin: Origin
    let kind: ClipKind
    let addedAt: Date
    /// Size when it was shelved, for the tile subtitle. Deliberately not
    /// refreshed: a shelf is a holding area, not a file browser, and stat-ing
    /// every item on every redraw would be the most expensive thing it does.
    let byteCount: Int64

    init(
        id: UUID = UUID(),
        url: URL,
        origin: Origin,
        kind: ClipKind? = nil,
        addedAt: Date = Date(),
        byteCount: Int64? = nil
    ) {
        self.id = id
        self.url = url
        self.origin = origin
        self.kind = kind ?? ClipKind(file: url)
        self.addedAt = addedAt
        self.byteCount = byteCount ?? Self.size(of: url)
    }

    var name: String { url.lastPathComponent }

    /// A referenced file can be renamed, moved, or deleted behind the shelf's
    /// back — nothing stops the user doing that in Finder. Tiles check this so a
    /// dead reference reads as broken rather than failing silently at drag time.
    var stillExists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// "1.2 MB", or "12 items" for a folder — the byte count of a directory is
    /// its own size on disk, which is never the number anyone means.
    var sizeLabel: String {
        if kind == .folder {
            let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count
            guard let children else { return "Folder" }
            return children == 1 ? "1 item" : "\(children) items"
        }
        return Self.byteFormatter.string(fromByteCount: byteCount)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
