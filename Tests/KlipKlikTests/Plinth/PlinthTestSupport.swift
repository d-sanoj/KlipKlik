import Foundation
@testable import KlipKlik

/// A disk for the builder that exists only in memory.
enum PlinthFakeDisk {
    static let folder = URL(fileURLWithPath: "/Users/test/Desktop", isDirectory: true)
    static let fallback = URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true)
    /// 2026-11-28 12:00 UTC.
    static let date = Date(timeIntervalSince1970: 1_795_867_200)

    /// Items in `folder`. A name ending in "/" is a folder.
    static func items(_ names: [String], in directory: URL = folder) -> [PlinthItem] {
        names.map { name in
            let isFolder = name.hasSuffix("/")
            let clean = isFolder ? String(name.dropLast()) : name
            return PlinthItem(url: directory.appendingPathComponent(clean, isDirectory: isFolder),
                              isDirectory: isFolder)
        }
    }

    static func probe(existing: Set<String> = [], writable: Bool = true,
                      size: (width: Int, height: Int)? = (4000, 3000)) -> PlinthFileProbe {
        PlinthFileProbe(
            exists: { existing.contains($0.lastPathComponent) },
            isWritableDirectory: { _ in writable },
            pixelSize: { _ in size },
            creationDate: { _ in date }
        )
    }

    static func builder(ffmpeg: Bool = true, existing: Set<String> = [], writable: Bool = true,
                        size: (width: Int, height: Int)? = (4000, 3000)) -> PlinthCommandBuilder {
        PlinthCommandBuilder(
            tools: PlinthToolPaths(ffmpeg: ffmpeg ? URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg") : nil),
            probe: probe(existing: existing, writable: writable, size: size),
            fallbackDirectory: fallback,
            timeZone: TimeZone(identifier: "UTC")!
        )
    }
}

extension PlinthPlan {
    var processes: [PlinthProcess] {
        steps.compactMap { if case .run(let process) = $0 { return process } else { return nil } }
    }

    var createdNames: [String] { created.map(\.lastPathComponent) }
}
