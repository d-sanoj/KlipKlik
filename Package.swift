// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KlipKlik",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "KlipKlik",
            path: "Sources/KlipKlik",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Pure logic only: link cleaning, matching rules, parsers. Run with
        // `swift test`; nothing here touches the pasteboard or the disk.
        .testTarget(
            name: "KlipKlikTests",
            dependencies: ["KlipKlik"],
            path: "Tests/KlipKlikTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
