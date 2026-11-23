import Foundation
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
