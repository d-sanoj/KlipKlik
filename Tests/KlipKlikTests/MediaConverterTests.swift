import AppKit
import Foundation
import ImageIO
import Testing
@testable import KlipKlik

@Suite struct MediaConverterTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("klipklik-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func resultGoesBesideTheOriginalAndNeverOverwrites() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("photo.png")
        FileManager.default.createFile(atPath: source.path, contents: Data([1]))

        let first = MediaConverter.outputURL(for: source, extension: "jpg", suffix: nil)
        #expect(first.lastPathComponent == "photo.jpg")
        #expect(first.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)

        FileManager.default.createFile(atPath: first.path, contents: Data([1]))
        let second = MediaConverter.outputURL(for: source, extension: "jpg", suffix: nil)
        #expect(second.lastPathComponent == "photo 2.jpg")

        let resized = MediaConverter.outputURL(for: source, extension: "png", suffix: "512px")
        #expect(resized.lastPathComponent == "photo (512px).png")
    }

    @Test func kindsComeFromTheExtension() {
        #expect(MediaConverter.kind(of: URL(fileURLWithPath: "/a/b.heic")) == .image)
        #expect(MediaConverter.kind(of: URL(fileURLWithPath: "/a/b.mov")) == .video)
        #expect(MediaConverter.kind(of: URL(fileURLWithPath: "/a/b.mp3")) == .audio)
        #expect(MediaConverter.kind(of: URL(fileURLWithPath: "/a/b.txt")) == nil)
    }

    @Test func aPictureIsNotOfferedItsOwnFormat() {
        let titles = MediaConverter.formats(for: URL(fileURLWithPath: "/a/b.png")).map(\.title)
        #expect(!titles.contains("PNG"))
        #expect(titles.contains("JPEG"))
        #expect(titles.contains("HEIC"))
    }
}

@Suite struct ScreenshotOutputTests {
    @Test func retinaCapturesCarryTheirDensity() throws {
        let context = CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = try #require(context.makeImage())
        let png = try #require(ScreenshotOutput.encode(image, as: .png, scale: 2))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyDPIWidth] as? Double) == 144)
        // So it opens at 20 × 10 points, not stretched to 40 × 20.
        let opened = try #require(NSImage(data: png))
        #expect(opened.size == NSSize(width: 20, height: 10))
    }

    @Test func savedNamesLookLikeScreenshots() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 23; parts.hour = 18; parts.minute = 4; parts.second = 11
        let date = Calendar.current.date(from: parts)!
        #expect(ScreenshotOutput.defaultName(at: date) == "Scrolling Screenshot 2026-11-23 at 18.04.11.png")
    }
}
