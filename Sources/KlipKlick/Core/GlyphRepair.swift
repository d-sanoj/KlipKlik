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
/// So the pixels get a second look. `boundingBox(for:)` reports the same
/// word-level box for every character in a word, so a per-character crop is not
/// available from Vision. Instead the word's own pixels are split into glyphs
/// here — by the gaps between them, or by even pitch for monospaced text — and
/// each glyph is matched against a bank of rendered templates.
///
/// Two things make the match reliable enough to act on:
///
/// * **Hole counting.** ⌘ encloses several regions and `H` encloses none, so a
///   flood fill separates them before any pixel comparison happens.
/// * **The bank contains ordinary characters too.** A glyph that really is an
///   `H` matches the `H` template and nothing changes. Only a confident symbol
///   win rewrites anything.
enum GlyphRepair {
    // MARK: Tuning

    /// The glyphs worth restoring.
    private static let symbols = [
        "⌘", "⌥", "⇧", "⌃", "⏎", "⌫", "⇥", "⎋", "⇪",
        "←", "→", "↑", "↓",
        "£", "¥", "€", "₹", "¢"
    ]

    /// Ordinary characters, so a real letter can win and block a substitution.
    private static let decoys = Array(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
            + ".,:;!?'\"()[]{}<>/\\|-_=+*&^%$#@~`"
    ).map(String.init)

    /// Characters Vision emits where a symbol really was. Only used to decide a
    /// word is worth inspecting; which symbol it becomes is decided by pixels.
    /// Derived from measurement, not guesswork: rendered every shortcut in the
    /// benchmark and recorded what Vision actually emitted where a symbol was.
    private static let suspect: Set<Character> = [
        "H", "&", "#", "X", "^", "T", "I", "K", "A", "M", "a", "o",
        "·", "•", "€", "£", "P", "8", "6", "J", "f"
    ]

    /// A segment has to match a symbol template at least this well before it is
    /// allowed to overwrite what Vision read.
    private static let symbolConfidence = 0.62

    /// When segmentation disagrees with Vision about how many glyphs there are,
    /// ordinary characters come from the classifier rather than from Vision, so
    /// the whole reading has to be stronger before it is trusted.
    private static let realignConfidence = 0.70

    /// Ceiling on repairs per grab, so a pathological screen cannot stall it.
    private static let maxRepairs = 80

    /// Resolution each glyph is normalised to before comparison.
    private static let gridSize = 28

    private static let templateFonts: [NSFont] = [
        .systemFont(ofSize: 72),
        .systemFont(ofSize: 72, weight: .medium),
        .monospacedSystemFont(ofSize: 72, weight: .regular),
        NSFont(name: "Helvetica", size: 72) ?? .systemFont(ofSize: 72),
        NSFont(name: "Menlo", size: 72) ?? .systemFont(ofSize: 72)
    ]

    // MARK: Entry point

    /// Returns `candidate.string` with unreadable glyphs restored.
    static func repair(_ candidate: VNRecognizedText, in image: CGImage) -> String {
        let text = candidate.string
        guard text.contains(where: { suspect.contains($0) }) else { return text }

        var result = ""
        var repairs = 0
        var index = text.startIndex

        while index < text.endIndex {
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
                                        candidate: candidate, image: image),
               fixed != word {
                result += fixed
                repairs += 1
            } else {
                result += word
            }

            index = wordEnd
        }

