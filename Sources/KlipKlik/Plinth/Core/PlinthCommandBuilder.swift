import Foundation

/// Where Plinth's programs live. The system tools are fixed paths that ship
/// with macOS; ffmpeg is wherever Homebrew put it, or nil.
struct PlinthToolPaths: Equatable, Sendable {
    var ffmpeg: URL?
    var sips = URL(fileURLWithPath: "/usr/bin/sips")
    var zip = URL(fileURLWithPath: "/usr/bin/zip")
    var ditto = URL(fileURLWithPath: "/usr/bin/ditto")

    /// Shown in a preview when ffmpeg is missing, so the user still sees the
    /// command that will run once it is installed.
    static let expectedFFmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")

    init(ffmpeg: URL?) {
        self.ffmpeg = ffmpeg
    }
}

/// The questions the builder asks the disk, as closures so tests can answer
/// them without one.
struct PlinthFileProbe {
    var exists: (URL) -> Bool
    var isWritableDirectory: (URL) -> Bool
    /// Pixel width and height of a picture, orientation applied.
    var pixelSize: (URL) -> (width: Int, height: Int)?
    var creationDate: (URL) -> Date?
}

/// Turns a validated `PlinthCommand` and the Finder selection into a
/// `PlinthPlan`: every program, every argument and every file it will touch.
///
/// Pure: it reads only through `probe` and writes nothing, so the preview the
/// user approves is exactly what `PlinthRunner` later executes.
struct PlinthCommandBuilder {
    static let itemLimit = 500

    var tools: PlinthToolPaths
    var probe: PlinthFileProbe
    /// Where results go when the original's folder cannot be written to.
    var fallbackDirectory: URL
    var timeZone: TimeZone = .current

    func plan(_ command: PlinthCommand, for items: [PlinthItem]) throws -> PlinthPlan {
        guard !items.isEmpty else { throw PlinthError.emptySelection }
        guard items.count <= Self.itemLimit else { throw PlinthError.tooManyItems(limit: Self.itemLimit) }

        var draft: Draft
        switch command.action {
        case .convertVideo(let format, let height):
            draft = try convertVideo(items, to: format, maxHeight: height)
        case .compressVideo(let quality, let height):
            draft = try compressVideo(items, quality: quality, maxHeight: height)
        case .convertImage(let format):
            draft = try convertImage(items, to: format)
        case .resizeImage(let resize):
            draft = try resizeImage(items, resize)
        case .compressImage(let quality):
            draft = try compressImage(items, quality: quality)
        case .zip(let name):
            draft = try zip(items, name: name)
        case .unzip:
            draft = try unzip(items)
        case .rename(let rule):
            draft = try rename(items, rule: rule)
        case .mergePDFs(let name):
            draft = try mergePDFs(items, name: name)
        }

        if command.trashOriginals, !draft.sources.isEmpty {
            draft.steps.append(.trash(draft.sources))
            draft.effects += draft.sources.map { PlinthEffect(kind: .trash, url: $0) }
        }

        let missing: [PlinthTool] = command.action.needsFFmpeg && tools.ffmpeg == nil ? [.ffmpeg] : []
        let count = draft.sources.count
        let what = draft.noun.map { " " + $0 } ?? ""
        return PlinthPlan(
            command: command,
            title: command.action.title + (count > 0 ? " · \(count)\(what)" : ""),
            steps: draft.steps,
            effects: draft.effects,
            skipped: draft.skipped,
            missingTools: missing
        )
    }

    /// A plan under construction.
    private struct Draft {
        var steps: [PlinthStep] = []
        var effects: [PlinthEffect] = []
        /// The selected items the action consumes.
        var sources: [URL] = []
        var skipped: [URL] = []
        /// "videos", for the title.
        var noun: String?
    }

    // MARK: Video

