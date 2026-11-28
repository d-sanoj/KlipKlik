import Foundation

/// The kinds of action the language model may choose. Mirrors the
/// `@Generable` enum one to one, but lives here, free of FoundationModels, so
/// validation and the eval suite's expectations compile everywhere.
enum PlinthIntentKind: String, CaseIterable, Sendable {
    case convertVideo, compressVideo, convertImage, resizeImage, compressImage
    case zip, unzip, rename, mergePDFs
    /// The model's way of saying no action fits. Always refused.
    case unsupported
}

/// What the model filled in, before anyone trusts it: every field optional,
/// every string unchecked, every number possibly absurd.
struct PlinthRawIntent: Equatable, Sendable {
    var kind: PlinthIntentKind
    var format: String?
    var videoHeight: Int?
    var percent: Int?
    var maxPixels: Int?
    var width: Int?
    var height: Int?
    var quality: String?
    var renameTemplate: String?
    var find: String?
    var replace: String?
    var prefix: String?
    var suffix: String?
    var letterCase: String?
    var outputName: String?
    var trashOriginals: Bool?

    init(kind: PlinthIntentKind, format: String? = nil, videoHeight: Int? = nil, percent: Int? = nil,
         maxPixels: Int? = nil, width: Int? = nil, height: Int? = nil, quality: String? = nil,
         renameTemplate: String? = nil, find: String? = nil, replace: String? = nil,
         prefix: String? = nil, suffix: String? = nil, letterCase: String? = nil,
         outputName: String? = nil, trashOriginals: Bool? = nil) {
        self.kind = kind
        self.format = format
        self.videoHeight = videoHeight
        self.percent = percent
        self.maxPixels = maxPixels
        self.width = width
        self.height = height
        self.quality = quality
        self.renameTemplate = renameTemplate
        self.find = find
        self.replace = replace
        self.prefix = prefix
        self.suffix = suffix
        self.letterCase = letterCase
        self.outputName = outputName
        self.trashOriginals = trashOriginals
    }
}

/// Turns a raw model answer into a `PlinthCommand`, or refuses it.
///
/// This is the gate every model output passes through. It rejects unknown
/// formats, out-of-range numbers, names that are not file names and text that
/// is too long; it corrects the one mistake small models make most — calling
/// a video conversion an image conversion — from what is actually selected;
/// and it drops fields that do not belong to the chosen action, so a stray
/// `trashOriginals` on a zip changes nothing.
enum PlinthIntentValidator {
    static let maxTextLength = 80

