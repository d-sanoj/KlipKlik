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
        )
    ]
)
