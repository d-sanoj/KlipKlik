import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Anything that can turn a request into a raw intent. The Apple
/// Intelligence model is the only one today; an Ollama or API-key backend is
/// meant to slot in behind the same protocol later.
@MainActor
protocol PlinthInterpreter: AnyObject {
    func interpret(_ request: String, selection: PlinthSelectionSummary) async throws -> PlinthRawIntent
    /// Loads the model ahead of the first request, when the bar gets focus.
    func prewarm()
}

enum PlinthModelAvailability: Equatable {
    case available
    /// Why not, in words to show in the bar.
    case unavailable(String)
}

/// Which model Plinth can use on this Mac, and why not when it cannot.
@MainActor
enum PlinthModel {
    static var availability: PlinthModelAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return AppleIntelligenceInterpreter.availability
        }
        return .unavailable("Typed requests need macOS 26 with Apple Intelligence. "
            + "Zip, JPG, PNG and PDF still work.")
        #else
        return .unavailable("This copy of KlipKlik was built without Apple's Foundation Models. "
            + "Zip, JPG, PNG and PDF still work.")
        #endif
    }

    /// A fresh interpreter, or nil when no model is available.
    static func makeInterpreter() -> PlinthInterpreter? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), availability == .available {
            return AppleIntelligenceInterpreter()
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)

/// Apple's on-device model, through guided generation.
///
/// The model never produces free text here: `respond(generating:)` constrains
/// its output to the `PlinthGeneratedIntent` schema token by token, so what
/// comes back is always one of the listed actions with typed fields — which
/// `PlinthIntentValidator` then checks again before anything is built.
@available(macOS 26.0, *)
@MainActor
final class AppleIntelligenceInterpreter: PlinthInterpreter {
    /// A session made and warmed when the bar is focused, used by the next
    /// request and then dropped. One session per request keeps the transcript
    /// — and so the 4,096-token context — from growing between requests.
    private var warmSession: LanguageModelSession?

    static var availability: PlinthModelAvailability {
        let model = SystemLanguageModel.default
        if case .available = model.availability { return .available }
        guard case .unavailable(let reason) = model.availability else {
            return .unavailable("Apple Intelligence isn't available right now.")
        }
        switch reason {
        case .deviceNotEligible:
            return .unavailable("This Mac can't run Apple Intelligence, so typed requests are off. "
                + "Zip, JPG, PNG and PDF still work.")
        case .appleIntelligenceNotEnabled:
            return .unavailable("Turn on Apple Intelligence in System Settings to type requests. "
                + "Zip, JPG, PNG and PDF work without it.")
        case .modelNotReady:
            return .unavailable("Apple Intelligence is still downloading its model. "
                + "Try again in a little while; zip, JPG, PNG and PDF work now.")
        @unknown default:
            return .unavailable("Apple Intelligence isn't available right now.")
        }
    }

    func prewarm() {
        guard warmSession == nil else { return }
        let session = Self.makeSession()
        session.prewarm()
        warmSession = session
    }

    func interpret(_ request: String, selection: PlinthSelectionSummary) async throws -> PlinthRawIntent {
        let session = warmSession ?? Self.makeSession()
        warmSession = nil
        do {
            let response = try await session.respond(
                to: PlinthPrompt.prompt(request: request, selection: selection),
                generating: PlinthGeneratedIntent.self,
                includeSchemaInPrompt: true,
                // Greedy: the same request on the same files gives the same
                // answer, which is what a command bar — and the eval — needs.
                options: GenerationOptions(sampling: .greedy)
            )
            return response.content.raw
        } catch let error as LanguageModelSession.GenerationError {
            throw PlinthError.modelFailed(Self.explain(error))
        }
    }

    private static func makeSession() -> LanguageModelSession {
        LanguageModelSession(model: SystemLanguageModel.default, instructions: PlinthPrompt.instructions)
    }

    private static func explain(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            return "That request is too long for the on-device model. Try fewer words."
        case .guardrailViolation:
            return "Apple Intelligence declined that request."
        case .unsupportedLanguageOrLocale:
            return "Apple Intelligence doesn't support this language yet. Try English."
        case .assetsUnavailable:
            return "Apple Intelligence's model isn't ready. Try again in a little while."
        case .rateLimited:
            return "Apple Intelligence is busy. Try again in a moment."
        case .decodingFailure:
            return "I couldn't understand that. Try wording it differently."
        default:
            return "Apple Intelligence couldn't answer: \(error.localizedDescription)"
        }
    }
}

