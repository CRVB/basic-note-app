// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NoteLight",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "NoteLight",
            targets: ["YazbozNoteApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "YazbozNoteApp",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "YazbozNoteAppTests",
            dependencies: ["YazbozNoteApp"]
        )
    ]
)