    private func convertVideo(_ items: [PlinthItem], to format: PlinthVideoFormat, maxHeight: Int?) throws -> Draft {
        let accepted: Set<PlinthFileKind> = format.isAudioOnly ? [.video, .audio] : [.video]
        let (chosen, skipped) = split(items, accepting: accepted)
        guard !chosen.isEmpty else {
            throw PlinthError.noApplicableItems(format.isAudioOnly
                ? "None of the selected items are videos or audio files."
                : "None of the selected items are videos.")
        }
        let height: Int? = try format.isAudioOnly ? nil : checkedHeight(maxHeight)

        var draft = Draft(skipped: skipped, noun: chosen.count == 1 ? "file" : "files")
        var reserved = Set<String>()
        for item in chosen {
            let source = item.url
            let sameExtension = source.pathExtension.lowercased() == format.fileExtension
            let suffix = height.map(PlinthResolution.label(for:)) ?? (sameExtension ? "converted" : nil)
            let output = outputURL(for: source, extension: format.fileExtension, suffix: suffix, reserved: &reserved)
            let arguments = Self.videoArguments(for: format, maxHeight: height)
            draft.steps.append(.run(ffmpeg(input: source, output: output, arguments: arguments)))
            draft.effects.append(PlinthEffect(kind: .create, url: output))
            draft.sources.append(source)
        }
        return draft
    }

    private func compressVideo(_ items: [PlinthItem], quality: PlinthQuality, maxHeight: Int?) throws -> Draft {
        let (chosen, skipped) = split(items, accepting: [.video])
        guard !chosen.isEmpty else { throw PlinthError.noApplicableItems("None of the selected items are videos.") }
        let height = try checkedHeight(maxHeight)

        var draft = Draft(skipped: skipped, noun: chosen.count == 1 ? "video" : "videos")
        var reserved = Set<String>()
        for item in chosen {
            let output = outputURL(for: item.url, extension: "mp4", suffix: "compressed", reserved: &reserved)
            let arguments = ["-vf", Self.scaleFilter(maxHeight: height),
                             "-c:v", "libx265", "-preset", "medium", "-crf", String(quality.videoCRF),
                             "-tag:v", "hvc1", "-pix_fmt", "yuv420p",
                             "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"]
            draft.steps.append(.run(ffmpeg(input: item.url, output: output, arguments: arguments)))
            draft.effects.append(PlinthEffect(kind: .create, url: output))
            draft.sources.append(item.url)
        }
        return draft
    }

