import AVFoundation
import Combine
import ImageIO
import UniformTypeIdentifiers

/// Converts pictures, videos and audio between formats, and resizes or
/// compresses them.
///
/// Apple's own engines do everything they can — ImageIO for pictures,
/// AVFoundation for video and audio — so the common formats need nothing
/// installed. When Homebrew's `ffmpeg` is on the Mac it widens the list to the
/// formats Apple does not write (WebM, MKV, AVI, animated GIF, MP3, FLAC…) and
/// reads the ones AVFoundation cannot open.
enum MediaConverter {
    enum Kind {
        case image, video, audio
    }

    /// One thing a file can be turned into.
    struct Format: Hashable, Identifiable {
        enum Engine: Hashable {
            case image(type: String)
            case video(preset: String, fileType: String)
            case ffmpeg(arguments: [String])
        }

        let title: String
        let fileExtension: String
        let engine: Engine

        var id: String { title + "." + fileExtension }
    }

    static func kind(of url: URL) -> Kind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || (type.conforms(to: .audiovisualContent) && !type.conforms(to: .audio)) {
            return .video
        }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }

    // MARK: What a file can become

    static func formats(for url: URL) -> [Format] {
        let ext = url.pathExtension.lowercased()
        let all: [Format]
        switch kind(of: url) {
        case .image: all = imageFormats(sourceIsGIF: ext == "gif")
        case .video: all = videoFormats
        case .audio: all = audioFormats
        case nil: all = []
        }
        // Converting to the same format does nothing useful.
        return all.filter { $0.fileExtension != ext || $0.title.contains("HEVC") || $0.title.contains("ProRes") }
    }

    private static func imageFormats(sourceIsGIF: Bool) -> [Format] {
        let writable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        let native: [(String, String, String)] = [
            ("PNG", "png", UTType.png.identifier),
            ("JPEG", "jpg", UTType.jpeg.identifier),
            ("HEIC", "heic", UTType.heic.identifier),
            ("AVIF", "avif", "public.avif"),
            ("TIFF", "tiff", UTType.tiff.identifier),
            ("GIF", "gif", UTType.gif.identifier),
            ("BMP", "bmp", UTType.bmp.identifier),
            ("JPEG 2000", "jp2", "public.jpeg-2000"),
            ("PDF", "pdf", UTType.pdf.identifier),
            ("Photoshop (PSD)", "psd", "com.adobe.photoshop-image"),
            ("TGA", "tga", "com.truevision.tga-image"),
            ("Icon (ICO)", "ico", UTType.ico.identifier),
            ("macOS Icon (ICNS)", "icns", UTType.icns.identifier)
        ]
        var formats = native
            .filter { writable.contains($0.2) }
            .map { Format(title: $0.0, fileExtension: $0.1, engine: .image(type: $0.2)) }

        if !writable.contains("org.webmproject.webp"), FFmpeg.hasEncoder("libwebp") {
            formats.insert(Format(title: "WebP", fileExtension: "webp",
                                  engine: .ffmpeg(arguments: ["-c:v", "libwebp", "-quality", "85"])), at: 2)
        } else if writable.contains("org.webmproject.webp") {
            formats.insert(Format(title: "WebP", fileExtension: "webp",
                                  engine: .image(type: "org.webmproject.webp")), at: 2)
        }
        // An animated GIF is a video in all but name.
        if sourceIsGIF, FFmpeg.isInstalled {
            formats.append(Format(title: "MP4 Video", fileExtension: "mp4", engine: .ffmpeg(arguments: [
                "-movflags", "+faststart", "-pix_fmt", "yuv420p",
                "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:v", "libx264"
            ])))
        }
        return formats
    }

    private static var videoFormats: [Format] {
        var formats = [
            Format(title: "MP4 (H.264)", fileExtension: "mp4",
                   engine: .video(preset: AVAssetExportPresetHighestQuality, fileType: AVFileType.mp4.rawValue)),
            Format(title: "MOV (HEVC)", fileExtension: "mov",
                   engine: .video(preset: AVAssetExportPresetHEVCHighestQuality, fileType: AVFileType.mov.rawValue)),
            Format(title: "M4V", fileExtension: "m4v",
                   engine: .video(preset: AVAssetExportPresetHighestQuality, fileType: AVFileType.m4v.rawValue)),
            Format(title: "MOV (ProRes 422)", fileExtension: "mov",
                   engine: .video(preset: AVAssetExportPresetAppleProRes422LPCM, fileType: AVFileType.mov.rawValue)),
            Format(title: "M4A (audio only)", fileExtension: "m4a",
                   engine: .video(preset: AVAssetExportPresetAppleM4A, fileType: AVFileType.m4a.rawValue))
        ]
        guard FFmpeg.isInstalled else { return formats }
        formats += [
            Format(title: "WebM (VP9)", fileExtension: "webm", engine: .ffmpeg(arguments: [
                "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus"
            ])),
            Format(title: "MKV", fileExtension: "mkv", engine: .ffmpeg(arguments: [
                "-c:v", "libx264", "-crf", "20", "-c:a", "aac"
            ])),
            Format(title: "AVI", fileExtension: "avi", engine: .ffmpeg(arguments: [
                "-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame"
            ])),
            Format(title: "Animated GIF", fileExtension: "gif", engine: .ffmpeg(arguments: [
                "-vf", "fps=12,scale='min(720,iw)':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                "-loop", "0"
            ])),
            Format(title: "MP3 (audio only)", fileExtension: "mp3", engine: .ffmpeg(arguments: [
                "-vn", "-c:a", "libmp3lame", "-q:a", "2"
            ]))
        ]
        return formats
    }

    private static var audioFormats: [Format] {
        var formats = [
            Format(title: "M4A (AAC)", fileExtension: "m4a",
                   engine: .video(preset: AVAssetExportPresetAppleM4A, fileType: AVFileType.m4a.rawValue))
        ]
        guard FFmpeg.isInstalled else { return formats }
        formats += [
            Format(title: "MP3", fileExtension: "mp3", engine: .ffmpeg(arguments: ["-vn", "-c:a", "libmp3lame", "-q:a", "2"])),
            Format(title: "WAV", fileExtension: "wav", engine: .ffmpeg(arguments: ["-vn", "-c:a", "pcm_s16le"])),
            Format(title: "FLAC", fileExtension: "flac", engine: .ffmpeg(arguments: ["-vn", "-c:a", "flac"])),
            Format(title: "OGG (Opus)", fileExtension: "ogg", engine: .ffmpeg(arguments: ["-vn", "-c:a", "libopus"]))
        ]
        return formats
    }

    // MARK: Doing it

    typealias Progress = (Double?) -> Void
    typealias Completion = (Result<URL, ConversionError>) -> Void

    struct ConversionError: Error {
        let message: String
    }

    /// Converts `source` into `format`, next to the original when that folder
    /// can be written to, otherwise into Downloads. Runs off the main thread;
    /// both callbacks come back on it.
    static func convert(_ source: URL, to format: Format, progress: @escaping Progress,
                        completion: @escaping Completion) {
        // Same container, new codec (MOV to HEVC MOV): say so in the name.
        let sameExtension = format.fileExtension == source.pathExtension.lowercased()
        let suffix = sameExtension
            ? (format.title.contains("ProRes") ? "ProRes" : format.title.contains("HEVC") ? "HEVC" : "converted")
            : nil
        let destination = outputURL(for: source, extension: format.fileExtension, suffix: suffix)
        switch format.engine {
        case .image(let type):
            runImage(completion: completion) {
                try writeImage(from: source, to: destination, type: type, maxPixel: nil, quality: nil)
            }
        case .video(let preset, let fileType):
            exportVideo(source, to: destination, preset: preset, fileType: AVFileType(fileType),
                        progress: progress, completion: completion)
        case .ffmpeg(let arguments):
            FFmpeg.run(input: source, output: destination, arguments: arguments,
                       progress: progress, completion: completion)
        }
    }

    /// A smaller copy of a picture, its longest side at most `maxPixel`.
    static func resize(_ source: URL, maxPixel: Int, completion: @escaping Completion) {
        let ext = source.pathExtension.lowercased()
        let destination = outputURL(for: source, extension: ext, suffix: "\(maxPixel)px")
        let type = UTType(filenameExtension: ext)?.identifier ?? UTType.png.identifier
        runImage(completion: completion) {
            try writeImage(from: source, to: destination, type: type, maxPixel: maxPixel, quality: nil)
        }
    }

    /// A lighter copy: pictures re-encoded at lower quality (as JPEG unless
    /// already HEIC), videos re-encoded as HEVC at up to 1080p.
    static func compress(_ source: URL, progress: @escaping Progress, completion: @escaping Completion) {
        switch kind(of: source) {
        case .image:
            let keepHEIC = source.pathExtension.lowercased() == "heic"
            let ext = keepHEIC ? "heic" : "jpg"
            let destination = outputURL(for: source, extension: ext, suffix: "compressed")
            runImage(completion: completion) {
                try writeImage(from: source, to: destination,
                               type: keepHEIC ? UTType.heic.identifier : UTType.jpeg.identifier,
                               maxPixel: nil, quality: 0.6)
            }
        case .video:
            let destination = outputURL(for: source, extension: "mp4", suffix: "compressed")
            exportVideo(source, to: destination, preset: AVAssetExportPresetHEVC1920x1080, fileType: .mp4,
                        progress: progress, completion: completion)
        default:
            completion(.failure(ConversionError(message: "Only pictures and videos can be compressed.")))
        }
    }

    // MARK: Engines

    private static func runImage(completion: @escaping Completion, _ work: @escaping () throws -> URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<URL, ConversionError>
            do {
                result = .success(try work())
            } catch let error as ConversionError {
                result = .failure(error)
            } catch {
                result = .failure(ConversionError(message: error.localizedDescription))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Decodes with ImageIO and writes `type`, optionally scaled down and at a
    /// given quality. Orientation is applied, so a rotated phone photo stays
    /// upright in formats that do not carry the orientation flag.
    private static func writeImage(from source: URL, to destination: URL, type: String,
                                   maxPixel: Int?, quality: Double?) throws -> URL {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ConversionError(message: "That picture could not be read.")
        }
        var image: CGImage?
        if let maxPixel {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(input, 0, nil)
        }
        guard let image else { throw ConversionError(message: "That picture could not be decoded.") }

        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, type as CFString, 1, nil) else {
            throw ConversionError(message: "This Mac cannot write that format.")
        }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        // Keep the original's metadata, minus the orientation already applied.
        if maxPixel == nil,
           let metadata = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any] {
            for (key, value) in metadata where key != kCGImagePropertyOrientation {
                properties[key] = value
            }
        }
        CGImageDestinationAddImage(output, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            try? FileManager.default.removeItem(at: destination)
            throw ConversionError(message: "Writing the new picture failed.")
        }
        return destination
    }

    private static func exportVideo(_ source: URL, to destination: URL, preset: String, fileType: AVFileType,
                                    progress: @escaping Progress, completion: @escaping Completion) {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            // AVFoundation cannot read it (WebM, MKV…): ffmpeg can, if it is here.
            if FFmpeg.isInstalled {
                FFmpeg.run(input: source, output: destination, arguments: FFmpeg.fallbackArguments(for: fileType),
                           progress: progress, completion: completion)
            } else {
                completion(.failure(ConversionError(
                    message: "macOS cannot read this video. Installing ffmpeg (brew install ffmpeg) adds support."
                )))
            }
            return
        }
        session.outputURL = destination
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true

        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in progress(Double(session.progress)) }
        RunLoop.main.add(timer, forMode: .common)

        session.exportAsynchronously {
            DispatchQueue.main.async {
                timer.invalidate()
                switch session.status {
                case .completed:
                    completion(.success(destination))
                default:
                    try? FileManager.default.removeItem(at: destination)
                    let message = session.error?.localizedDescription ?? "The export did not finish."
                    if FFmpeg.isInstalled, session.status == .failed {
                        // The file may use a codec AVFoundation will not
                        // re-encode; ffmpeg gets a second go at it.
                        FFmpeg.run(input: source, output: destination,
                                   arguments: FFmpeg.fallbackArguments(for: fileType),
                                   progress: progress, completion: completion)
                    } else {
                        completion(.failure(ConversionError(message: message)))
                    }
                }
            }
        }
    }

    // MARK: Where results go

    /// Beside the original — `clip.mp4` becomes `clip.webm` — or in Downloads
    /// when the original's folder cannot be written to or is the shelf's own
    /// staging area. Never overwrites: a taken name gets a number.
    static func outputURL(for source: URL, extension ext: String, suffix: String?) -> URL {
        let folder = source.deletingLastPathComponent()
        let useFolder = !ShelfStorage.isStaged(source)
            && FileManager.default.isWritableFile(atPath: folder.path)
        let directory = useFolder
            ? folder
            : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

        let stem = source.deletingPathExtension().lastPathComponent + (suffix.map { " (\($0))" } ?? "")
        var candidate = directory.appendingPathComponent(stem).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) || candidate == source {
            candidate = directory.appendingPathComponent("\(stem) \(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }
}

/// Homebrew's ffmpeg, when it is installed.
enum FFmpeg {
    static var executable: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isInstalled: Bool { executable != nil }

    private static var encoderList: String?

    /// Whether this ffmpeg build carries an encoder — Homebrew's builds differ.
    static func hasEncoder(_ name: String) -> Bool {
        guard let executable else { return false }
        if encoderList == nil {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-hide_banner", "-encoders"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            encoderList = String(data: data, encoding: .utf8) ?? ""
        }
        return encoderList?.contains(" \(name) ") ?? false
    }

    /// The input's length in seconds, or 0 when AVFoundation cannot read it.
    /// Blocks: only ever called off the main thread.
    private static func mediaDuration(_ url: URL) -> Double {
        let done = DispatchSemaphore(value: 0)
        var seconds = 0.0
        Task {
            seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            done.signal()
        }
        done.wait()
        return seconds
    }

    /// Settings for a container when AVFoundation could not do the job.
    static func fallbackArguments(for fileType: AVFileType) -> [String] {
        switch fileType {
        case .m4a: return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case .mov: return ["-c:v", "libx265", "-tag:v", "hvc1", "-c:a", "aac"]
        default: return ["-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac",
                         "-movflags", "+faststart"]
        }
    }

    /// Runs one conversion, reporting progress from ffmpeg's own progress
    /// stream against the input's duration.
    static func run(input: URL, output: URL, arguments: [String],
                    progress: @escaping MediaConverter.Progress,
                    completion: @escaping MediaConverter.Completion) {
        guard let executable else {
            completion(.failure(.init(message: "ffmpeg is not installed. Install it with brew install ffmpeg.")))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let duration = mediaDuration(input)
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-hide_banner", "-nostdin", "-y", "-i", input.path] + arguments
                + ["-progress", "pipe:1", "-nostats", output.path]
            let out = Pipe()
            let errors = Pipe()
            process.standardOutput = out
            process.standardError = errors

            var errorText = ""
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                group.leave()
            }

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(.failure(.init(message: error.localizedDescription))) }
                return
            }

            // "out_time_us=12345678" lines, a few times a second.
            out.fileHandleForReading.readabilityHandler = { handle in
                let chunk = String(data: handle.availableData, encoding: .utf8) ?? ""
                for line in chunk.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                    guard duration.isFinite, duration > 0,
                          let micros = Double(line.dropFirst("out_time_us=".count))
                    else { continue }
                    let fraction = min(1, max(0, micros / 1_000_000 / duration))
                    DispatchQueue.main.async { progress(fraction) }
                }
            }

            process.waitUntilExit()
            out.fileHandleForReading.readabilityHandler = nil
            group.wait()

            let succeeded = process.terminationStatus == 0
            if !succeeded { try? FileManager.default.removeItem(at: output) }
            let reason = errorText.split(separator: "\n").last.map(String.init) ?? "ffmpeg failed."
            DispatchQueue.main.async {
                completion(succeeded ? .success(output) : .failure(.init(message: reason)))
            }
        }
    }
}

