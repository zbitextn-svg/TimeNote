// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TimeNoteApp",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "TimeNoteApp",
            exclude: [
                "Assets.xcassets",
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "TimeNoteAppTests",
            dependencies: ["TimeNoteApp"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
