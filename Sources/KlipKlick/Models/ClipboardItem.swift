import AppKit
import UniformTypeIdentifiers

/// The item families KlipKlick tells apart. Rows are text-only, so this only
/// surfaces in the hover detail card and in how an item is restored.
enum ClipKind: String, Codable {
    case text
    case rich
    case link
    case color
    case image
    case video
    case audio
    case file
    case folder

    /// Classifies a file by what it is on disk, then by its extension.
    ///
    /// Shared with the shelf, which classifies one file at a time — the same
    /// question asked of a single URL rather than a pasteboard selection.
    init(file url: URL) {
        // A plain directory is a folder; a package (.app, .rtfd) is a directory
        // on disk too but the user thinks of it as a single file.
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true && values?.isPackage != true {
            self = .folder
            return
        }

        guard let type = UTType(filenameExtension: url.pathExtension) else {
            self = .file
            return
        }

        if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { self = .video }
        else if type.conforms(to: .audio) { self = .audio }
        else { self = .file }
    }

    /// Human-readable name, as shown on the hover card's "Type" line.
    var label: String {
        switch self {
        case .text: return "Text"
        case .rich: return "Rich text"
        case .link: return "Link"
        case .color: return "Color"
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .file: return "File"
        case .folder: return "Folder"
        }
    }
}

/// A single captured clipboard entry.
///
/// `representations` keeps every flavour the source app put on the pasteboard
/// (RTF, HTML, plain string, file URLs, TIFF...), so putting the item back is
/// lossless rather than a text-only approximation.
struct ClipboardItem: Identifiable, Equatable, Codable {
    let id: UUID
    let kind: ClipKind
    let title: String
    /// Plain-text flavour, when there is one. Used for "paste without formatting".
    let plainText: String?
    /// Set only for `.color` items — the hex string as it was copied.
    let colorHex: String?
    /// One dictionary per `NSPasteboardItem`, mapping type identifier to raw data.
    ///
    /// Nil once the item has been offloaded to disk — this is the heavy part, an
    /// image can be several megabytes, and holding every one in RAM is what the
    /// offload exists to avoid. `DiskStore.materialize(_:)` brings it back.
    var representations: [[String: Data]]?
    /// Localised name of the app that was frontmost when this was copied.
    let sourceApp: String?
    let createdAt: Date
    /// Identity used to collapse a re-copy of something already in history.
    let fingerprint: String
    /// Pinned items sort into their own section and survive "Clear History".
    var pinned: Bool
    /// Set when the uncompressed `public.tiff` flavour was replaced by PNG, so
    /// `write(to:)` knows to rebuild it for anything that asks. See
    /// `compacting(_:)`.
    var restoresTIFF: Bool = false

    init(
        id: UUID = UUID(),
        kind: ClipKind,
        title: String,
        plainText: String?,
        colorHex: String? = nil,
        representations: [[String: Data]]?,
        sourceApp: String? = nil,
        createdAt: Date = Date(),
        fingerprint: String,
        pinned: Bool = false,
        restoresTIFF: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.plainText = plainText
        self.colorHex = colorHex
        self.representations = representations
        self.sourceApp = sourceApp
        self.createdAt = createdAt
        self.fingerprint = fingerprint
        self.pinned = pinned
        self.restoresTIFF = restoresTIFF
    }

    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.id == rhs.id && lhs.pinned == rhs.pinned
    }

    /// "now", "3m ago", "1h ago", "2d ago" — the design's compact form.
    func relativeTime(from now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(createdAt))
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// Wall-clock time for the hover card — the date is only worth the space
    /// once the item is no longer from today.
    func absoluteTime(from now: Date = Date()) -> String {
        let calendar = Calendar.current
        let formatter = calendar.isDate(createdAt, inSameDayAs: now)
            ? Self.timeOnlyFormatter
            : Self.dateAndTimeFormatter
        return formatter.string(from: createdAt)
    }

    private static let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateAndTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Capture

