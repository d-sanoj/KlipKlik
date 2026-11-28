import Foundation

/// A program to run, exactly as it will be run: an absolute executable and an
/// argument array, handed to `Process` with no shell in between. Nothing in it
/// is ever interpolated into a command line, so a file named `; rm -rf ~` is
/// only a strange file name.
struct PlinthProcess: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
    /// Set for `zip`, which stores paths relative to where it runs.
    var workingDirectory: URL?
    /// The file this run creates, removed again if the run fails.
    var output: URL?
    /// For ffmpeg: the input whose duration progress is measured against.
    var progressInput: URL?

    /// The command as text, for the preview only. Never executed.
    var displayString: String {
        ([executable.lastPathComponent] + arguments.map(Self.quoted)).joined(separator: " ")
    }

    private static func quoted(_ argument: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=+%,@"))
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// One step of a plan. Most are programs; the rest are done in-process,
/// where Foundation or PDFKit already does the job without a shell.
enum PlinthStep: Equatable, Sendable {
    case run(PlinthProcess)
    case mergePDFs(inputs: [URL], output: URL)
    /// Old → new, done in two passes so swapped names cannot collide.
    case rename([PlinthRename])
    /// Moved to the Trash, never deleted outright.
    case trash([URL])

    var displayString: String {
        switch self {
        case .run(let process): return process.displayString
        case .mergePDFs(let inputs, let output):
            return "merge \(inputs.count) PDFs → \(output.lastPathComponent)"
        case .rename(let pairs): return "rename \(pairs.count) item\(pairs.count == 1 ? "" : "s")"
        case .trash(let urls): return "move \(urls.count) original\(urls.count == 1 ? "" : "s") to the Trash"
        }
    }
}

struct PlinthRename: Equatable, Sendable {
    let from: URL
    let to: URL
}

/// What the plan will do to the disk, for the preview to list.
struct PlinthEffect: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case create
        case rename(from: URL)
        case trash
    }

    let kind: Kind
    let url: URL

    var isDestructive: Bool {
        switch kind {
        case .create: return false
        case .rename, .trash: return true
        }
    }
}

/// Programs Plinth needs that may not be on the Mac. The system ones (`sips`,
/// `zip`, `ditto`) ship with every macOS, so only ffmpeg is listed.
enum PlinthTool: String, Sendable {
    case ffmpeg

    var formula: String { rawValue }
}

/// Everything a request will do, worked out before anything runs.
struct PlinthPlan: Equatable, Sendable {
    let command: PlinthCommand
    /// "Convert 3 videos to MP4 (1080p)".
    let title: String
    let steps: [PlinthStep]
    let effects: [PlinthEffect]
    /// Selected items this action does not apply to — the PDF among videos.
    let skipped: [URL]
    let missingTools: [PlinthTool]

    /// Renames and trashing need a second "yes"; creating new files does not,
    /// because a new file next to the old one costs nothing to throw away.
    var isDestructive: Bool { effects.contains(where: \.isDestructive) }

    var created: [URL] { effects.filter { $0.kind == .create }.map(\.url) }
}

/// Why a request cannot become a plan. Every message is written to be shown
/// as-is, in the bar.
enum PlinthError: Error, Equatable, Sendable {
    case emptySelection
    case tooManyItems(limit: Int)
    case noApplicableItems(String)
    case invalidValue(String)
    case nameConflict(String)
    case nothingToChange
    case unsupportedRequest
    case requestTooLong(limit: Int)
    case modelUnavailable(String)
    case modelFailed(String)
    case automationDenied
    case finderFailed(String)

    var message: String {
        switch self {
        case .emptySelection:
            return "Select some files in Finder first."
        case .tooManyItems(let limit):
            return "Plinth works on up to \(limit) items at once. Select fewer."
        case .noApplicableItems(let detail):
            return detail
        case .invalidValue(let detail):
            return detail
        case .nameConflict(let detail):
            return detail
        case .nothingToChange:
            return "That wouldn't change anything."
        case .unsupportedRequest:
            return "I can't do that yet. Try converting, resizing, compressing, zipping, renaming or merging PDFs."
        case .requestTooLong(let limit):
            return "Keep the request under \(limit) characters."
        case .modelUnavailable(let detail):
            return detail
        case .modelFailed(let detail):
            return detail
        case .automationDenied:
            return "KlipKlik needs permission to read Finder's selection. Allow it under Privacy & Security ▸ Automation."
        case .finderFailed(let detail):
            return "Finder didn't answer: \(detail)"
        }
    }
}