    static func command(from raw: PlinthRawIntent, selection: PlinthSelectionSummary) throws -> PlinthCommand {
        let kind = corrected(raw.kind, format: raw.format, selection: selection)
        let trash = raw.trashOriginals ?? false

        switch kind {
        case .unsupported:
            throw PlinthError.unsupportedRequest

        case .convertVideo:
            guard let format = raw.format.flatMap(videoFormat) else {
                throw PlinthError.invalidValue("Say which format to convert to, like MP4, MOV, WebM or GIF.")
            }
            let height: Int? = try format.isAudioOnly ? nil : checkedHeight(raw.videoHeight ?? raw.height)
            return PlinthCommand(.convertVideo(to: format, maxHeight: height), trashOriginals: trash)

        case .compressVideo:
            let quality = try checkedQuality(raw.quality)
            let height = try checkedHeight(raw.videoHeight ?? raw.height)
            return PlinthCommand(.compressVideo(quality: quality, maxHeight: height), trashOriginals: trash)

        case .convertImage:
            guard let format = raw.format.flatMap(imageFormat) else {
                throw PlinthError.invalidValue("Say which format to convert to, like JPEG, PNG, HEIC or PDF.")
            }
            return PlinthCommand(.convertImage(to: format), trashOriginals: trash)

        case .resizeImage:
            let resize: PlinthResize
            if let percent = raw.percent {
                resize = .percent(percent)
            } else if let pixels = raw.maxPixels {
                resize = .longestSide(pixels)
            } else if let width = raw.width {
                resize = .width(width)
            } else if let height = raw.height {
                resize = .height(height)
            } else {
                throw PlinthError.invalidValue("Say how big, like 50% or 1024 pixels.")
            }
            try PlinthLimits.check(resize)
            return PlinthCommand(.resizeImage(resize), trashOriginals: trash)

        case .compressImage:
            return PlinthCommand(.compressImage(quality: try checkedQuality(raw.quality)), trashOriginals: trash)

        case .zip:
            let name = try cleanText(raw.outputName).map { try PlinthNames.checkedBaseName($0, extension: "zip") }
            return PlinthCommand(.zip(name: name))

        case .unzip:
            return PlinthCommand(.unzip)

        case .rename:
            let rule = PlinthRenameRule(
                find: try cleanText(raw.find, allowEmpty: false),
                replace: try cleanText(raw.replace, allowEmpty: true),
                template: try cleanText(raw.renameTemplate, allowEmpty: false),
                prefix: try cleanText(raw.prefix, allowEmpty: false),
                suffix: try cleanText(raw.suffix, allowEmpty: false),
                letterCase: raw.letterCase.flatMap { PlinthLetterCase(rawValue: $0.lowercased()) }
            )
            for part in [rule.find, rule.replace, rule.template, rule.prefix, rule.suffix].compactMap({ $0 })
            where part.contains("/") || part.contains(":") {
                throw PlinthError.invalidValue("A file name can't contain “/” or “:”.")
            }
            guard !rule.isEmpty else {
                throw PlinthError.invalidValue("Say how to rename, like “add a date” or “replace IMG with Trip”.")
            }
            return PlinthCommand(.rename(rule))

        case .mergePDFs:
            let name = try cleanText(raw.outputName).map { try PlinthNames.checkedBaseName($0, extension: "pdf") }
            return PlinthCommand(.mergePDFs(name: name))
        }
    }

    /// Picture or video, decided by the selection when the model guessed
    /// against it. "Convert to GIF" on three .mov files is a video job however
    /// the model labelled it.
    static func corrected(_ kind: PlinthIntentKind, format: String?,
                          selection: PlinthSelectionSummary) -> PlinthIntentKind {
        let videos = selection.count(of: .video) + selection.count(of: .audio)
        let pictures = selection.count(of: .image)
        switch kind {
        case .convertImage where videos > pictures && format.flatMap(videoFormat) != nil:
            return .convertVideo
        case .convertVideo where pictures > videos && format.flatMap(imageFormat) != nil:
            return .convertImage
        case .compressImage where videos > pictures:
            return .compressVideo
        case .compressVideo where pictures > videos:
            return .compressImage
        case .convertImage where format?.lowercased() == "pdf"
            && selection.count(of: .pdf) == selection.total && selection.total > 1:
            // "Make one PDF" with only PDFs selected means merge them.
            return .mergePDFs
        default:
            return kind
        }
    }

    static func videoFormat(_ text: String) -> PlinthVideoFormat? {
        switch normalized(text) {
        case "mp4", "h264", "h.264": return .mp4
        case "mov", "quicktime": return .mov
        case "webm", "vp9": return .webm
        case "mkv", "matroska": return .mkv
        case "gif", "animatedgif": return .gif
        case "mp3": return .mp3
        case "m4a", "aac": return .m4a
        case "wav", "wave": return .wav
        default: return nil
        }
    }

