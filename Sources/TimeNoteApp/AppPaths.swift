import Foundation

/// 应用数据目录。
///
/// 默认位于 `~/Library/Application Support/TimeNote/`。
/// 开发调试或运行测试时，可以设置环境变量 `TIMENOTE_DATA_DIR` 指向临时目录，
/// 避免读写真实的场记数据库与附件。
enum AppPaths {
    static let dataDirectoryEnvironmentKey = "TIMENOTE_DATA_DIR"

    static func rootDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment[dataDirectoryEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            override.isEmpty == false {
            let url = URL(
                fileURLWithPath: (override as NSString).expandingTildeInPath,
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root.appendingPathComponent("TimeNote", isDirectory: true)
    }

    static func databaseURL(in rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("timenote.sqlite")
    }
}