    /// The encoder settings for each target, after `-i input`.
    static func videoArguments(for format: PlinthVideoFormat, maxHeight: Int?) -> [String] {
        let scale = scaleFilter(maxHeight: maxHeight)
        let h264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "160k"]
        switch format {
        case .mp4, .mov:
            return ["-vf", scale] + h264 + ["-movflags", "+faststart"]
        case .mkv:
            return ["-vf", scale] + h264
        case .webm:
            return ["-vf", scale, "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1",
                    "-c:a", "libopus", "-b:a", "128k"]
        case .gif:
            // A palette built from the clip itself, or GIF's 256 colours band badly.
            let size = maxHeight.map { "scale=-1:'min(\($0),ih)':flags=lanczos" }
                ?? "scale='min(720,iw)':-1:flags=lanczos"
            return ["-vf", "fps=12,\(size),split[a][b];[a]palettegen[p];[b][p]paletteuse",
                    "-loop", "0", "-an"]
        case .mp3:
            return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a:
            return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case .wav:
            return ["-vn", "-c:a", "pcm_s16le"]
        }
    }

    /// H.264 and HEVC in 4:2:0 need even dimensions, so both sides are
    /// rounded down to even. With a height, never scaled up past the source.
    static func scaleFilter(maxHeight: Int?) -> String {
        guard let maxHeight else { return "scale='trunc(iw/2)*2':'trunc(ih/2)*2'" }
        return "scale=-2:'trunc(min(\(maxHeight),ih)/2)*2'"
    }

    /// `file:` in front of each path tells ffmpeg the rest is a literal file
    /// name, so a name containing a colon is never read as a protocol.
    private func ffmpeg(input: URL, output: URL, arguments: [String]) -> PlinthProcess {
        PlinthProcess(
            executable: tools.ffmpeg ?? PlinthToolPaths.expectedFFmpeg,
            arguments: ["-hide_banner", "-nostdin", "-n", "-i", "file:" + input.path]
                + arguments
                + ["-progress", "pipe:1", "-nostats", "file:" + output.path],
            output: output,
            progressInput: input
        )
    }

    private func checkedHeight(_ height: Int?) throws -> Int? {
        guard let height else { return nil }
        guard PlinthLimits.videoHeight.contains(height) else {
            throw PlinthError.invalidValue("A video height has to be between "
                + "\(PlinthLimits.videoHeight.lowerBound) and \(PlinthLimits.videoHeight.upperBound) pixels.")
        }
        return height
    }

    // MARK: Pictures

    /// Extensions `sips` can write back as themselves.
    private static let sipsWritable: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "jp2", "psd"
    ]

    /// Spellings of the same format.
    private static func canonicalImageExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg": return "jpg"
        case "tif": return "tiff"
        case "heif": return "heic"
        default: return ext.lowercased()
        }
    }

    private func convertImage(_ items: [PlinthItem], to format: PlinthImageFormat) throws -> Draft {
        let (pictures, others) = split(items, accepting: [.image])
        let already = pictures.filter {
            Self.canonicalImageExtension($0.url.pathExtension) == format.fileExtension
        }
        let chosen = pictures.filter { item in !already.contains(item) }
        guard !chosen.isEmpty else {
            throw PlinthError.noApplicableItems(pictures.isEmpty
                ? "None of the selected items are pictures."
                : "Those are already \(format.label).")
        }

        var draft = Draft(skipped: others + already.map(\.url), noun: chosen.count == 1 ? "picture" : "pictures")
        var reserved = Set<String>()
        for item in chosen {
            let output = outputURL(for: item.url, extension: format.fileExtension, suffix: nil, reserved: &reserved)
            var arguments = ["-s", "format", format.sipsName]
            if format == .jpg || format == .heic { arguments += ["-s", "formatOptions", "85"] }
            arguments += [item.url.path, "--out", output.path]
            draft.steps.append(.run(PlinthProcess(executable: tools.sips, arguments: arguments, output: output)))
            draft.effects.append(PlinthEffect(kind: .create, url: output))
            draft.sources.append(item.url)
        }
        return draft
    }

    private func resizeImage(_ items: [PlinthItem], _ resize: PlinthResize) throws -> Draft {
        try PlinthLimits.check(resize)
        let (pictures, others) = split(items, accepting: [.image])
        guard !pictures.isEmpty else { throw PlinthError.noApplicableItems("None of the selected items are pictures.") }

        var draft = Draft(skipped: others, noun: pictures.count == 1 ? "picture" : "pictures")
        var reserved = Set<String>()
        for item in pictures {
            var sizeArguments: [String]
            switch resize {
            case .percent(let percent):
                // sips has no percentage, so the new size is worked out here.
                guard let size = probe.pixelSize(item.url) else {
                    draft.skipped.append(item.url)
                    continue
                }
                let width = max(1, Int((Double(size.width) * Double(percent) / 100).rounded()))
                let height = max(1, Int((Double(size.height) * Double(percent) / 100).rounded()))
                sizeArguments = ["-z", String(height), String(width)]
            case .longestSide(let pixels):
                sizeArguments = ["-Z", String(pixels)]
            case .width(let pixels):
                sizeArguments = ["--resampleWidth", String(pixels)]
            case .height(let pixels):
                sizeArguments = ["--resampleHeight", String(pixels)]
            }
            let ext = item.url.pathExtension.lowercased()
            let keepsFormat = Self.sipsWritable.contains(ext)
            if !keepsFormat { sizeArguments += ["-s", "format", "png"] }
            let output = outputURL(for: item.url, extension: keepsFormat ? ext : "png",
                                   suffix: resize.nameSuffix, reserved: &reserved)
            let arguments = sizeArguments + [item.url.path, "--out", output.path]
            draft.steps.append(.run(PlinthProcess(executable: tools.sips, arguments: arguments, output: output)))
            draft.effects.append(PlinthEffect(kind: .create, url: output))
            draft.sources.append(item.url)
        }
        guard !draft.sources.isEmpty else {
            throw PlinthError.noApplicableItems("Couldn't read the size of the selected pictures.")
        }
        return draft
    }

    private func compressImage(_ items: [PlinthItem], quality: PlinthQuality) throws -> Draft {
        let (pictures, others) = split(items, accepting: [.image])
        guard !pictures.isEmpty else { throw PlinthError.noApplicableItems("None of the selected items are pictures.") }

        var draft = Draft(skipped: others, noun: pictures.count == 1 ? "picture" : "pictures")
        var reserved = Set<String>()
        for item in pictures {
            let isHEIC = Self.canonicalImageExtension(item.url.pathExtension) == "heic"
            let format: PlinthImageFormat = isHEIC ? .heic : .jpg
            let output = outputURL(for: item.url, extension: format.fileExtension, suffix: "compressed",
                                   reserved: &reserved)
            let arguments = ["-s", "format", format.sipsName, "-s", "formatOptions", String(quality.imageQuality),
                             item.url.path, "--out", output.path]
            draft.steps.append(.run(PlinthProcess(executable: tools.sips, arguments: arguments, output: output)))
            draft.effects.append(PlinthEffect(kind: .create, url: output))
            draft.sources.append(item.url)
        }
        return draft
    }

    // MARK: Archives

    private func zip(_ items: [PlinthItem], name: String?) throws -> Draft {
        let parents = Set(items.map { $0.url.deletingLastPathComponent().standardizedFileURL.path })
        guard parents.count == 1, let parentPath = parents.first else {
            throw PlinthError.noApplicableItems("Zipping needs everything to be in the same folder.")
        }
        let parent = URL(fileURLWithPath: parentPath, isDirectory: true)
        let stem = try name.map { try PlinthNames.checkedBaseName($0, extension: "zip") }
            ?? (items.count == 1 ? items[0].url.lastPathComponent : "Archive")

        var reserved = Set<String>()
        let directory = probe.isWritableDirectory(parent) ? parent : fallbackDirectory
        let output = uniqueURL(in: directory, stem: stem, extension: "zip", reserved: &reserved)

        // Relative names, so the archive holds "Photos/…" rather than the
        // whole path from the root. "./" keeps a name starting with "-" from
        // being read as an option.
        let names = items.map { "./" + $0.url.lastPathComponent }
        let arguments = ["-r", "-y", "-q", "-X", output.path] + names + ["-x", "*.DS_Store", "__MACOSX/*"]
        var draft = Draft(noun: items.count == 1 ? "item" : "items")
        draft.steps = [.run(PlinthProcess(executable: tools.zip, arguments: arguments,
                                          workingDirectory: parent, output: output))]
        draft.effects = [PlinthEffect(kind: .create, url: output)]
        draft.sources = items.map(\.url)
        return draft
    }

    private func unzip(_ items: [PlinthItem]) throws -> Draft {
        let (archives, others) = split(items, accepting: [.zip])
        guard !archives.isEmpty else { throw PlinthError.noApplicableItems("None of the selected items are zip archives.") }

        var draft = Draft(skipped: others, noun: archives.count == 1 ? "archive" : "archives")
        var reserved = Set<String>()
        for item in archives {
            let parent = item.url.deletingLastPathComponent()
            let directory = probe.isWritableDirectory(parent) ? parent : fallbackDirectory
            let folder = uniqueURL(in: directory, stem: item.url.deletingPathExtension().lastPathComponent,
                                   extension: "", reserved: &reserved)
            // ditto, like Archive Utility: keeps resource forks, permissions
            // and quarantine flags, and never writes outside `folder`.
            let arguments = ["-x", "-k", item.url.path, folder.path]
            draft.steps.append(.run(PlinthProcess(executable: tools.ditto, arguments: arguments, output: folder)))
            draft.effects.append(PlinthEffect(kind: .create, url: folder))
            draft.sources.append(item.url)
        }
        return draft
    }

    // MARK: PDFs

    private func mergePDFs(_ items: [PlinthItem], name: String?) throws -> Draft {
        let (pdfs, others) = split(items, accepting: [.pdf])
        guard pdfs.count >= 2 else { throw PlinthError.noApplicableItems("Select at least two PDFs to merge.") }
        let ordered = pdfs.map(\.url).sorted(by: Self.nameOrder)
        let stem = try name.map { try PlinthNames.checkedBaseName($0, extension: "pdf") } ?? "Merged"

        let parent = ordered[0].deletingLastPathComponent()
        let directory = probe.isWritableDirectory(parent) ? parent : fallbackDirectory
        var reserved = Set<String>()
        let output = uniqueURL(in: directory, stem: stem, extension: "pdf", reserved: &reserved)

        var draft = Draft(skipped: others, noun: "PDFs")
        draft.steps = [.mergePDFs(inputs: ordered, output: output)]
        draft.effects = [PlinthEffect(kind: .create, url: output)]
        draft.sources = ordered
        return draft
    }

    // MARK: Renaming

    private func rename(_ items: [PlinthItem], rule: PlinthRenameRule) throws -> Draft {
        guard !rule.isEmpty else { throw PlinthError.nothingToChange }
        let ordered = items.map(\.url).sorted(by: Self.nameOrder)
        let folders = Set(items.filter { $0.kind == .folder }.map(\.url))

        var pairs: [PlinthRename] = []
        for (index, url) in ordered.enumerated() {
            let name = PlinthRenamer.newName(
                for: url, isFolder: folders.contains(url), index: index + 1, total: ordered.count, rule: rule,
                date: probe.creationDate(url), timeZone: timeZone
            )
            guard PlinthNames.isValidFileName(name) else {
                throw PlinthError.invalidValue("“\(name)” isn't a name a file can have.")
            }
            guard name != url.lastPathComponent else { continue }
            pairs.append(PlinthRename(from: url, to: url.deletingLastPathComponent().appendingPathComponent(name)))
        }
        guard !pairs.isEmpty else { throw PlinthError.nothingToChange }

        // macOS volumes are case-insensitive, so "a.jpg" and "A.jpg" clash.
        let sources = Set(ordered.map { $0.path.lowercased() })
        var targets = Set<String>()
        for pair in pairs {
            let key = pair.to.path.lowercased()
            guard targets.insert(key).inserted else {
                throw PlinthError.nameConflict("Two items would both be called “\(pair.to.lastPathComponent)”. "
                    + "Add {n} to number them.")
            }
            if probe.exists(pair.to), !sources.contains(key) {
                throw PlinthError.nameConflict("“\(pair.to.lastPathComponent)” already exists in that folder.")
            }
        }

        var draft = Draft(noun: pairs.count == 1 ? "item" : "items")
        draft.steps = [.rename(pairs)]
        draft.effects = pairs.map { PlinthEffect(kind: .rename(from: $0.from), url: $0.to) }
        draft.sources = pairs.map(\.from)
        return draft
    }

    // MARK: Shared

    private func split(_ items: [PlinthItem], accepting kinds: Set<PlinthFileKind>) -> ([PlinthItem], [URL]) {
        var chosen: [PlinthItem] = []
        var skipped: [URL] = []
        for item in items {
            if kinds.contains(item.kind) { chosen.append(item) } else { skipped.append(item.url) }
        }
        return (chosen, skipped)
    }

    /// Finder's own order: "2" before "10".
    static func nameOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    /// Beside the original — `clip.mov` becomes `clip.mp4` — or in the
    /// fallback folder when that one cannot be written to. Never an existing
    /// name, and never one another step of the same plan already took.
    private func outputURL(for source: URL, extension ext: String, suffix: String?,
                           reserved: inout Set<String>) -> URL {
        let parent = source.deletingLastPathComponent()
        let directory = probe.isWritableDirectory(parent) ? parent : fallbackDirectory
        let stem = source.deletingPathExtension().lastPathComponent + (suffix.map { " (\($0))" } ?? "")
        return uniqueURL(in: directory, stem: stem, extension: ext, reserved: &reserved)
    }

    private func uniqueURL(in directory: URL, stem: String, extension ext: String,
                           reserved: inout Set<String>) -> URL {
        func make(_ base: String) -> URL {
            ext.isEmpty
                ? directory.appendingPathComponent(base, isDirectory: true)
                : directory.appendingPathComponent(base + "." + ext, isDirectory: false)
        }
        var candidate = make(stem)
        var counter = 2
        while probe.exists(candidate) || reserved.contains(candidate.path.lowercased()) {
            candidate = make("\(stem) \(counter)")
            counter += 1
        }
        reserved.insert(candidate.path.lowercased())
        return candidate
    }
}

