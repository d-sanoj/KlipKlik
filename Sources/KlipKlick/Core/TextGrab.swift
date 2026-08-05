import AppKit
import ScreenCaptureKit
import Vision

/// Grabs a region of the screen, reads the text out of it, and copies that —
/// the text, not the picture.
enum TextGrab {
    enum Failure: Error {
        case needsPermission
        case captureFailed
        case noTextFound
    }

    /// Whether macOS will let us read the screen.
    ///
    /// Reading screen pixels is exactly what Screen Recording gates, and there
    /// is no way around it: shelling out to `/usr/sbin/screencapture` does not
    /// help, because TCC attributes the capture to the app that spawned it.
    static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    private static let askedKey = "didAskForScreenRecording"

    /// Asks macOS to prompt, but only the first time.
    ///
    /// Returns true when the system dialog has just been put up, so the caller
    /// can stay quiet and let it do the talking. After that first ask macOS
    /// never prompts again — it just returns false — and an app that stays
    /// silent then looks broken, so the caller explains it instead.
    static func promptIfNeverAsked() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: askedKey) else { return false }
        defaults.set(true, forKey: askedKey)
        // Also registers the app in the Screen Recording list, so it can be
        // switched on by hand even if this prompt is dismissed.
        return !CGRequestScreenCaptureAccess()
    }

    static func openSettingsPane() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )!
        NSWorkspace.shared.open(url)
    }

    /// Captures `rect` (Core Graphics screen coordinates) and copies whatever
    /// text Vision finds. `completion` runs on the main thread.
    static func grab(rect: CGRect, completion: @escaping (Result<String, Failure>) -> Void) {
        Task {
            func finish(_ result: Result<String, Failure>) {
                DispatchQueue.main.async { completion(result) }
            }

            let image: CGImage
            do {
                image = try await capture(rect)
            } catch {
                finish(.failure(isPermitted ? .captureFailed : .needsPermission))
                return
            }

            guard let text = recognizeText(in: image), !text.isEmpty else {
                finish(.failure(.noTextFound))
                return
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            // Left for ClipboardMonitor to pick up, so a grab lands in history
            // like any other copy.
            finish(.success(text))
        }
    }

    /// ScreenCaptureKit rather than a `screencapture` subprocess: same
    /// permission either way, but this keeps the pixels in-process and lets the
    /// capture be scaled to the display's real backing resolution, which is
    /// what makes small text legible to the recogniser.
    private static func capture(_ rect: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        // The display the selection sits on, falling back to the first.
        guard let display = content.displays.first(where: { $0.frame.intersects(rect) })
                ?? content.displays.first
        else { throw Failure.captureFailed }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // sourceRect is relative to the display's own top-left corner.
        config.sourceRect = CGRect(
            x: rect.minX - display.frame.minX,
            y: rect.minY - display.frame.minY,
            width: rect.width,
            height: rect.height
        )
        let scale = backingScale(for: display)
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.captureResolution = .best
        config.showsCursor = false

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )
    }

    private static func backingScale(for display: SCDisplay) -> CGFloat {
        NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                == display.displayID
        }?.backingScaleFactor ?? 2
    }

    private static func recognizeText(in image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Off on purpose. Language correction is tuned for prose and rewrites
        // anything that isn't a word — identifiers, flags, hex, punctuation
        // runs — which is precisely what you grab a screen of code for.
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else { return nil }
        return layOut(observations)
    }

    /// Rebuilds the page layout from where the words sat.
    ///
    /// Vision reports a bag of text fragments with bounding boxes and no order,
    /// so joining the strings gives you the words and throws away the shape:
    /// indentation, column alignment and blank lines all collapse. Measuring the
    /// gaps against a typical character width puts them back, which is the
    /// difference between grabbing code you can paste and code you have to
    /// re-indent by hand.
    private static func layOut(_ observations: [VNRecognizedTextObservation]) -> String {
        struct Fragment {
            let text: String
            let box: CGRect
        }

        let fragments: [Fragment] = observations.compactMap {
            guard let best = $0.topCandidates(1).first else { return nil }
            return Fragment(text: best.string, box: $0.boundingBox)
        }
        guard !fragments.isEmpty else { return "" }

        // One character's width, in the same normalised units as the boxes.
        // Median over the longer fragments, so a stray glyph can't skew it.
        let widths = fragments
            .filter { $0.text.count >= 3 }
            .map { $0.box.width / CGFloat($0.text.count) }
            .sorted()
        let charWidth = widths.isEmpty
            ? fragments[0].box.width / CGFloat(max(fragments[0].text.count, 1))
            : widths[widths.count / 2]
        guard charWidth > 0 else {
            return fragments.map(\.text).joined(separator: "\n")
        }

        // Group fragments sharing a baseline into rows. Normalised y runs
        // bottom-up, so reading order is descending.
        var rows: [[Fragment]] = []
        for fragment in fragments.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let anchor = rows.last?.first,
               abs(anchor.box.midY - fragment.box.midY) < anchor.box.height * 0.5 {
                rows[rows.count - 1].append(fragment)
            } else {
                rows.append([fragment])
            }
        }

        let leftEdge = fragments.map(\.box.minX).min() ?? 0
        let midYs = rows.map { $0[0].box.midY }
        let pitch = medianPitch(of: midYs)

        var lines: [String] = []
        for (index, row) in rows.enumerated() {
            // A gap of more than one line means blank lines were there.
            if index > 0, pitch > 0 {
                let blanks = Int(((midYs[index - 1] - midYs[index]) / pitch).rounded()) - 1
                lines.append(contentsOf: Array(repeating: "", count: min(max(blanks, 0), 3)))
            }

            let ordered = row.sorted { $0.box.minX < $1.box.minX }
            var line = String(repeating: " ", count: spaces(from: leftEdge, to: ordered[0].box.minX, charWidth))
            var previous: CGRect?

            for fragment in ordered {
                if let previous {
                    // At least one space: two fragments on a line were separated
                    // by something, even if the gap rounds to nothing.
                    let count = max(1, spaces(from: previous.maxX, to: fragment.box.minX, charWidth))
                    line += String(repeating: " ", count: count)
                }
                line += fragment.text
                previous = fragment.box
            }

            while line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }

    /// Gap between two x positions, in characters. Capped so a wide selection
    /// with one far-right fragment can't emit a line of hundreds of spaces.
    private static func spaces(from: CGFloat, to: CGFloat, _ charWidth: CGFloat) -> Int {
        min(max(Int(((to - from) / charWidth).rounded()), 0), 60)
    }

    private static func medianPitch(of midYs: [CGFloat]) -> CGFloat {
        guard midYs.count > 1 else { return 0 }
        let gaps = zip(midYs, midYs.dropFirst()).map { $0 - $1 }.sorted()
        return gaps[gaps.count / 2]
    }
}
