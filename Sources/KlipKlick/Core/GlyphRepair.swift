import AppKit
import Vision

/// Puts back the glyphs Vision cannot read.
///
/// Apple's text recogniser has no ⌘ ⌥ ⇧ ⌃ in its vocabulary — they never appear
/// in the text corpora it learned from — so it emits the nearest Latin shape
/// instead: ⌘ becomes `H`, ⌥ becomes `T` or `I`, ⇧ becomes `&`, ¥ becomes `·`.
/// No setting fixes this, and no other OCR engine knows these glyphs either;
/// they are Apple-specific.
///
/// So the pixels get a second look. For a word that contains a suspect
/// character, every plausible correction is *rendered* and compared against the
/// actual pixels, and the closest render wins. The original reading competes on
/// equal terms, so a word that really did contain an `H` keeps it.
///
/// Matching is done a word at a time rather than a character at a time because
/// `VNRecognizedText.boundingBox(for:)` reports the same word-level box for
/// every character in that word — a per-character crop would contain several
/// glyphs and match nothing.
enum GlyphRepair {
    /// The glyphs worth restoring.
    private static let symbols = [
        "⌘", "⌥", "⇧", "⌃", "⏎", "⌫", "⇥", "⎋", "⇪",
        "←", "→", "↑", "↓",
        "£", "¥", "€", "₹", "¢",
        "·"
    ]

    /// Characters Vision emits where one of the above really was. This only
    /// marks a position as worth a second look — which symbol it becomes, or
    /// whether it changes at all, is decided by the pixels.
    private static let suspect: Set<Character> = [
        "H", "T", "I", "&", "^", "·", "•", "€"
    ]

    /// A correction has to beat the original reading by this much to be taken.
    /// Without it, noise could rewrite text that was already right.
    private static let margin = 0.06

    /// A correction is only taken when the render genuinely matches the pixels.
    /// Without this, small anti-aliased text matches nothing well and the
    /// "closest" template wins by noise, turning prose into symbols.
    private static let minimumConfidence = 0.86

    /// Words with more suspect characters than this are left alone — the
    /// candidate set grows as a power and stops being worth the time.
    private static let maxSuspectsPerWord = 2

    /// Ceiling on repairs per grab, so a pathological screen cannot stall it.
    private static let maxRepairs = 60

    private static let fonts: [NSFont] = [
        .systemFont(ofSize: 60),
        .monospacedSystemFont(ofSize: 60, weight: .regular)
    ]

    /// Grid resolution each glyph is normalised to before comparison.
    private static let gridSize = 32

    private static var renderCache: [String: [Double]] = [:]

    // MARK: Entry point

