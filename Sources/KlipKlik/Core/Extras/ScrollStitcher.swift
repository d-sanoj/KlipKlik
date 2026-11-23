import CoreGraphics
import Foundation

/// Joins a run of overlapping screenshots of a scrolling view into one tall
/// picture.
///
/// Each pair of consecutive shots is compared row by row to find how far the
/// content moved. Rows that did not move at all — a sticky header at the top,
/// a fixed toolbar at the bottom — are recognised and kept only once, so they
/// do not repeat down the length of the page.
///
/// Comparison runs on a small signature of each row (its brightness averaged
/// into a few dozen segments) rather than on every pixel, which is what makes
/// a full search over every possible offset affordable.
enum ScrollStitcher {
    /// How many segments a row's signature has.
    static let signatureWidth = 96

    /// The brightness signature of every row of a picture.
    struct Signatures: Equatable {
        let rows: Int
        let width: Int
        let values: [UInt8]

        /// Mean absolute difference between row `a` here and row `b` there.
        func difference(_ a: Int, _ other: Signatures, _ b: Int) -> Int {
            var total = 0
            let lhs = a * width, rhs = b * other.width
            for i in 0..<width {
                total += abs(Int(values[lhs + i]) - Int(other.values[rhs + i]))
            }
            return total / width
        }
    }

    /// How one shot relates to the one before it.
    struct Step: Equatable {
        /// Pixels the content moved up. 0 means it did not move: the end.
        let shift: Int
        /// Rows at the top that stayed put (a sticky header).
        let header: Int
        /// Rows at the bottom that stayed put (a fixed footer).
        let footer: Int
    }

    static func signatures(of image: CGImage) -> Signatures? {
        let width = signatureWidth, height = image.height
        guard height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return nil }
        // Squeezing the width averages each segment; the height stays 1:1.
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let buffer = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height)
        return Signatures(rows: height, width: width, values: Array(buffer))
    }

    /// Rows within this much (on 0…255) count as the same.
    private static let sameRow = 2

    /// Finds how far `next` moved relative to `previous`.
    ///
    /// - Parameter expected: roughly how far the view was asked to scroll, in
    ///   pixels. Content with long blank stretches matches at many offsets;
    ///   among equally good ones, the one nearest this wins.
    /// - Returns: nil when no offset fits convincingly — the content changed
    ///   rather than scrolled.
    static func step(from previous: Signatures, to next: Signatures, expected: Int?) -> Step? {
        guard previous.rows == next.rows, previous.width == next.width else { return nil }
        let height = previous.rows

        var header = 0
        while header < height, previous.difference(header, next, header) <= sameRow { header += 1 }
        if header == height { return Step(shift: 0, header: height, footer: 0) }

        var footer = 0
        while footer < height - header,
              previous.difference(height - 1 - footer, next, height - 1 - footer) <= sameRow {
            footer += 1
        }

        let content = height - header - footer
        // Enough shared rows to be sure of the match. The capture scrolls by
        // a little over half of the moving area, so real steps leave plenty.
        let minimumOverlap = max(24, content / 8)
        guard content > minimumOverlap + 1 else { return nil }

        func cost(_ shift: Int) -> Double {
            var total = 0, count = 0
            var row = header + shift
            while row < height - footer {
                total += previous.difference(row, next, row - shift)
                count += 1
                row += 2
            }
            return count == 0 ? .infinity : Double(total) / Double(count)
        }

        let maxShift = content - minimumOverlap
        var costs: [(shift: Int, cost: Double)] = []
        costs.reserveCapacity(maxShift)
        for shift in 1...maxShift { costs.append((shift, cost(shift))) }
        guard let best = costs.min(by: { $0.cost < $1.cost }), best.cost <= 6 else { return nil }

        // Ties go to the offset nearest the scroll that was asked for.
        let contenders = costs.filter { $0.cost <= best.cost + 0.75 }
        let chosen = expected.flatMap { target in
            contenders.min { abs($0.shift - target) < abs($1.shift - target) }
        } ?? best
        return Step(shift: chosen.shift, header: header, footer: footer)
    }

    /// True when two shots show the same thing — the view has stopped moving.
    /// Allows a few changed rows, for a blinking caret or a ticking clock.
    static func isSettled(_ a: Signatures, _ b: Signatures) -> Bool {
        guard a.rows == b.rows, a.width == b.width else { return false }
        var same = 0
        for row in 0..<a.rows where a.difference(row, b, row) <= sameRow { same += 1 }
        return Double(same) >= Double(a.rows) * 0.97
    }

    /// Paints the shots into one picture. `steps[i]` relates `frames[i]` to
    /// `frames[i + 1]`.
    static func compose(_ frames: [CGImage], steps: [Step]) -> CGImage? {
        guard let first = frames.first, steps.count == frames.count - 1 else { return nil }
        let builder = Builder(first: first)
        for (index, step) in steps.enumerated() { builder.add(frames[index + 1], step: step) }
        return builder.finish()
    }

    /// Builds the picture as shots arrive, keeping only what each one adds.
    ///
    /// A shot's visible part is known as soon as the next shot is matched to
    /// it: everything from below its sticky header down to where the next
    /// shot's content takes over. That strip is copied out and the shot is let
    /// go, so a long page costs about one picture's worth of memory, not one
    /// per shot.
    final class Builder {
        private var strips: [CGImage] = []
        private var current: CGImage
        /// Rows of `current` above this are covered by an earlier strip.
        private var keepFrom = 0

        private(set) var height: Int

        init(first: CGImage) {
            current = first
            height = first.height
        }

        /// - Parameter step: how `next` relates to the last shot added.
        func add(_ next: CGImage, step: Step) {
            // The last shot is visible down to where `next`'s content begins.
            let end = min(current.height, step.shift + step.header)
            if end > keepFrom, let strip = Builder.copy(current, rows: keepFrom, end) {
                strips.append(strip)
            }
            current = next
            keepFrom = min(step.header, next.height)
            height = strips.reduce(0) { $0 + $1.height } + (next.height - keepFrom)
        }

        /// The finished picture: every strip, then the last shot from below
        /// its sticky header to its bottom edge, footer included.
        func finish() -> CGImage? {
            var pieces = strips
            if let tail = Builder.copy(current, rows: keepFrom, current.height) { pieces.append(tail) }
            guard let first = pieces.first else { return nil }
            let width = first.width
            let total = pieces.reduce(0) { $0 + $1.height }
            guard let context = CGContext(
                data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                space: first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            var top = 0
            for piece in pieces {
                context.draw(piece, in: CGRect(x: 0, y: total - top - piece.height,
                                               width: piece.width, height: piece.height))
                top += piece.height
            }
            return context.makeImage()
        }

        /// Rows `from..<to` as an image of their own. Drawn into a new bitmap
        /// rather than cropped: a crop keeps the whole shot alive behind it.
        private static func copy(_ image: CGImage, rows from: Int, _ to: Int) -> CGImage? {
            guard to > from,
                  let slice = image.cropping(to: CGRect(x: 0, y: from, width: image.width, height: to - from)),
                  let context = CGContext(
                      data: nil, width: image.width, height: to - from, bitsPerComponent: 8, bytesPerRow: 0,
                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return nil }
            context.draw(slice, in: CGRect(x: 0, y: 0, width: image.width, height: to - from))
            return context.makeImage()
        }
    }
}
