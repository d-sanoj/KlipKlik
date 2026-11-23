import CoreGraphics
import Foundation
import Testing
@testable import KlipKlik

@Suite struct ScrollStitcherTests {
    /// A tall "page" whose every row is distinct: stripes of varying
    /// brightness, with a few blank stretches like real pages have.
    private func page(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        var generator = SystemRandomNumberGenerator()
        for row in 0..<height {
            let blank = (row / 90) % 5 == 4
            for block in 0..<8 {
                let value = blank ? 1.0 : Double(UInt8.random(in: 0...255, using: &generator)) / 255
                context.setFillColor(CGColor(red: value, green: value * 0.8, blue: 1 - value, alpha: 1))
                context.fill(CGRect(x: block * width / 8, y: height - row - 1, width: width / 8, height: 1))
            }
        }
        return context.makeImage()!
    }

    /// A screenful of `page` starting at `top`, with optional sticky bars.
    private func shot(of page: CGImage, top: Int, height: Int, header: Int = 0, footer: Int = 0) -> CGImage {
        let width = page.width
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let slice = page.cropping(to: CGRect(x: 0, y: top, width: width, height: height))!
        context.draw(slice, in: CGRect(x: 0, y: 0, width: width, height: height))
        if header > 0 {
            context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: height - header, width: width, height: header))
        }
        if footer > 0 {
            context.setFillColor(CGColor(red: 0.7, green: 0.1, blue: 0.4, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: footer))
        }
        return context.makeImage()!
    }

    private func signatures(_ image: CGImage) -> ScrollStitcher.Signatures {
        ScrollStitcher.signatures(of: image)!
    }

    @Test func findsTheScrollDistance() throws {
        let tall = page(width: 320, height: 2000)
        let a = shot(of: tall, top: 0, height: 400)
        let b = shot(of: tall, top: 260, height: 400)
        let step = try #require(ScrollStitcher.step(from: signatures(a), to: signatures(b), expected: 280))
        #expect(step.shift == 260)
        #expect(step.header == 0)
    }

    @Test func recognisesStickyHeaderAndFooter() throws {
        let tall = page(width: 320, height: 2000)
        let a = shot(of: tall, top: 0, height: 400, header: 40, footer: 30)
        let b = shot(of: tall, top: 250, height: 400, header: 40, footer: 30)
        let step = try #require(ScrollStitcher.step(from: signatures(a), to: signatures(b), expected: 250))
        #expect(step.shift == 250)
        #expect(step.header >= 40)
        #expect(step.footer >= 30)
    }

    @Test func noMovementMeansTheEnd() throws {
        let tall = page(width: 320, height: 2000)
        let a = shot(of: tall, top: 500, height: 400)
        let step = try #require(ScrollStitcher.step(from: signatures(a), to: signatures(a), expected: 250))
        #expect(step.shift == 0)
    }

    @Test func unrelatedPicturesDoNotMatch() {
        let a = shot(of: page(width: 320, height: 1000), top: 0, height: 400)
        let b = shot(of: page(width: 320, height: 1000), top: 0, height: 400)
        #expect(ScrollStitcher.step(from: signatures(a), to: signatures(b), expected: 250) == nil)
    }

    @Test func composedPictureMatchesThePage() throws {
        let tall = page(width: 160, height: 1400)
        let tops = [0, 300, 600, 900, 1000]
        let frames = tops.map { shot(of: tall, top: $0, height: 400) }
        var steps: [ScrollStitcher.Step] = []
        for index in 1..<frames.count {
            steps.append(try #require(ScrollStitcher.step(
                from: signatures(frames[index - 1]), to: signatures(frames[index]), expected: 300
            )))
        }
        #expect(steps.map(\.shift) == [300, 300, 300, 100])

        let result = try #require(ScrollStitcher.compose(frames, steps: steps))
        #expect(result.height == 1400)
        // Row by row, the stitched picture is the page.
        let expected = signatures(tall), actual = signatures(result)
        let mismatched = (0..<1400).filter { expected.difference($0, actual, $0) > 2 }
        #expect(mismatched.isEmpty)
    }

    @Test func stickyBarsAppearOnceInTheResult() throws {
        let tall = page(width: 160, height: 1200)
        let frames = [0, 300, 600].map { shot(of: tall, top: $0, height: 400, header: 30, footer: 20) }
        var steps: [ScrollStitcher.Step] = []
        for index in 1..<frames.count {
            steps.append(try #require(ScrollStitcher.step(
                from: signatures(frames[index - 1]), to: signatures(frames[index]), expected: 300
            )))
        }
        let result = try #require(ScrollStitcher.compose(frames, steps: steps))
        #expect(result.height == 1000)
        // Header colour at the very top, footer colour at the very bottom, and
        // the page in between — not a header every 300 pixels.
        let rows = signatures(result)
        let header = signatures(frames[0])
        #expect(rows.difference(5, header, 5) <= 2)
        #expect(rows.difference(rows.rows - 5, header, header.rows - 5) <= 2)
        let page = signatures(tall)
        #expect(rows.difference(330, page, 330) <= 2)
        #expect(rows.difference(630, page, 630) <= 2)
    }
}