/// Bounds on every number a request can carry. The model's guesses are
/// checked against these before anything is built.
enum PlinthLimits {
    static let videoHeight = 144...4320
    static let percent = 1...400
    static let pixels = 16...16_384
    static let requestLength = 300
    static let nameLength = 120

    static func check(_ resize: PlinthResize) throws {
        switch resize {
        case .percent(let value):
            guard percent.contains(value) else {
                throw PlinthError.invalidValue("Resize between \(percent.lowerBound)% and \(percent.upperBound)%.")
            }
            guard value != 100 else { throw PlinthError.nothingToChange }
        case .longestSide(let value), .width(let value), .height(let value):
            guard pixels.contains(value) else {
                throw PlinthError.invalidValue("Pick a size between \(pixels.lowerBound) and \(pixels.upperBound) pixels.")
            }
        }
    }
}

/// File-name rules, shared by the builder and the request validator.
enum PlinthNames {
    /// A name Finder would accept and that stays visible: no slash or colon
    /// (Finder shows a colon as a slash), no control characters, not hidden,
    /// and within the 255-byte limit APFS sets.
    static func isValidFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."),
              name.utf8.count <= 255,
              name.trimmingCharacters(in: .whitespaces) == name
        else { return false }
        return !name.unicodeScalars.contains { scalar in
            scalar == "/" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar)
        }
    }

    /// A user- or model-supplied archive or document name, without its
    /// extension. Trailing ".zip" is dropped if given.
    static func checkedBaseName(_ raw: String, extension ext: String) throws -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix("." + ext) { name = String(name.dropLast(ext.count + 1)) }
        name = name.trimmingCharacters(in: .whitespaces)
        guard name.count <= PlinthLimits.nameLength, isValidFileName(name + "." + ext) else {
            throw PlinthError.invalidValue("“\(raw)” can't be used as a file name.")
        }
        return name
    }
}

