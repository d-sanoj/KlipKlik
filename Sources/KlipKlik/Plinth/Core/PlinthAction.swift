import Foundation

// Plinth's vocabulary: every thing the command bar can do, as plain values.
//
// Nothing here is a shell string. The language model only ever chooses one of
// these cases and fills in its numbers and names; `PlinthCommandBuilder` turns
// the chosen case into the exact program and argument list to run. A model
// that misbehaves can therefore pick the wrong action, but it can never write
// a command.
//
// Foundation only, on purpose: the whole of Plinth's core compiles and tests
// without AppKit, Finder or a language model.

/// One validated thing to do to the selected files.
enum PlinthAction: Equatable, Sendable {
    /// Re-encode videos with ffmpeg, optionally no taller than `maxHeight`.
    /// The audio-only targets (MP3, M4A, WAV) also accept audio files.
    case convertVideo(to: PlinthVideoFormat, maxHeight: Int?)
    /// A smaller HEVC copy of each video.
    case compressVideo(quality: PlinthQuality, maxHeight: Int?)
    /// Pictures into another format with `sips`.
    case convertImage(to: PlinthImageFormat)
    case resizeImage(PlinthResize)
    /// A lighter JPEG (or HEIC, when the original is HEIC) of each picture.
    case compressImage(quality: PlinthQuality)
    /// Everything selected into one archive. `name` without ".zip".
    case zip(name: String?)
    /// Each selected .zip expanded into a folder beside it.
    case unzip
    case rename(PlinthRenameRule)
    /// The selected PDFs into one, in name order. `name` without ".pdf".
    case mergePDFs(name: String?)

    /// Words for the preview's title: "Convert to MP4 (1080p)".
    var title: String {
        switch self {
        case .convertVideo(let format, let height):
            return "Convert to \(format.label)" + (height.map { " (\(PlinthResolution.label(for: $0)))" } ?? "")
        case .compressVideo(let quality, let height):
            return "Compress video, \(quality.rawValue) quality"
                + (height.map { ", up to \(PlinthResolution.label(for: $0))" } ?? "")
        case .convertImage(let format):
            return "Convert to \(format.label)"
        case .resizeImage(let resize):
            return "Resize to \(resize.label)"
        case .compressImage(let quality):
            return "Compress pictures, \(quality.rawValue) quality"
        case .zip(let name):
            return name.map { "Zip into \($0).zip" } ?? "Zip"
        case .unzip:
            return "Unzip"
        case .rename:
            return "Rename"
        case .mergePDFs(let name):
            return "Merge PDFs" + (name.map { " into \($0).pdf" } ?? "")
        }
    }

    /// Whether ffmpeg has to be installed for this action.
    var needsFFmpeg: Bool {
        switch self {
        case .convertVideo, .compressVideo: return true
        default: return false
        }
    }
}

/// An action plus the one option that applies to several of them: whether the
/// originals go to the Trash once the new files are written.
///
/// Kept apart from `PlinthAction` so a "replace the originals" request is a
/// single flag the preview can show in red, not a variant of every case.
struct PlinthCommand: Equatable, Sendable {
    var action: PlinthAction
    /// Only honoured for conversions, compressions and resizes; every other
    /// action already changes the files themselves or never touches them.
    var trashOriginals: Bool = false

    init(_ action: PlinthAction, trashOriginals: Bool = false) {
        self.action = action
        self.trashOriginals = trashOriginals && Self.canTrashOriginals(action)
    }

    static func canTrashOriginals(_ action: PlinthAction) -> Bool {
        switch action {
        case .convertVideo, .compressVideo, .convertImage, .resizeImage, .compressImage: return true
        case .zip, .unzip, .rename, .mergePDFs: return false
        }
    }
}

enum PlinthVideoFormat: String, CaseIterable, Sendable {
    case mp4, mov, webm, mkv, gif, mp3, m4a, wav

    var label: String {
        switch self {
        case .gif: return "animated GIF"
        default: return rawValue.uppercased()
        }
    }

    var fileExtension: String { rawValue }

    /// MP3, M4A and WAV keep only the sound.
    var isAudioOnly: Bool { self == .mp3 || self == .m4a || self == .wav }
}

enum PlinthImageFormat: String, CaseIterable, Sendable {
    case jpg, png, heic, tiff, gif, bmp, pdf

    var label: String { self == .jpg ? "JPEG" : rawValue.uppercased() }

    var fileExtension: String { rawValue }

    /// The name `sips -s format` uses.
    var sipsName: String {
        switch self {
        case .jpg: return "jpeg"
        default: return rawValue
        }
    }
}

/// Low quality is the smallest file.
enum PlinthQuality: String, CaseIterable, Sendable {
    case low, medium, high

    /// x265's constant rate factor: higher is smaller.
    var videoCRF: Int {
        switch self {
        case .low: return 32
        case .medium: return 28
        case .high: return 24
        }
    }

    /// `sips` JPEG / HEIC quality, 0–100.
    var imageQuality: Int {
        switch self {
        case .low: return 45
        case .medium: return 65
        case .high: return 82
        }
    }
}

enum PlinthResize: Equatable, Sendable {
    case percent(Int)
    /// The longer of width and height, in pixels.
    case longestSide(Int)
    case width(Int)
    case height(Int)

    var label: String {
        switch self {
        case .percent(let value): return "\(value)%"
        case .longestSide(let value): return "\(value) px"
        case .width(let value): return "\(value) px wide"
        case .height(let value): return "\(value) px tall"
        }
    }

    /// The part of the new file's name that says how it was resized.
    var nameSuffix: String {
        switch self {
        case .percent(let value): return "\(value)%"
        case .longestSide(let value): return "\(value)px"
        case .width(let value): return "\(value)w"
        case .height(let value): return "\(value)h"
        }
    }
}

enum PlinthLetterCase: String, CaseIterable, Sendable {
    case lower, upper, title
}

/// How to rename. Every part is optional and they apply in a fixed order:
/// find-and-replace, then letter case, then the template, then the prefix and
/// suffix. The extension is never touched, so a rename cannot turn a picture
/// into a file nothing will open.
struct PlinthRenameRule: Equatable, Sendable {
    var find: String?
    var replace: String?
    /// The new name with tokens: `{name}` the current name, `{n}` a number
    /// counting from 1 (zero-padded to the selection's size), `{date}` the
    /// file's creation date as 2026-11-28.
    var template: String?
    var prefix: String?
    var suffix: String?
    var letterCase: PlinthLetterCase?

    init(find: String? = nil, replace: String? = nil, template: String? = nil,
         prefix: String? = nil, suffix: String? = nil, letterCase: PlinthLetterCase? = nil) {
        self.find = find
        self.replace = replace
        self.template = template
        self.prefix = prefix
        self.suffix = suffix
        self.letterCase = letterCase
    }

    /// True when applying it could not change any name.
    var isEmpty: Bool {
        (find ?? "").isEmpty && (template ?? "").isEmpty && (prefix ?? "").isEmpty
            && (suffix ?? "").isEmpty && letterCase == nil
    }
}

/// "1080p", "4K": the names people use for heights.
enum PlinthResolution {
    static func label(for height: Int) -> String {
        switch height {
        case 2160: return "4K"
        case 4320: return "8K"
        default: return "\(height)p"
        }
    }
}