// MARK: - Guided generation schema

// Property names, case names and guide descriptions all become part of the
// prompt, so each is a word or two. Order matters too: the model fills the
// fields top to bottom, so the action comes first and conditions the rest.

@available(macOS 26.0, *)
@Generable(description: "One action on the selected files")
struct PlinthGeneratedIntent {
    @Guide(description: "What to do")
    var action: PlinthGeneratedKind

    @Guide(description: "Target file format")
    var format: PlinthGeneratedFormat?

    @Guide(description: "Video height in pixels")
    var videoHeight: Int?

    @Guide(description: "Resize percent")
    var percent: Int?

    @Guide(description: "Longest side in pixels")
    var maxPixels: Int?

    @Guide(description: "Width in pixels")
    var width: Int?

    @Guide(description: "Height of a picture in pixels")
    var height: Int?

    @Guide(description: "Compression quality")
    var quality: PlinthGeneratedQuality?

    @Guide(description: "New name using {name} {n} {date}")
    var renameTemplate: String?

    @Guide(description: "Text to find in names")
    var find: String?

    @Guide(description: "Replacement text")
    var replace: String?

    @Guide(description: "Text to add before names")
    var prefix: String?

    @Guide(description: "Text to add after names")
    var suffix: String?

    @Guide(description: "Letter case for names")
    var letterCase: PlinthGeneratedCase?

    @Guide(description: "Name for a zip or merged PDF")
    var outputName: String?

    @Guide(description: "True only if asked to replace or delete the originals")
    var trashOriginals: Bool?

    /// Into the plain, FoundationModels-free form the validator checks.
    var raw: PlinthRawIntent {
        PlinthRawIntent(
            kind: action.kind,
            format: format?.text,
            videoHeight: videoHeight,
            percent: percent,
            maxPixels: maxPixels,
            width: width,
            height: height,
            quality: quality?.text,
            renameTemplate: renameTemplate,
            find: find,
            replace: replace,
            prefix: prefix,
            suffix: suffix,
            letterCase: letterCase?.text,
            outputName: outputName,
            trashOriginals: trashOriginals
        )
    }
}

/// The typed action enum the model chooses from.
@available(macOS 26.0, *)
@Generable
enum PlinthGeneratedKind {
    case convertVideo, compressVideo, convertImage, resizeImage, compressImage
    case zip, unzip, rename, mergePDFs, unsupported

    var kind: PlinthIntentKind {
        switch self {
        case .convertVideo: return .convertVideo
        case .compressVideo: return .compressVideo
        case .convertImage: return .convertImage
        case .resizeImage: return .resizeImage
        case .compressImage: return .compressImage
        case .zip: return .zip
        case .unzip: return .unzip
        case .rename: return .rename
        case .mergePDFs: return .mergePDFs
        case .unsupported: return .unsupported
        }
    }
}

@available(macOS 26.0, *)
@Generable
enum PlinthGeneratedFormat {
    case mp4, mov, webm, mkv, gif, mp3, m4a, wav, jpg, png, heic, tiff, bmp, pdf

    var text: String {
        switch self {
        case .mp4: return "mp4"
        case .mov: return "mov"
        case .webm: return "webm"
        case .mkv: return "mkv"
        case .gif: return "gif"
        case .mp3: return "mp3"
        case .m4a: return "m4a"
        case .wav: return "wav"
        case .jpg: return "jpg"
        case .png: return "png"
        case .heic: return "heic"
        case .tiff: return "tiff"
        case .bmp: return "bmp"
        case .pdf: return "pdf"
        }
    }
}

@available(macOS 26.0, *)
@Generable
enum PlinthGeneratedQuality {
    case low, medium, high

    var text: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }
}

@available(macOS 26.0, *)
@Generable
enum PlinthGeneratedCase {
    case lower, upper, title

    var text: String {
        switch self {
        case .lower: return "lower"
        case .upper: return "upper"
        case .title: return "title"
        }
    }
}

#endif
