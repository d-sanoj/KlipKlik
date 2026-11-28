import AVFoundation
import Foundation
import ImageIO
import PDFKit

/// Carries out a `PlinthPlan`, one step after another, off the main thread.
///
/// It runs exactly the steps the user saw in the preview and nothing else. A
/// step that fails stops the plan: its own half-written output is removed,
/// earlier steps' results are kept, and the error says how far it got.
final class PlinthRunner {
    struct Failure: Error {
        let message: String
        /// What was finished before the failure.
        let completed: [URL]
    }

    typealias Progress = (Double?) -> Void

    private let queue = DispatchQueue(label: "com.sanoj.KlipKlik.plinth.runner", qos: .userInitiated)
    private let lock = NSLock()
    private var currentProcess: Process?
    private var isCancelled = false

    /// A GUI app inherits launchd's bare PATH; ffmpeg's own helpers and
    /// Homebrew's prefix need to be on it.
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Both callbacks arrive on the main queue.
    func run(_ plan: PlinthPlan, progress: @escaping Progress,
             completion: @escaping (Result<[URL], Failure>) -> Void) {
        lock.withLock { isCancelled = false }
        queue.async { [self] in
            let result = execute(plan) { fraction in
                DispatchQueue.main.async { progress(fraction) }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Stops the running program; the plan then fails as cancelled.
    func cancel() {
        lock.withLock {
            isCancelled = true
            currentProcess?.terminate()
        }
    }

    private func execute(_ plan: PlinthPlan, progress: @escaping (Double?) -> Void) -> Result<[URL], Failure> {
        var outputs: [URL] = []
        let total = Double(max(plan.steps.count, 1))

        for (index, step) in plan.steps.enumerated() {
            if lock.withLock({ isCancelled }) {
                return .failure(Failure(message: "Cancelled.", completed: outputs))
            }
            let base = Double(index) / total
            progress(base)
            do {
                switch step {
                case .run(let process):
                    try runProcess(process) { fraction in progress(base + fraction / total) }
                    if let output = process.output { outputs.append(output) }
                case .mergePDFs(let inputs, let output):
                    try PlinthFileOperations.mergePDFs(inputs, into: output)
                    outputs.append(output)
                case .rename(let pairs):
                    try PlinthFileOperations.rename(pairs)
                    outputs += pairs.map(\.to)
                case .trash(let urls):
                    try PlinthFileOperations.trash(urls)
                }
            } catch let error as Failure {
                return .failure(Failure(message: error.message, completed: outputs))
            } catch {
                return .failure(Failure(message: error.localizedDescription, completed: outputs))
            }
        }
        progress(1)
        return .success(outputs)
    }

    private func runProcess(_ spec: PlinthProcess, progress: @escaping (Double) -> Void) throws {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: spec.executable.path) else {
            throw Failure(message: "\(spec.executable.lastPathComponent) isn't installed.", completed: [])
        }
        // Checked again here, not only when the plan was built: something
        // may have appeared there while the preview was open.
        if let output = spec.output, fileManager.fileExists(atPath: output.path) {
            throw Failure(message: "“\(output.lastPathComponent)” already exists, so nothing was overwritten.",
                          completed: [])
        }

        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        if let directory = spec.workingDirectory { process.currentDirectoryURL = directory }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.searchPath
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        // ffmpeg reports "out_time_us=…" on stdout a few times a second.
        let duration = spec.progressInput.map(Self.duration(of:)) ?? 0
        if duration > 0 {
            output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = String(decoding: handle.availableData, as: UTF8.self)
                for line in chunk.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                    guard let micros = Double(line.dropFirst("out_time_us=".count)) else { continue }
                    progress(min(1, max(0, micros / 1_000_000 / duration)))
                }
            }
        } else {
            output.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        }

        // Drained concurrently, or a chatty program fills the pipe and stalls.
        var errorData = Data()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }

        do {
            try lock.withLock {
                guard !isCancelled else { throw Failure(message: "Cancelled.", completed: []) }
                try process.run()
                currentProcess = process
            }
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            try? errors.fileHandleForWriting.close()
            throw error
        }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        drained.wait()
        lock.withLock { currentProcess = nil }

