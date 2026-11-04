// swift-tools-version: 6.1
// 最低 Swift 6.1（Xcode 16.3 / Command Line Tools 16.3 及以上）

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
