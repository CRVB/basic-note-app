// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "YazbozNote",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "YazbozNoteApp",
            targets: ["YazbozNoteApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "YazbozNoteApp"
        )
    ]
)