/// The conversions in flight, for the little progress panel.
final class ConversionCenter: ObservableObject {
    static let shared = ConversionCenter()

    struct Job: Identifiable {
        enum State {
            case running(Double?)
            case done(URL)
            case failed(String)
        }

        let id = UUID()
        let title: String
        var state: State
    }

    @Published private(set) var jobs: [Job] = []

    private init() {}

    /// Starts `work`, tracking it in the panel. `onSuccess` gets the new file.
    func run(_ title: String,
             onSuccess: @escaping (URL) -> Void,
             work: (@escaping MediaConverter.Progress, @escaping MediaConverter.Completion) -> Void) {
        let job = Job(title: title, state: .running(nil))
        jobs.append(job)
        ConversionPanel.shared.showIfNeeded()

        work({ [weak self] fraction in
            self?.update(job.id) { $0.state = .running(fraction) }
        }, { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                update(job.id) { $0.state = .done(url) }
                onSuccess(url)
                removeLater(job.id, after: 6)
            case .failure(let error):
                update(job.id) { $0.state = .failed(error.message) }
                removeLater(job.id, after: 12)
            }
        })
    }

    func dismiss(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        if jobs.isEmpty { ConversionPanel.shared.hide() }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private func removeLater(_ id: UUID, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.dismiss(id) }
    }
}
