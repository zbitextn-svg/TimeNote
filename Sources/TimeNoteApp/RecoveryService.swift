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

        let integrityMessage: String
        do {
            integrityMessage = try runIntegrityCheck(at: databaseURL)
        } catch {
            integrityMessage = error.localizedDescription
        }
        guard integrityMessage != "ok" else {
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

    private static func runIntegrityCheck(at databaseURL: URL) throws -> String {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            let message = database.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            sqlite3_close(database)
            throw RecoveryIssue.openFailed("数据库打开失败：\(message)")
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check(1);", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RecoveryIssue.integrityCheckFailed("数据库完整性检查启动失败：\(String(cString: sqlite3_errmsg(database)))")
        }
        defer { sqlite3_finalize(statement) }

        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            throw RecoveryIssue.integrityCheckFailed("数据库完整性检查执行失败：\(String(cString: sqlite3_errmsg(database)))")
        }

        guard let textPointer = sqlite3_column_text(statement, 0) else {
            return "unknown"
        }
        return String(cString: textPointer)
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