extension ClipboardItem {
    /// Types that mark content other apps have asked clipboard managers not to record.
    private static let concealedMarkers: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType"
    ]

    private static let ignoredTypes: Set<String> = [
        "com.apple.finder.noderef",
        "dyn.ah62d4rv4gu8zg55gq0862press-noop"
    ]

    private static let richTextTypes: Set<String> = [
        NSPasteboard.PasteboardType.rtf.rawValue,
        NSPasteboard.PasteboardType.rtfd.rawValue,
        NSPasteboard.PasteboardType.html.rawValue
    ]

    private static let colorPattern = try! NSRegularExpression(
        pattern: "^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"
    )

    static func capture(from pasteboard: NSPasteboard, sourceApp: String? = nil) -> ClipboardItem? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }

        // Honour the nspasteboard.org convention for passwords and transient data.
        for item in items {
            for type in item.types where concealedMarkers.contains(type.rawValue) {
                return nil
            }
        }

        var representations: [[String: Data]] = []
        for item in items {
            var bag: [String: Data] = [:]
            for type in item.types {
                guard !ignoredTypes.contains(type.rawValue) else { continue }
                if let data = item.data(forType: type) {
                    bag[type.rawValue] = data
                }
            }
            if !bag.isEmpty { representations.append(bag) }
        }
        guard !representations.isEmpty else { return nil }

        let fileURLs = Self.fileURLs(in: representations)
        let plain = pasteboard.string(forType: .string)
        let trimmed = plain?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var kind: ClipKind
        var title: String
        var colorHex: String?

        if !fileURLs.isEmpty {
            kind = Self.kind(forFiles: fileURLs)
            title = Self.title(forFiles: fileURLs)
        } else if let imageTitle = Self.imageTitle(in: representations) {
            kind = .image
            title = imageTitle
        } else if !trimmed.isEmpty {
            if Self.isColor(trimmed) {
                kind = .color
                title = trimmed
                colorHex = trimmed
            } else if let host = Self.linkTitle(trimmed) {
                kind = .link
                title = host
            } else if Self.hasRichText(in: representations) {
                kind = .rich
                title = Self.preview(of: trimmed)
            } else {
                kind = .text
                title = Self.preview(of: trimmed)
            }
        } else {
            // Something opaque — a custom app flavour with no text or file behind it.
            kind = .file
            title = Self.opaqueTitle(in: representations)
        }

        return ClipboardItem(
            kind: kind,
            title: title,
            plainText: plain,
            colorHex: colorHex,
            representations: representations,
            sourceApp: sourceApp,
            fingerprint: Self.fingerprint(
                fileURLs: fileURLs, plain: plain, representations: representations
            )
        )
    }

    // MARK: Classification

    private static func fileURLs(in representations: [[String: Data]]) -> [URL] {
        let key = NSPasteboard.PasteboardType.fileURL.rawValue
        return representations.compactMap { bag in
            guard let data = bag[key],
                  let string = String(data: data, encoding: .utf8),
                  let url = URL(string: string), url.isFileURL
            else { return nil }
            return url
        }
    }

    /// Classifies by the first file; a mixed selection takes that file's kind.
    private static func kind(forFiles urls: [URL]) -> ClipKind {
        guard let first = urls.first else { return .file }
        return ClipKind(file: first)
    }

    private static func title(forFiles urls: [URL]) -> String {
        guard let first = urls.first else { return "File" }
        let name = first.lastPathComponent
        return urls.count > 1 ? "\(name) + \(urls.count - 1) more" : name
    }

    private static func isColor(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return colorPattern.firstMatch(in: text, range: range) != nil
    }

    /// Returns the display form of a URL — scheme and trailing slash stripped,
    /// as the design shows it ("github.com/p0deje/Maccy").
    private static func linkTitle(_ text: String) -> String? {
        guard !text.contains(where: \.isWhitespace),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp", "ftps"].contains(scheme),
              url.host != nil
        else { return nil }

        var display = text
        for prefix in ["https://", "http://", "ftps://", "ftp://"] {
            if display.lowercased().hasPrefix(prefix) {
                display.removeFirst(prefix.count)
                break
            }
        }
        if display.hasSuffix("/") { display.removeLast() }
        return display
    }

    private static func hasRichText(in representations: [[String: Data]]) -> Bool {
        representations.contains { bag in
            bag.keys.contains { richTextTypes.contains($0) }
        }
    }

    private static func imageTitle(in representations: [[String: Data]]) -> String? {
        let imageKeys = [
            NSPasteboard.PasteboardType.tiff.rawValue,
            NSPasteboard.PasteboardType.png.rawValue,
            "public.jpeg",
            "com.compuserve.gif",
            NSPasteboard.PasteboardType.pdf.rawValue
        ]
        for bag in representations {
            for key in imageKeys {
                guard let data = bag[key] else { continue }
                if let image = NSImage(data: data), image.size.width > 0 {
                    let w = Int(image.size.width.rounded())
                    let h = Int(image.size.height.rounded())
                    return "Image — \(w) × \(h)"
                }
                return "Image"
            }
        }
        return nil
    }

    private static func opaqueTitle(in representations: [[String: Data]]) -> String {
        let type = representations.first?.keys.sorted().first ?? "unknown"
        if let utType = UTType(type), let description = utType.localizedDescription {
            return description
        }
        return type
    }

    /// Collapses a clipboard entry to a single readable line for the list.
    private static func preview(of text: String) -> String {
        let firstMeaningfulLine = text
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? text

        let collapsed = firstMeaningfulLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        return collapsed.count > 140 ? String(collapsed.prefix(140)) + "…" : collapsed
    }

    private static func fingerprint(
        fileURLs: [URL],
        plain: String?,
        representations: [[String: Data]]
    ) -> String {
        if !fileURLs.isEmpty {
            return "file:" + fileURLs.map(\.absoluteString).joined(separator: "|")
        }
        if let plain, !plain.isEmpty {
            return "text:\(plain.hashValue)"
        }
        let bytes = representations
            .flatMap(\.values)
            .max(by: { $0.count < $1.count })?
            .hashValue ?? 0
        return "data:\(bytes)"
    }
}

