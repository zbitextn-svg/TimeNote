import Foundation
import SQLite3

enum RecoveryIssue: LocalizedError {
    case openFailed(String)
    case integrityCheckFailed(String)
    case backupFailed(String)
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message),
             .integrityCheckFailed(let message),
             .backupFailed(let message),
             .restoreFailed(let message):
            return message
        }
    }
}

enum LaunchRecoveryResult {
    case restoredFromBackup(backupFileName: String)
    case recreatedDatabaseAfterCorruption(archivedFileName: String)

    var userMessage: String {
        switch self {
        case .restoredFromBackup(let backupFileName):
            return "启动时检测到数据库异常，已自动从最近备份恢复：\(backupFileName)"
        case .recreatedDatabaseAfterCorruption(let archivedFileName):
            return "启动时检测到数据库异常，且没有可用备份。原数据库已移到 \(archivedFileName)，当前已创建新的空数据库。"
        }
    }

    var recoveryNote: String {
        switch self {
        case .restoredFromBackup(let backupFileName):
            return "已从备份恢复：\(backupFileName)"
        case .recreatedDatabaseAfterCorruption(let archivedFileName):
            return "无备份可恢复，已隔离损坏数据库：\(archivedFileName)"
        }
    }
}

enum RecoveryService {
    static func prepareDatabaseForLaunch(at databaseURL: URL) throws -> LaunchRecoveryResult? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return nil
        }

        // 只有确认数据库损坏时才隔离；数据库被占用、权限等临时问题不应触发"恢复"，
        // 否则会把一个完好的数据库挪走，造成数据丢失的假象。
        guard case .corrupted = checkIntegrity(at: databaseURL) else {
            return nil
        }

        let quarantinedURL = try quarantineDatabase(at: databaseURL)
        if let backupURL = try latestBackupURL(for: databaseURL) {
            do {
                try restoreBackup(from: backupURL, to: databaseURL)
                return .restoredFromBackup(backupFileName: backupURL.lastPathComponent)
            } catch {
                return .recreatedDatabaseAfterCorruption(archivedFileName: quarantinedURL.lastPathComponent)
            }
        }

        return .recreatedDatabaseAfterCorruption(archivedFileName: quarantinedURL.lastPathComponent)
    }

    static func backupsDirectoryURL(for databaseURL: URL) -> URL {
        databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("Backups", isDirectory: true)
    }

    static func createBackup(from sourceDatabase: OpaquePointer, databaseURL: URL) throws -> URL {
        let backupDirectory = backupsDirectoryURL(for: databaseURL)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        let backupURL = backupDirectory.appendingPathComponent("timenote-backup-\(timestamp()).sqlite")
        var destination: OpaquePointer?
        guard sqlite3_open(backupURL.path, &destination) == SQLITE_OK, let destination else {
            throw RecoveryIssue.backupFailed("无法创建备份数据库文件。")
        }
        defer { sqlite3_close(destination) }

        let backup = sqlite3_backup_init(destination, "main", sourceDatabase, "main")
        guard let backup else {
            throw RecoveryIssue.backupFailed("无法启动数据库备份：\(String(cString: sqlite3_errmsg(destination)))")
        }

        let result = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)

        guard result == SQLITE_DONE else {
            throw RecoveryIssue.backupFailed("数据库备份失败：\(String(cString: sqlite3_errmsg(destination)))")
        }

        return backupURL
    }

    static func pruneBackups(for databaseURL: URL, keepLast limit: Int) throws {
        guard limit > 0 else { return }
        let backupDirectory = backupsDirectoryURL(for: databaseURL)
        guard FileManager.default.fileExists(atPath: backupDirectory.path) else { return }

        let backups = try backupFiles(in: backupDirectory)
        guard backups.count > limit else { return }

        for url in backups.dropFirst(limit) {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: sidecarURL(for: url, suffix: "-wal"))
            try? FileManager.default.removeItem(at: sidecarURL(for: url, suffix: "-shm"))
        }
    }

    static func latestBackupURL(for databaseURL: URL) throws -> URL? {
        let backupDirectory = backupsDirectoryURL(for: databaseURL)
        guard FileManager.default.fileExists(atPath: backupDirectory.path) else { return nil }
        return try backupFiles(in: backupDirectory).first
    }

    private static func backupFiles(in directory: URL) throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        return urls
            .filter { $0.pathExtension == "sqlite" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    private static func restoreBackup(from backupURL: URL, to databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try removeDatabaseArtifacts(at: databaseURL)
        try FileManager.default.copyItem(at: backupURL, to: databaseURL)
    }

    private static func quarantineDatabase(at databaseURL: URL) throws -> URL {
        let quarantineDirectory = databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)

        let quarantinedURL = quarantineDirectory.appendingPathComponent("timenote-corrupted-\(timestamp()).sqlite")
        try moveDatabaseArtifacts(from: databaseURL, to: quarantinedURL)
        return quarantinedURL
    }

    private static func moveDatabaseArtifacts(from sourceURL: URL, to destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        }

        for suffix in ["-wal", "-shm"] {
            let sidecarSource = sidecarURL(for: sourceURL, suffix: suffix)
            if FileManager.default.fileExists(atPath: sidecarSource.path) {
                let sidecarDestination = sidecarURL(for: destinationURL, suffix: suffix)
                try FileManager.default.moveItem(at: sidecarSource, to: sidecarDestination)
            }
        }
    }

    private static func removeDatabaseArtifacts(at databaseURL: URL) throws {
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            try FileManager.default.removeItem(at: databaseURL)
        }

        for suffix in ["-wal", "-shm"] {
            let sidecar = sidecarURL(for: databaseURL, suffix: suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
        }
    }

    enum IntegrityStatus: Equatable {
        case ok
        case corrupted(String)
        /// 无法完成检查（被占用、权限、IO 等），不代表数据库已损坏
        case inconclusive(String)
    }

    static func checkIntegrity(at databaseURL: URL) -> IntegrityStatus {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(databaseURL.path, &database, flags, nil)
        defer { sqlite3_close(database) }
        guard openResult == SQLITE_OK, let database else {
            let message = database.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            return classify(code: openResult, message: "数据库打开失败：\(message)")
        }
        sqlite3_busy_timeout(database, 3000)

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, "PRAGMA quick_check(1);", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepareResult == SQLITE_OK, let statement else {
            return classify(
                code: sqlite3_errcode(database),
                message: "数据库完整性检查启动失败：\(String(cString: sqlite3_errmsg(database)))"
            )
        }

        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            return classify(
                code: sqlite3_errcode(database),
                message: "数据库完整性检查执行失败：\(String(cString: sqlite3_errmsg(database)))"
            )
        }

        guard let textPointer = sqlite3_column_text(statement, 0) else {
            return .inconclusive("完整性检查没有返回结果")
        }
        let result = String(cString: textPointer)
        return result == "ok" ? .ok : .corrupted(result)
    }

    private static func classify(code: Int32, message: String) -> IntegrityStatus {
        switch code & 0xFF {
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return .corrupted(message)
        default:
            return .inconclusive(message)
        }
    }

    private static func sidecarURL(for databaseURL: URL, suffix: String) -> URL {
        URL(fileURLWithPath: databaseURL.path + suffix)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }
}
