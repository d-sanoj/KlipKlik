import Foundation

/// What a selected item is, by its extension.
///
/// A fixed table rather than UTType lookups: the answer has to be the same on
/// every Mac and in every test run, and an extension the table does not know
/// is simply "other" — which no action accepts, so nothing unexpected runs.
enum PlinthFileKind: String, CaseIterable, Sendable {
    case video, audio, image, pdf, zip, folder, other

    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "3gp", "ts", "mts", "m2ts"
    ]
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus", "caf"
    ]
    /// Everything `sips` reads. GIF is a picture here; an animated GIF can
    /// still go to video formats through ffmpeg, but that is not offered.
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "jp2", "psd", "avif", "tga"
    ]

    static func of(_ url: URL, isDirectory: Bool) -> PlinthFileKind {
        if isDirectory {
            // A package (.app, .photoslibrary) is a folder too; only zipping
            // and renaming accept folders, and both are safe on packages.
            return .folder
        }
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if ext == "zip" { return .zip }
        return .other
    }

    /// The plural the preview uses: "3 videos".
    func counted(_ count: Int) -> String {
        let noun: String
        switch self {
        case .video: noun = count == 1 ? "video" : "videos"
        case .audio: noun = count == 1 ? "audio file" : "audio files"
        case .image: noun = count == 1 ? "picture" : "pictures"
        case .pdf: noun = count == 1 ? "PDF" : "PDFs"
        case .zip: noun = count == 1 ? "zip archive" : "zip archives"
        case .folder: noun = count == 1 ? "folder" : "folders"
        case .other: noun = count == 1 ? "file" : "files"
        }
        return "\(count) \(noun)"
    }
}

/// One selected Finder item, with its kind worked out once.
struct PlinthItem: Equatable, Sendable {
    let url: URL
    let kind: PlinthFileKind

    init(url: URL, kind: PlinthFileKind) {
        self.url = url
        self.kind = kind
    }

    init(url: URL, isDirectory: Bool) {
        self.init(url: url, kind: PlinthFileKind.of(url, isDirectory: isDirectory))
    }
}

/// The selection as the language model sees it: counts and extensions, never
/// names or paths. That keeps the prompt a few dozen tokens long, and a file
/// called "ignore previous instructions.mov" is just one more .mov.
struct PlinthSelectionSummary: Equatable, Sendable {
    let total: Int
    /// Kind → count, only the kinds present.
    let kinds: [PlinthFileKind: Int]
    /// The commonest extensions first, at most five.
    let extensions: [String]

    init(_ items: [PlinthItem]) {
        total = items.count
        var kinds: [PlinthFileKind: Int] = [:]
        var extensionCounts: [String: Int] = [:]
        for item in items {
            kinds[item.kind, default: 0] += 1
            let ext = item.url.pathExtension.lowercased()
            if item.kind != .folder, !ext.isEmpty { extensionCounts[ext, default: 0] += 1 }
        }
        self.kinds = kinds
        extensions = extensionCounts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(5)
            .map(\.key)
    }

    /// The kind most of the selection is, ties broken in a fixed order.
    var dominantKind: PlinthFileKind? {
        kinds.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.order > rhs.key.order
        }?.key
    }

    func count(of kind: PlinthFileKind) -> Int { kinds[kind] ?? 0 }

    /// "3 videos (.mov, .mp4)", the line the prompt carries.
    var promptLine: String {
        guard total > 0 else { return "nothing" }
        let parts = PlinthFileKind.allCases.compactMap { kind -> String? in
            guard let count = kinds[kind] else { return nil }
            return kind.counted(count)
        }
        let exts = extensions.map { "." + $0 }.joined(separator: ", ")
        return parts.joined(separator: ", ") + (exts.isEmpty ? "" : " (\(exts))")
    }
}

private extension PlinthFileKind {
    /// Tie-break order for `dominantKind`.
    var order: Int { PlinthFileKind.allCases.firstIndex(of: self) ?? 0 }
}