    static func imageFormat(_ text: String) -> PlinthImageFormat? {
        switch normalized(text) {
        case "jpg", "jpeg": return .jpg
        case "png": return .png
        case "heic", "heif": return .heic
        case "tiff", "tif": return .tiff
        case "gif": return .gif
        case "bmp": return .bmp
        case "pdf": return .pdf
        default: return nil
        }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && $0 != "." && $0 != "-" }
    }

    private static func checkedHeight(_ height: Int?) throws -> Int? {
        guard let height else { return nil }
        guard PlinthLimits.videoHeight.contains(height) else {
            throw PlinthError.invalidValue("A video height has to be between "
                + "\(PlinthLimits.videoHeight.lowerBound) and \(PlinthLimits.videoHeight.upperBound) pixels.")
        }
        return height
    }

    private static func checkedQuality(_ text: String?) throws -> PlinthQuality {
        guard let text, !text.isEmpty else { return .medium }
        guard let quality = PlinthQuality(rawValue: text.lowercased()) else {
            throw PlinthError.invalidValue("Quality is low, medium or high.")
        }
        return quality
    }

    /// Trimmed, bounded, free of control characters. Empty becomes nil unless
    /// `allowEmpty` — "replace IMG with nothing" has an empty replacement.
    private static func cleanText(_ text: String?, allowEmpty: Bool = false) throws -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .newlines)
        if trimmed.isEmpty { return allowEmpty ? "" : nil }
        guard trimmed.count <= maxTextLength,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw PlinthError.invalidValue("That name is too long or has characters a file name can't.") }
        return trimmed
    }
}

/// One-word requests that need no model at all: they run the moment ↩ is
/// pressed, whether or not Apple Intelligence is on.
enum PlinthInstantActions {
    /// The words the bar offers as chips.
    static let chips = ["zip", "jpg", "png", "pdf"]

    static func command(for request: String, selection: PlinthSelectionSummary) -> PlinthCommand? {
        let word = request.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch word {
        case "zip", "compress to zip", "archive":
            return PlinthCommand(.zip(name: nil))
        case "unzip", "extract":
            return PlinthCommand(.unzip)
        case "jpg", "jpeg":
            return PlinthCommand(.convertImage(to: .jpg))
        case "png":
            return PlinthCommand(.convertImage(to: .png))
        case "heic":
            return PlinthCommand(.convertImage(to: .heic))
        case "pdf":
            // Several PDFs: one PDF out of them. Pictures: a PDF of each.
            let pdfs = selection.count(of: .pdf)
            if pdfs >= 2, pdfs == selection.total { return PlinthCommand(.mergePDFs(name: nil)) }
            return PlinthCommand(.convertImage(to: .pdf))
        case "mp4":
            return PlinthCommand(.convertVideo(to: .mp4, maxHeight: nil))
        default:
            return nil
        }
    }
}

/// The words sent to the on-device model.
///
/// Its context is 4,096 tokens for instructions, schema, prompt and answer
/// together, and every token is latency, so all of it is kept small: short
/// instructions, a handful of one-line examples, the selection as counts and
/// extensions, and the request capped at 300 characters. The schema of
/// `PlinthGeneratedIntent` is added by the framework itself.
enum PlinthPrompt {
    static let instructions = """
    Turn a request about selected Finder files into one action. Fill only the fields the request \
    gives; leave the rest empty. Heights: 4K=2160, 1080p=1080, 720p=720, 480p=480. "Smaller" or \
    "shrink" a video means compressVideo; for pictures, a percentage or pixel size means resizeImage, \
    otherwise compressImage. Rename templates use {name}, {n} and {date}. If nothing fits, use unsupported.
    Examples:
    "convert to 1080p mp4" -> convertVideo, format mp4, videoHeight 1080
    "make these gifs" -> convertVideo, format gif
    "half size" -> resizeImage, percent 50
    "zip as Photos" -> zip, outputName Photos
    "number them Trip" -> rename, renameTemplate "Trip {n}"
    "replace IMG_ with Rome " -> rename, find "IMG_", replace "Rome "
    "combine into one pdf" -> mergePDFs
    """

    static func prompt(request: String, selection: PlinthSelectionSummary) -> String {
        "Selected: \(selection.promptLine)\nRequest: \(request)"
    }

    /// Rough size of what is sent, at the usual four characters a token, for
    /// the budget test.
    static func estimatedTokens(request: String, selection: PlinthSelectionSummary) -> Int {
        (instructions.count + prompt(request: request, selection: selection).count) / 4
    }
}