// MARK: - Compaction

extension ClipboardItem {
    static let tiffType = NSPasteboard.PasteboardType.tiff.rawValue
    static let pngType = NSPasteboard.PasteboardType.png.rawValue

    /// Replaces the uncompressed TIFF flavour with PNG.
    ///
    /// Apps copy a picture by handing AppKit an `NSImage`, and what lands on the
    /// pasteboard is `public.tiff` — uncompressed. A full-screen grab that is
    /// 1.8 MB as PNG arrives as 23 MB of TIFF, and every byte of that sat in RAM
    /// until the offload five minutes later. Two screenshots put the app past
    /// 40 MB on their own.
    ///
    /// PNG is lossless, so nothing is given up: `write(to:)` rebuilds a
    /// byte-identical TIFF for anything that asks for one. Some apps write both
    /// flavours, in which case the TIFF is simply dropped and nothing is
    /// transcoded at all.
    ///
    /// Returns nil when there was nothing worth doing — the caller then leaves
    /// the item exactly as captured.
    static func compacting(
        _ representations: [[String: Data]]
    ) -> (bags: [[String: Data]], restoresTIFF: Bool)? {
        guard representations.contains(where: { $0[tiffType] != nil }) else { return nil }

        var bags = representations
        var changed = false

        for index in bags.indices {
            guard let tiff = bags[index][tiffType] else { continue }

            // Pooled explicitly. Decoding a TIFF produces an uncompressed bitmap
            // the same size as the TIFF itself — 23 MB for a full-screen grab —
            // and `NSBitmapImageRep` is autoreleased. Without a pool that drains
            // here, those bitmaps outlive the transcode and cost more than the
            // compaction saves.
            let compressed: Data? = autoreleasepool {
                if let existing = bags[index][pngType] { return existing }
                return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            }

            // A small or already-compressed image can encode *larger* as PNG,
            // and an undecodable TIFF yields nothing — leave both alone.
            guard let compressed, compressed.count < tiff.count else { continue }

            bags[index][pngType] = compressed
            bags[index][tiffType] = nil
            changed = true
        }

        return changed ? (bags, true) : nil
    }
}

// MARK: - Restore

extension ClipboardItem {
    /// Puts this item back on the pasteboard.
    ///
    /// - Parameter plainTextOnly: strip styling and write just the text flavour.
    /// - Returns: the pasteboard's change count after writing, so the monitor can
    ///   recognise the write as its own and not re-record it.
    @discardableResult
    func write(to pasteboard: NSPasteboard, plainTextOnly: Bool = false) -> Int {
        pasteboard.clearContents()

        if plainTextOnly {
            if let plainText {
                pasteboard.setString(plainText, forType: .string)
                return pasteboard.changeCount
            }
            // Nothing to strip down to — fall through and restore in full.
        }

        // Offloaded and not yet brought back: the plain text is all that is left
        // in memory, and pasting that beats pasting nothing.
        guard let representations else {
            if let plainText { pasteboard.setString(plainText, forType: .string) }
            return pasteboard.changeCount
        }

        let items: [NSPasteboardItem] = representations.map { bag in
            var bag = bag
            // Put back the TIFF that `compacting(_:)` swapped out. Rebuilt from
            // the PNG, which is lossless, so this is the same image the source
            // app put on the pasteboard — apps that ask only for `public.tiff`
            // must still find it.
            if restoresTIFF,
               bag[Self.tiffType] == nil,
               let png = bag[Self.pngType],
               let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
                bag[Self.tiffType] = tiff
            }

            let item = NSPasteboardItem()
            for (type, data) in bag {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(items)
        return pasteboard.changeCount
    }
}