/// Works out one new name from a `PlinthRenameRule`.
enum PlinthRenamer {
    static func newName(for url: URL, isFolder: Bool, index: Int, total: Int, rule: PlinthRenameRule,
                        date: Date?, timeZone: TimeZone) -> String {
        let full = url.lastPathComponent
        // A folder's "extension" is part of its name: "Report v1.2" stays whole.
        let ext = isFolder ? "" : url.pathExtension
        var stem = ext.isEmpty ? full : String(full.dropLast(ext.count + 1))

        if let find = rule.find, !find.isEmpty {
            stem = stem.replacingOccurrences(of: find, with: rule.replace ?? "", options: .caseInsensitive)
        }
        switch rule.letterCase {
        case .lower: stem = stem.lowercased()
        case .upper: stem = stem.uppercased()
        case .title: stem = stem.capitalized
        case nil: break
        }
        if let template = rule.template, !template.isEmpty {
            let width = max(2, String(total).count)
            let number = String(index)
            let padded = String(repeating: "0", count: max(0, width - number.count)) + number
            stem = template
                .replacingOccurrences(of: "{name}", with: stem)
                .replacingOccurrences(of: "{n}", with: padded)
                .replacingOccurrences(of: "{date}", with: date.map { dateText($0, timeZone: timeZone) } ?? "")
        }
        stem = (rule.prefix ?? "") + stem + (rule.suffix ?? "")
        stem = stem.trimmingCharacters(in: .whitespaces)
        return ext.isEmpty ? stem : stem + "." + ext
    }

    private static func dateText(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
