import AppKit

/// A single floating shelf: a named, coloured tray of files waiting to be put
/// somewhere else.
///
/// Several can be open at once, which is the point — one for the screenshots
/// going into a report, one for the report itself. Each remembers where it was
/// last dragged to, so reopening a persisted shelf puts it back where the user
/// left it rather than under the pointer.
struct Shelf: Identifiable, Equatable, Codable {
    /// How files first landed on this shelf from the notch.
    enum Intake: String, Codable {
        case copy, move

        var title: String { self == .move ? "Move" : "Copy" }
        var symbol: String { self == .move ? "arrow.right" : "plus" }
        var help: String {
            switch self {
            case .copy:
                return "Copied onto this shelf. Originals stay where they were."
            case .move:
                return "Will be moved from the original location when dragged out of this shelf."
            }
        }
    }

    let id: UUID
    var name: String
    /// Index into `Shelf.tints`. Stored as an index, not a colour, so the
    /// palette can change with the theme without rewriting every saved shelf.
    var tintIndex: Int
    var items: [ShelfItem]
    let createdAt: Date
    /// Screen position of the window's top-left corner, in Cocoa coordinates.
    /// Nil until the window has been placed once.
    var windowTopLeft: CGPoint?
    /// Collapsed shelves draw as a compact pill showing only the count.
    var isCollapsed: Bool
    /// Copy vs Move, from the notch half that created the shelf.
    var intake: Intake

    init(
        id: UUID = UUID(),
        name: String? = nil,
        tintIndex: Int = 0,
        items: [ShelfItem] = [],
        createdAt: Date = Date(),
        windowTopLeft: CGPoint? = nil,
        isCollapsed: Bool = false,
        intake: Intake = .copy
    ) {
        self.id = id
        self.name = name ?? Self.defaultName(at: createdAt)
        self.tintIndex = tintIndex
        self.items = items
        self.createdAt = createdAt
        self.windowTopLeft = windowTopLeft
        self.isCollapsed = isCollapsed
        self.intake = intake
    }

    var isEmpty: Bool { items.isEmpty }

    /// "3 items · 4.2 MB" — the subtitle under the shelf name.
    var summary: String {
        let count = items.count == 1 ? "1 item" : "\(items.count) items"
        let bytes = items.reduce(Int64(0)) { $0 + $1.byteCount }
        guard bytes > 0 else { return count }
        return "\(count) · \(Self.byteFormatter.string(fromByteCount: bytes))"
    }

    /// Named for when it was made. A shelf is usually short-lived and never
    /// renamed, so the default has to be something you can tell apart from the
    /// other three on screen — "Shelf 1" is not.
    private static func defaultName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    /// The colours a shelf can be tagged with, in menu order.
    ///
    /// Chosen to stay legible as a thin edge over both Liquid Glass and a solid
    /// panel, which rules out anything pale — a yellow hairline vanishes on a
    /// light desktop.
    static let tints: [(name: String, color: NSColor)] = [
        ("Blue", NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1)),
        ("Purple", NSColor(srgbRed: 0.58, green: 0.35, blue: 0.95, alpha: 1)),
        ("Pink", NSColor(srgbRed: 0.96, green: 0.30, blue: 0.55, alpha: 1)),
        ("Red", NSColor(srgbRed: 0.96, green: 0.26, blue: 0.21, alpha: 1)),
        ("Orange", NSColor(srgbRed: 0.98, green: 0.55, blue: 0.09, alpha: 1)),
        ("Green", NSColor(srgbRed: 0.20, green: 0.70, blue: 0.32, alpha: 1)),
        ("Graphite", NSColor(srgbRed: 0.45, green: 0.47, blue: 0.50, alpha: 1))
    ]

    var tint: NSColor {
        Self.tints[min(max(tintIndex, 0), Self.tints.count - 1)].color
    }

    enum CodingKeys: String, CodingKey {
        case id, name, tintIndex, items, createdAt, windowTopLeft, isCollapsed, intake
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tintIndex = try container.decode(Int.self, forKey: .tintIndex)
        items = try container.decode([ShelfItem].self, forKey: .items)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        windowTopLeft = try container.decodeIfPresent(CGPoint.self, forKey: .windowTopLeft)
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        if let stored = try container.decodeIfPresent(Intake.self, forKey: .intake) {
            intake = stored
        } else if !items.isEmpty, items.allSatisfy({ $0.origin == .staged }) {
            intake = .move
        } else {
            intake = .copy
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(tintIndex, forKey: .tintIndex)
        try container.encode(items, forKey: .items)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(windowTopLeft, forKey: .windowTopLeft)
        try container.encode(isCollapsed, forKey: .isCollapsed)
        try container.encode(intake, forKey: .intake)
    }
}