    /// Returns `candidate.string` with unreadable glyphs restored.
    static func repair(_ candidate: VNRecognizedText, in image: CGImage) -> String {
        let text = candidate.string
        guard text.contains(where: { suspect.contains($0) }) else { return text }

        var result = ""
        var repairs = 0
        var index = text.startIndex

        while index < text.endIndex {
            // Copy across everything up to the next word.
            guard let wordStart = text[index...].firstIndex(where: { !$0.isWhitespace }) else {
                result += text[index...]
                break
            }
            result += text[index..<wordStart]

            let wordEnd = text[wordStart...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            let word = String(text[wordStart..<wordEnd])

            if repairs < maxRepairs,
               word.contains(where: { suspect.contains($0) }),
               let fixed = repairedWord(word, range: wordStart..<wordEnd,
                                        candidate: candidate, image: image) {
                result += fixed
                if fixed != word { repairs += 1 }
            } else {
                result += word
            }

            index = wordEnd
        }

        return result
    }

    // MARK: Matching

    private static func repairedWord(
        _ word: String,
        range: Range<String.Index>,
        candidate: VNRecognizedText,
        image: CGImage
    ) -> String? {
        guard let observation = try? candidate.boundingBox(for: range) else { return nil }

        // Vision's normalised box is bottom-left origin; CGImage crops top-left.
        let box = observation.boundingBox
        let rect = CGRect(
            x: box.minX * CGFloat(image.width),
            y: (1 - box.maxY) * CGFloat(image.height),
            width: box.width * CGFloat(image.width),
            height: box.height * CGFloat(image.height)
        ).integral

        guard let target = grid(of: image, in: rect) else { return nil }

        var bestScore = -Double.infinity
        var bestWord = word
        var originalScore = -Double.infinity

        for option in candidates(for: word) {
            var optionBest = -Double.infinity
            for (i, font) in fonts.enumerated() {
                guard let rendered = renderedGrid(option, font: font, key: "f\(i)") else { continue }
                optionBest = max(optionBest, similarity(target, rendered))
            }
            if option == word { originalScore = optionBest }
            if optionBest > bestScore {
                bestScore = optionBest
                bestWord = option
            }
        }

        // Keep the original unless a correction is clearly closer to the pixels.
        guard bestWord != word,
              bestScore >= minimumConfidence,
              bestScore > originalScore + margin else { return word }
        return bestWord
    }

    /// Every reading obtainable by treating suspect positions as symbols.
    ///
    /// Covers two shapes of mistake. One character standing in for a symbol
    /// (`H` for ⌘), and *two* standing in for one — Vision reads a single ⌘ as
    /// `M&` or `J€` often enough that ignoring it leaves half the shortcuts on
    /// a page unrepaired.
    private static func candidates(for word: String) -> [String] {
        let characters = Array(word)
        let spots = characters.indices.filter { suspect.contains(characters[$0]) }
        guard !spots.isEmpty, spots.count <= maxSuspectsPerWord else { return [word] }

        var options: Set<String> = [word]

        // One character becomes one symbol.
        for spot in spots {
            var grown = options
            for base in options {
                var scratch = Array(base)
                guard spot < scratch.count else { continue }
                for symbol in symbols {
                    scratch[spot] = Character(symbol)
                    grown.insert(String(scratch))
                }
            }
            options = grown
        }

        // Two adjacent characters collapse into one symbol, where at least one
        // of the pair looked suspect to begin with.
        for spot in characters.indices.dropLast() where
            suspect.contains(characters[spot]) || suspect.contains(characters[spot + 1]) {
            for symbol in symbols {
                var scratch = characters
                scratch.replaceSubrange(spot...(spot + 1), with: [Character(symbol)])
                options.insert(String(scratch))
            }
        }

        return Array(options)
    }

    // MARK: Bitmaps

    /// Ink-trimmed, contrast-normalised, fixed-size grid. Trimming to the ink is
    /// what makes the comparison independent of font size and padding.
    private static func grid(of image: CGImage, in rect: CGRect) -> [Double]? {
        guard let crop = image.cropping(to: rect), crop.width > 3, crop.height > 3 else { return nil }
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))

        let low = Double(pixels.min() ?? 0), high = Double(pixels.max() ?? 255)
        guard high - low > 20 else { return nil }   // blank patch, nothing to match
        let threshold = (low + high) / 2

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where Double(pixels[y * width + x]) < threshold {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let inkWidth = maxX - minX + 1, inkHeight = maxY - minY + 1
        var out = [Double](repeating: 0, count: gridSize * gridSize)
        for gy in 0..<gridSize {
            for gx in 0..<gridSize {
                let sx = min(minX + gx * inkWidth / gridSize, width - 1)
                let sy = min(minY + gy * inkHeight / gridSize, height - 1)
                out[gy * gridSize + gx] = (high - Double(pixels[sy * width + sx])) / max(high - low, 1)
            }
        }
        return out
    }

    private static func renderedGrid(_ text: String, font: NSFont, key: String) -> [Double]? {
        let cacheKey = key + "|" + text
        if let cached = renderCache[cacheKey] { return cached }

        let string = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.black]
        )
        let size = string.size()
        let width = Int(size.width.rounded(.up)) + 20
        let height = Int(size.height.rounded(.up)) + 20
        guard width > 6, height > 6 else { return nil }

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        string.draw(at: NSPoint(x: 10, y: 10))
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage(),
              let result = grid(of: image, in: CGRect(x: 0, y: 0, width: width, height: height))
        else { return nil }

        renderCache[cacheKey] = result
        return result
    }

    /// 1 is identical; lower is further apart.
    private static func similarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return -.infinity }
        var sum = 0.0
        for i in 0..<a.count {
            let d = a[i] - b[i]
            sum += d * d
        }
        return 1.0 - sum / Double(a.count)
    }
}
