// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "smudge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "smudge",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
