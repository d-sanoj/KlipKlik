// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KlipKlick",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "KlipKlick",
            path: "Sources/KlipKlick",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