        return result
    }

    /// Per-word detail for diagnosing a bad repair. Not used by the app.
    static func diagnose(_ candidate: VNRecognizedText, in image: CGImage) -> [String] {
        var out: [String] = []
        let text = candidate.string
        var index = text.startIndex
        while index < text.endIndex {
            guard let ws = text[index...].firstIndex(where: { !$0.isWhitespace }) else { break }
            let we = text[ws...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            let word = String(text[ws..<we])
            defer { index = we }
            guard word.contains(where: { suspect.contains($0) }),
                  let observation = try? candidate.boundingBox(for: ws..<we) else { continue }
            let box = observation.boundingBox
            let rect = CGRect(x: box.minX * CGFloat(image.width),
                              y: (1 - box.maxY) * CGFloat(image.height),
                              width: box.width * CGFloat(image.width),
                              height: box.height * CGFloat(image.height)).integral
            guard let mask = mask(of: image, in: rect) else { out.append("[\(word)] no mask"); continue }
            var lines = ["[\(word)] chars=\(word.count)"]
            if let r = interpret(gapColumns(mask), mask: mask, ocr: word) {
                lines.append(String(format: "   gap  n=%d  %@  %.3f%@",
                    gapColumns(mask).count, r.text, r.confidence, r.containsSymbol ? " SYM" : ""))
            } else { lines.append("   gap  nil") }
            for c in [word.count, word.count - 1, word.count + 1] where c > 0 {
                if let r = interpret(evenColumns(mask, count: c), mask: mask, ocr: word) {
                    lines.append(String(format: "   even n=%d  %@  %.3f%@",
                        c, r.text, r.confidence, r.containsSymbol ? " SYM" : ""))
                }
            }
            out.append(lines.joined(separator: "\n"))
        }
        return out
    }

    // MARK: Word repair

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

        guard let mask = mask(of: image, in: rect) else { return nil }

        // Two ways to split the word. Gaps work for proportional text. Even
        // pitch works for monospaced, where a fallback glyph floats inside a
        // fixed-width cell and the gaps stop meaning anything.
        // Even pitch needs a glyph count, and Vision's character count is wrong
        // exactly when it split one glyph into two or merged two into one. Try
        // its count and the neighbours either side.
        var readings = [interpret(gapColumns(mask), mask: mask, ocr: word)]
        for count in [word.count, word.count - 1, word.count + 1] where count > 0 {
            readings.append(interpret(evenColumns(mask, count: count), mask: mask, ocr: word))
        }
        let candidates = readings.compactMap { $0 }

        guard let best = candidates.max(by: { $0.confidence < $1.confidence }) else { return nil }
        guard best.text != word, best.containsSymbol else { return nil }

        // Trusting the classifier for ordinary characters as well needs a
        // higher bar than only overwriting the suspect ones.
        let floor = best.realigned ? realignConfidence : symbolConfidence
        guard best.confidence >= floor else { return nil }

        return best.text
    }

    private struct Reading {
        let text: String
        let confidence: Double
        let containsSymbol: Bool
        /// True when segmentation disagreed with Vision's character count.
        let realigned: Bool
    }

    private static func interpret(
        _ columns: [(Int, Int)],
        mask: Mask,
        ocr word: String
    ) -> Reading? {
        guard !columns.isEmpty, columns.count <= 24 else { return nil }

        let ocrCharacters = Array(word)
        let aligned = columns.count == ocrCharacters.count
        var text = ""
        var total = 0.0
        var sawSymbol = false

        for (i, column) in columns.enumerated() {
            guard let grid = grid(mask, column) else { return nil }
            guard let hit = classify(grid, aspect: aspect(mask, column)).first else { return nil }
            total += hit.score

            if hit.isSymbol, hit.score >= symbolConfidence {
                text.append(hit.character)
                sawSymbol = true
            } else if aligned {
                // Vision reads Latin better than this classifier does; only let
                // the classifier speak where it is claiming a symbol.
                text.append(ocrCharacters[i])
            } else {
                text.append(hit.character)
            }
        }

        return Reading(
            text: text,
            confidence: total / Double(columns.count),
            containsSymbol: sawSymbol,
            realigned: !aligned
        )
    }

    // MARK: Segmentation

    struct Mask {
        let width: Int
        let height: Int
        let ink: [Bool]
    }

    private static func mask(of image: CGImage, in rect: CGRect) -> Mask? {
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
        guard high - low > 25 else { return nil }   // blank patch
        let threshold = low + (high - low) * 0.55

        return Mask(width: width, height: height, ink: pixels.map { Double($0) < threshold })
    }

    /// Glyph runs separated by columns with no ink. Works for proportional text.
    private static func gapColumns(_ mask: Mask) -> [(Int, Int)] {
        var counts = [Int](repeating: 0, count: mask.width)
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask.ink[y * mask.width + x] { counts[x] += 1 }
        }

        var runs: [(Int, Int)] = []
        var start: Int?
        for x in 0..<mask.width {
            if counts[x] > 0 {
                if start == nil { start = x }
            } else if let s = start {
                runs.append((s, x - 1))
                start = nil
            }
        }
        if let s = start { runs.append((s, mask.width - 1)) }

        // Merge slivers — an accent or a dot is part of the glyph beside it.
        var merged: [(Int, Int)] = []
        for run in runs {
            if let last = merged.last, run.0 - last.1 <= 1 {
                merged[merged.count - 1] = (last.0, run.1)
            } else {
                merged.append(run)
            }
        }
        return merged.filter { $0.1 - $0.0 >= 1 }
    }

    /// Equal-width cells. Monospaced fonts have no ⌘ glyph, so macOS drops a
    /// fallback into a fixed-width cell: a narrow glyph floats inside its cell
    /// and a wide one fills it, which makes the gaps unreliable. The pitch is
    /// not.
    private static func evenColumns(_ mask: Mask, count: Int) -> [(Int, Int)] {
        guard count > 0 else { return [] }
        var counts = [Int](repeating: 0, count: mask.width)
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask.ink[y * mask.width + x] { counts[x] += 1 }
        }
        guard let low = counts.firstIndex(where: { $0 > 0 }),
              let high = counts.lastIndex(where: { $0 > 0 }) else { return [] }

        let pitch = Double(high - low + 1) / Double(count)
        guard pitch >= 3 else { return [] }

        return (0..<count).map { i in
            (low + Int(Double(i) * pitch), low + Int(Double(i + 1) * pitch) - 1)
        }.filter { $0.1 > $0.0 }
    }

    // MARK: Glyph description

    /// Ink-trimmed, fixed-size grid. Trimming is what makes the comparison
    /// independent of font size and padding.
    private static func grid(_ mask: Mask, _ column: (Int, Int)) -> [Double]? {
        var minY = mask.height, maxY = -1
        for y in 0..<mask.height {
            for x in column.0...min(column.1, mask.width - 1)
            where mask.ink[y * mask.width + x] {
                minY = min(minY, y); maxY = max(maxY, y)
                break
            }
        }
        guard maxY >= minY else { return nil }

        let glyphWidth = column.1 - column.0 + 1, glyphHeight = maxY - minY + 1
        var out = [Double](repeating: 0, count: gridSize * gridSize)
        for gy in 0..<gridSize {
            for gx in 0..<gridSize {
                let sx = min(column.0 + gx * glyphWidth / gridSize, mask.width - 1)
                let sy = min(minY + gy * glyphHeight / gridSize, mask.height - 1)
                out[gy * gridSize + gx] = mask.ink[sy * mask.width + sx] ? 1 : 0
            }
        }
        return out
    }

    private static func aspect(_ mask: Mask, _ column: (Int, Int)) -> Double {
        var minY = mask.height, maxY = -1
        for y in 0..<mask.height {
            for x in column.0...min(column.1, mask.width - 1)
            where mask.ink[y * mask.width + x] {
                minY = min(minY, y); maxY = max(maxY, y)
                break
            }
        }
        guard maxY >= minY else { return 1 }
        return Double(column.1 - column.0 + 1) / Double(maxY - minY + 1)
    }

    /// Enclosed regions. ⌘ has several, `H` has none, and that separates them
    /// before any pixel comparison happens.
    private static func holes(_ grid: [Double]) -> Int {
        var seen = [Bool](repeating: false, count: gridSize * gridSize)
        var count = 0

        for start in 0..<(gridSize * gridSize) where grid[start] <= 0.5 && !seen[start] {
            var stack = [start]
            seen[start] = true
            var touchesEdge = false

            while let current = stack.popLast() {
                let cx = current % gridSize, cy = current / gridSize
                if cx == 0 || cy == 0 || cx == gridSize - 1 || cy == gridSize - 1 {
                    touchesEdge = true
                }
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = cx + dx, ny = cy + dy
                    guard nx >= 0, ny >= 0, nx < gridSize, ny < gridSize else { continue }
                    let next = ny * gridSize + nx
                    if !seen[next], grid[next] <= 0.5 {
                        seen[next] = true
                        stack.append(next)
                    }
                }
            }
            if !touchesEdge { count += 1 }
        }
        return count
    }

    // MARK: Template bank

    private struct Template {
        let character: String
        let isSymbol: Bool
        let grid: [Double]
        let holes: Int
        let aspect: Double
    }

    private static let bank: [Template] = {
        var out: [Template] = []
        for font in templateFonts {
            for symbol in symbols {
                if let t = render(symbol, font: font, isSymbol: true) { out.append(t) }
            }
            for decoy in decoys {
                if let t = render(decoy, font: font, isSymbol: false) { out.append(t) }
            }
        }
        return out
    }()

    private static func render(_ text: String, font: NSFont, isSymbol: Bool) -> Template? {
        let string = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: NSColor.black]
        )
        let size = string.size()
        let width = Int(size.width.rounded(.up)) + 24
        let height = Int(size.height.rounded(.up)) + 24
        guard width > 8, height > 8 else { return nil }

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
        string.draw(at: NSPoint(x: 12, y: 12))
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage(),
              let mask = mask(of: image, in: CGRect(x: 0, y: 0, width: width, height: height))
        else { return nil }

        let columns = gapColumns(mask)
        guard let first = columns.first, let last = columns.last else { return nil }
        let span = (first.0, last.1)
        guard let grid = grid(mask, span) else { return nil }

        return Template(
            character: text, isSymbol: isSymbol, grid: grid,
            holes: holes(grid), aspect: aspect(mask, span)
        )
    }

    // MARK: Matching

    private struct Hit {
        let character: String
        let isSymbol: Bool
        let score: Double
    }

    /// Jaccard overlap on the binarised grids. It survives the changes in
    /// contrast and stroke weight that throw off squared difference.
    private static func overlap(_ a: [Double], _ b: [Double]) -> Double {
        var intersection = 0.0, union = 0.0
        for i in 0..<a.count {
            let x = a[i] > 0.5, y = b[i] > 0.5
            if x && y { intersection += 1 }
            if x || y { union += 1 }
        }
        return union == 0 ? 0 : intersection / union
    }

    private static func classify(_ grid: [Double], aspect glyphAspect: Double) -> [Hit] {
        let glyphHoles = holes(grid)
        var hits: [Hit] = []
        hits.reserveCapacity(64)

        for template in bank {
            guard abs(template.holes - glyphHoles) <= 1 else { continue }
            hits.append(Hit(
                character: template.character,
                isSymbol: template.isSymbol,
                score: overlap(grid, template.grid)
            ))
        }
        return hits.sorted { $0.score > $1.score }
    }
}
