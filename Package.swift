// swift-tools-version: 6.1
// 最低 Swift 6.1（Xcode 16.3 / Command Line Tools 16.3 及以上）

import PackageDescription

let package = Package(
    name: "TimeNoteApp",
    platforms: [
        // 编译目标保持 macOS 14：以 macOS 26 为编译目标时，当前命令行工具编出的程序
        // 会在主线程执行器检查处崩溃。安装包通过 Info.plist 的 LSMinimumSystemVersion
        // 要求 macOS 26（录音转文字用到的 SpeechAnalyzer 只在 macOS 26 提供）。
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