        guard process.terminationStatus == 0 else {
            if let partial = spec.output { try? fileManager.removeItem(at: partial) }
            if lock.withLock({ isCancelled }) { throw Failure(message: "Cancelled.", completed: []) }
            throw Failure(message: Self.reason(from: errorData, tool: spec.executable.lastPathComponent),
                          completed: [])
        }
    }

    /// The last meaningful line a program printed before giving up.
    static func reason(from data: Data, tool: String) -> String {
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return "\(tool) failed." }
        return "\(tool): \(last.prefix(200))"
    }

    /// The input's length, for ffmpeg's progress. 0 when AVFoundation cannot
    /// read it (WebM, MKV), which leaves the bar indeterminate.
    private static func duration(of url: URL) -> Double {
        let done = DispatchSemaphore(value: 0)
        var seconds = 0.0
        Task {
            seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }
}

/// The steps done in-process rather than by a program.
enum PlinthFileOperations {
    /// Two passes — every item to a temporary name, then each to its new one —
    /// so "a → b, b → a" works and a case-only change ("a.jpg" → "A.jpg") is
    /// not refused by a case-insensitive volume. Anything that fails part way
    /// is put back.
    static func rename(_ pairs: [PlinthRename]) throws {
        let fileManager = FileManager.default
        var staged: [(temporary: URL, pair: PlinthRename)] = []
        var finished = Set<Int>()
        do {
            for pair in pairs {
                let temporary = pair.from.deletingLastPathComponent()
                    .appendingPathComponent(".plinth-\(UUID().uuidString)")
                try fileManager.moveItem(at: pair.from, to: temporary)
                staged.append((temporary, pair))
            }
            for (index, entry) in staged.enumerated() {
                if fileManager.fileExists(atPath: entry.pair.to.path) {
                    throw PlinthRunner.Failure(
                        message: "“\(entry.pair.to.lastPathComponent)” appeared meanwhile. Nothing was renamed.",
                        completed: []
                    )
                }
                try fileManager.moveItem(at: entry.temporary, to: entry.pair.to)
                finished.insert(index)
            }
        } catch {
            for (index, entry) in staged.enumerated().reversed() {
                let current = finished.contains(index) ? entry.pair.to : entry.temporary
                try? fileManager.moveItem(at: current, to: entry.pair.from)
            }
            throw error
        }
    }

    /// To the Trash, where it can be put back — never deleted outright.
    static func trash(_ urls: [URL]) throws {
        for url in urls {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    static func mergePDFs(_ inputs: [URL], into output: URL) throws {
        let merged = PDFDocument()
        for url in inputs {
            guard let document = PDFDocument(url: url) else {
                throw PlinthRunner.Failure(message: "“\(url.lastPathComponent)” couldn't be opened as a PDF.",
                                           completed: [])
            }
            guard !document.isLocked else {
                throw PlinthRunner.Failure(message: "“\(url.lastPathComponent)” is password-protected.",
                                           completed: [])
            }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: merged.pageCount)
            }
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw PlinthRunner.Failure(message: "“\(output.lastPathComponent)” already exists.", completed: [])
        }
        guard merged.write(to: output) else {
            throw PlinthRunner.Failure(message: "Writing “\(output.lastPathComponent)” failed.", completed: [])
        }
    }
}

// MARK: - The real disk

extension PlinthFileProbe {
    static let live = PlinthFileProbe(
        exists: { FileManager.default.fileExists(atPath: $0.path) },
        isWritableDirectory: { FileManager.default.isWritableFile(atPath: $0.path) },
        pixelSize: { url in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int
            else { return nil }
            // EXIF orientations 5–8 are rotated a quarter turn; sips applies
            // the rotation, so the sides are swapped to match what it sees.
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            return orientation >= 5 ? (width: height, height: width) : (width: width, height: height)
        },
        creationDate: { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }
    )
}

extension PlinthItem {
    /// Reads whether each URL is a folder (packages count as folders).
    static func live(_ urls: [URL]) -> [PlinthItem] {
        urls.map { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return PlinthItem(url: url, isDirectory: isDirectory)
        }
    }
}

extension PlinthCommandBuilder {
    /// The builder against this Mac: real disk, Homebrew's ffmpeg if any,
    /// Downloads for folders that cannot be written to.
    static var live: PlinthCommandBuilder {
        PlinthCommandBuilder(
            tools: PlinthToolPaths(ffmpeg: FFmpeg.executable),
            probe: .live,
            fallbackDirectory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        )
    }
}
