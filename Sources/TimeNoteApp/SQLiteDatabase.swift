import Foundation
import SQLite3

enum DatabaseError: LocalizedError {
    case openFailed(String)
    case executeFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case missingRow

    var errorDescription: String? {
        switch self {
        case .openFailed(let message),
             .executeFailed(let message),
             .prepareFailed(let message),
             .stepFailed(let message):
            return message
        case .missingRow:
            return "未找到对应的数据。"
        }
    }
}

final class SQLiteDatabase {
    private let db: OpaquePointer
    private let path: URL
    private static let fullTextSchemaVersion = "3"

    init(path: URL) throws {
        self.path = path
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var pointer: OpaquePointer?
        if sqlite3_open(path.path, &pointer) != SQLITE_OK {
            let message = pointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            sqlite3_close(pointer)
            throw DatabaseError.openFailed("数据库打开失败：\(message)")
        }

        db = pointer!
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA busy_timeout = 3000;")
        try runMigrations()
        try seedIfNeeded()
    }

    deinit {
        sqlite3_close(db)
    }

    static func defaultDatabaseURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root
            .appendingPathComponent("TimeNote", isDirectory: true)
            .appendingPathComponent("timenote.sqlite")
    }

    func createBackupIfNeeded(force: Bool = false, minimumInterval: TimeInterval = 6 * 60 * 60) throws -> URL? {
        if force == false, let lastBackupAt = try lastBackupAt() {
            let elapsed = Date().timeIntervalSince(lastBackupAt)
            guard elapsed >= minimumInterval else { return nil }
        }

        let backupURL = try RecoveryService.createBackup(from: db, databaseURL: path)
        try setMetaValue(TimeFormats.iso8601String(from: .now), for: "last_backup_at")
        try RecoveryService.pruneBackups(for: path, keepLast: 20)
        return backupURL
    }

    func recordRecovery(_ result: LaunchRecoveryResult) throws {
        let now = TimeFormats.iso8601String(from: .now)
        try setMetaValue(now, for: "last_recovery_at")
        try setMetaValue(result.recoveryNote, for: "last_recovery_note")
    }

    func fetchProjects(includeArchived: Bool = false) throws -> [Project] {
        let sql = includeArchived
            ? """
              SELECT id, title, is_archived, created_at, updated_at, archived_at
              FROM projects
              ORDER BY created_at DESC
              """
            : """
              SELECT id, title, is_archived, created_at, updated_at, archived_at
              FROM projects
              WHERE is_archived = 0
              ORDER BY created_at DESC
              """

        return try query(sql) { statement in
            Project(
                id: statement.text(at: 0),
                title: statement.text(at: 1),
                isArchived: statement.int(at: 2) == 1,
                createdAt: statement.date(at: 3),
                updatedAt: statement.date(at: 4),
                archivedAt: statement.optionalDate(at: 5)
            )
        }
    }

    func fetchArchivedProjects() throws -> [Project] {
        try query(
            """
            SELECT id, title, is_archived, created_at, updated_at, archived_at
            FROM projects
            WHERE is_archived = 1
            ORDER BY archived_at DESC, updated_at DESC
            """
        ) { statement in
            Project(
                id: statement.text(at: 0),
                title: statement.text(at: 1),
                isArchived: statement.int(at: 2) == 1,
                createdAt: statement.date(at: 3),
                updatedAt: statement.date(at: 4),
                archivedAt: statement.optionalDate(at: 5)
            )
        }
    }

    func createProject(title: String = "未命名项目") throws -> Project {
        let now = Date()
        let id = UUID().uuidString
        let timestamp = TimeFormats.iso8601String(from: now)
        try execute(
            """
            INSERT INTO projects (id, title, is_archived, created_at, updated_at)
            VALUES (?, ?, 0, ?, ?)
            """,
            bindings: [.text(id), .text(title), .text(timestamp), .text(timestamp)]
        )
        try insertMainTab(projectID: id, now: now)
        return try fetchProject(id: id)
    }

    func duplicateProject(id: String) throws -> Project {
        let original = try fetchProject(id: id)
        let tabs = try fetchTabs(projectID: id)
        let entries = try fetchEntries(projectID: id, tabID: tabs.first(where: { $0.kind == .mainLog })?.id)

        let duplicated = try createProject(title: "\(original.title) 副本")
        let duplicatedMainTab = try fetchTabs(projectID: duplicated.id).first(where: { $0.kind == .mainLog })

        var tabIDMap: [String: String] = [:]
        if let originalMainTab = tabs.first(where: { $0.kind == .mainLog }), let duplicatedMainTab {
            tabIDMap[originalMainTab.id] = duplicatedMainTab.id
        }

        for tab in tabs where tab.kind == .text {
            let copiedTab = try createTextTab(projectID: duplicated.id, title: tab.title)
            try updateTabBody(tabID: copiedTab.id, body: tab.body)
            tabIDMap[tab.id] = copiedTab.id
        }

        for entry in entries {
            guard let targetTabID = tabIDMap[entry.tabID] else { continue }
            try insertLogEntry(
                projectID: duplicated.id,
                tabID: targetTabID,
                recordedAt: entry.recordedAt,
                noteText: entry.noteText
            )
        }

        return duplicated
    }

    func archiveProject(id: String) throws {
        let now = TimeFormats.iso8601String(from: Date())
        try execute(
            """
            UPDATE projects
            SET is_archived = 1, archived_at = ?, updated_at = ?
            WHERE id = ?
            """,
            bindings: [.text(now), .text(now), .text(id)]
        )
    }

    func unarchiveProject(id: String) throws {
        let now = TimeFormats.iso8601String(from: Date())
        try execute(
            """
            UPDATE projects
            SET is_archived = 0, archived_at = NULL, updated_at = ?
            WHERE id = ?
            """,
            bindings: [.text(now), .text(id)]
        )
    }

    func deleteProject(id: String) throws {
        try execute("DELETE FROM log_entries_fts WHERE project_id = ?", bindings: [.text(id)])
        try execute("DELETE FROM text_tabs_fts WHERE project_id = ?", bindings: [.text(id)])
        try execute("DELETE FROM projects WHERE id = ?", bindings: [.text(id)])
    }

    func renameProject(id: String, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let now = TimeFormats.iso8601String(from: Date())
        try execute(
            """
            UPDATE projects
            SET title = ?, updated_at = ?
            WHERE id = ?
            """,
            bindings: [.text(trimmed), .text(now), .text(id)]
        )
    }

    func fetchProject(id: String) throws -> Project {
        let projects = try query(
            """
            SELECT id, title, is_archived, created_at, updated_at, archived_at
            FROM projects
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.text(id)]
        ) { statement in
            Project(
                id: statement.text(at: 0),
                title: statement.text(at: 1),
                isArchived: statement.int(at: 2) == 1,
                createdAt: statement.date(at: 3),
                updatedAt: statement.date(at: 4),
                archivedAt: statement.optionalDate(at: 5)
            )
        }

        guard let project = projects.first else { throw DatabaseError.missingRow }
        return project
    }

    func fetchMainTab(projectID: String) throws -> TabItem? {
        let tabs = try query(
            """
            SELECT id, project_id, kind, title, sort_index, body
            FROM tabs
            WHERE project_id = ? AND kind = 'main_log'
            LIMIT 1
            """,
            bindings: [.text(projectID)]
        ) { statement in
            TabItem(
                id: statement.text(at: 0),
                projectID: statement.text(at: 1),
                kind: TabKind(rawValue: statement.text(at: 2)) ?? .mainLog,
                title: statement.text(at: 3),
                sortIndex: statement.int(at: 4),
                body: statement.text(at: 5)
            )
        }

        return tabs.first
    }

    func fetchTabs(projectID: String) throws -> [TabItem] {
        try query(
            """
            SELECT id, project_id, kind, title, sort_index, body
            FROM tabs
            WHERE project_id = ?
            ORDER BY sort_index ASC, created_at ASC
            """,
            bindings: [.text(projectID)]
        ) { statement in
            TabItem(
                id: statement.text(at: 0),
                projectID: statement.text(at: 1),
                kind: TabKind(rawValue: statement.text(at: 2)) ?? .text,
                title: statement.text(at: 3),
                sortIndex: statement.int(at: 4),
                body: statement.text(at: 5)
            )
        }
    }

    func createTextTab(projectID: String, title: String? = nil) throws -> TabItem {
        let maxSort = try queryValue(
            "SELECT COALESCE(MAX(sort_index), 0) FROM tabs WHERE project_id = ?",
            bindings: [.text(projectID)]
        )
        let now = Date()
        let timestamp = TimeFormats.iso8601String(from: now)
        let id = UUID().uuidString
        let resolvedTitle = try (title ?? nextDefaultTextTabTitle(projectID: projectID))
        try execute(
            """
            INSERT INTO tabs (id, project_id, kind, title, sort_index, body, created_at, updated_at)
            VALUES (?, ?, 'text', ?, ?, '', ?, ?)
            """,
            bindings: [.text(id), .text(projectID), .text(resolvedTitle), .int(maxSort + 1), .text(timestamp), .text(timestamp)]
        )
        return try fetchTab(id: id)
    }

    func renameTab(tabID: String, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let now = TimeFormats.iso8601String(from: Date())
        try execute(
            """
            UPDATE tabs
            SET title = ?, updated_at = ?
            WHERE id = ? AND kind = 'text'
            """,
            bindings: [.text(trimmed), .text(now), .text(tabID)]
        )
    }

    func deleteTab(tabID: String) throws {
        try execute("DELETE FROM text_tabs_fts WHERE tab_id = ?", bindings: [.text(tabID)])
        try execute("DELETE FROM tabs WHERE id = ? AND kind = 'text'", bindings: [.text(tabID)])
    }

    func updateTabOrder(projectID: String, orderedTabIDs: [String]) throws {
        for (index, tabID) in orderedTabIDs.enumerated() {
            try execute(
                """
                UPDATE tabs
                SET sort_index = ?, updated_at = ?
                WHERE id = ? AND project_id = ?
                """,
                bindings: [.int(index), .text(TimeFormats.iso8601String(from: Date())), .text(tabID), .text(projectID)]
            )
        }
    }

    func updateTabBody(tabID: String, body: String) throws {
        let now = TimeFormats.iso8601String(from: Date())
        try execute(
            """
            UPDATE tabs
            SET body = ?, updated_at = ?
            WHERE id = ? AND kind = 'text'
            """,
            bindings: [.text(body), .text(now), .text(tabID)]
        )
        try upsertTextTabSearchIndex(tabID: tabID)
    }

    func fetchTab(id: String) throws -> TabItem {
        let tabs = try query(
            """
            SELECT id, project_id, kind, title, sort_index, body
            FROM tabs
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.text(id)]
        ) { statement in
            TabItem(
                id: statement.text(at: 0),
                projectID: statement.text(at: 1),
                kind: TabKind(rawValue: statement.text(at: 2)) ?? .text,
                title: statement.text(at: 3),
                sortIndex: statement.int(at: 4),
                body: statement.text(at: 5)
            )
        }

        guard let tab = tabs.first else { throw DatabaseError.missingRow }
        return tab
    }

    func fetchEntries(projectID: String, tabID: String?) throws -> [LogEntry] {
        if let tabID {
            return try query(
                """
                SELECT id, project_id, tab_id, recorded_at, note_text, created_at, updated_at
                FROM log_entries
                WHERE project_id = ? AND tab_id = ?
                ORDER BY recorded_at ASC, created_at ASC
                """,
                bindings: [.text(projectID), .text(tabID)]
            ) { statement in
                LogEntry(
                    id: statement.text(at: 0),
                    projectID: statement.text(at: 1),
                    tabID: statement.text(at: 2),
                    recordedAt: statement.date(at: 3),
                    noteText: statement.text(at: 4),
                    createdAt: statement.date(at: 5),
                    updatedAt: statement.date(at: 6)
                )
            }
        }

        return []
    }

    func fetchAttachments(projectID: String) throws -> [AttachmentItem] {
        try query(
            """
            SELECT id, project_id, file_name, relative_path, kind, file_size, created_at, updated_at
            FROM attachments
            WHERE project_id = ?
            ORDER BY created_at DESC
            """,
            bindings: [.text(projectID)]
        ) { statement in
            AttachmentItem(
                id: statement.text(at: 0),
                projectID: statement.text(at: 1),
                fileName: statement.text(at: 2),
                relativePath: statement.text(at: 3),
                kind: AttachmentKind(rawValue: statement.text(at: 4)) ?? .video,
                fileSize: statement.int64(at: 5),
                createdAt: statement.date(at: 6),
                updatedAt: statement.date(at: 7)
            )
        }
    }

    func insertAttachment(
        projectID: String,
        fileName: String,
        relativePath: String,
        kind: AttachmentKind,
        fileSize: Int64
    ) throws {
        let now = TimeFormats.iso8601String(from: Date())
        try execute(
            """
            INSERT INTO attachments (id, project_id, file_name, relative_path, kind, file_size, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(UUID().uuidString),
                .text(projectID),
                .text(fileName),
                .text(relativePath),
                .text(kind.rawValue),
                .int64(fileSize),
                .text(now),
                .text(now),
            ]
        )
    }

    func deleteAttachment(id: String) throws {
        try execute("DELETE FROM attachments WHERE id = ?", bindings: [.text(id)])
    }

    func insertLogEntry(projectID: String, tabID: String, recordedAt: Date, noteText: String) throws {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let id = UUID().uuidString
        let now = TimeFormats.iso8601String(from: Date())
        try execute(
            """
            INSERT INTO log_entries (id, project_id, tab_id, recorded_at, note_text, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(id),
                .text(projectID),
                .text(tabID),
                .text(TimeFormats.iso8601String(from: recordedAt)),
                .text(trimmed),
                .text(now),
                .text(now),
            ]
        )
        try execute(
            """
            INSERT INTO log_entries_fts (entry_id, project_id, tab_id, note_text)
            VALUES (?, ?, ?, ?)
            """,
            bindings: [.text(id), .text(projectID), .text(tabID), .text(trimmed)]
        )
    }

    func updateLogEntry(id: String, recordedAt: Date, noteText: String) throws {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DatabaseError.executeFailed("记录内容不能为空。")
        }

        let now = TimeFormats.iso8601String(from: Date())
        try execute(
            """
            UPDATE log_entries
            SET recorded_at = ?, note_text = ?, updated_at = ?
            WHERE id = ?
            """,
            bindings: [
                .text(TimeFormats.iso8601String(from: recordedAt)),
                .text(trimmed),
                .text(now),
                .text(id),
            ]
        )
        try execute("DELETE FROM log_entries_fts WHERE entry_id = ?", bindings: [.text(id)])
        let rows = try query(
            """
            SELECT project_id, tab_id, note_text
            FROM log_entries
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.text(id)]
        ) { statement in
            (
                projectID: statement.text(at: 0),
                tabID: statement.text(at: 1),
                noteText: statement.text(at: 2)
            )
        }
        if let row = rows.first {
            try execute(
                """
                INSERT INTO log_entries_fts (entry_id, project_id, tab_id, note_text)
                VALUES (?, ?, ?, ?)
                """,
                bindings: [.text(id), .text(row.projectID), .text(row.tabID), .text(row.noteText)]
            )
        }
    }

    func search(query rawQuery: String) throws -> [SearchResult] {
        let normalizedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.isEmpty == false else { return [] }

        let pattern = likePattern(for: normalizedQuery)
        let fullTextPattern = ftsPattern(for: normalizedQuery)
        guard fullTextPattern.isEmpty == false || normalizedQuery.isEmpty == false else { return [] }
        var results: [SearchResult] = []

        let projectResults = try query(
            """
            SELECT id, title, updated_at, is_archived
            FROM projects
            WHERE title LIKE ? ESCAPE '\\'
            ORDER BY updated_at DESC
            LIMIT 30
            """,
            bindings: [.text(pattern)]
        ) { statement in
            let isArchived = statement.int(at: 3) == 1
            return SearchResult(
                id: "project-\(statement.text(at: 0))",
                kind: .project,
                projectID: statement.text(at: 0),
                tabID: nil,
                entryID: nil,
                attachmentID: nil,
                primaryText: statement.text(at: 1),
                secondaryText: isArchived ? "项目标题 · 已归档" : "项目标题",
                snippet: makeSnippet(from: statement.text(at: 1), query: normalizedQuery),
                updatedAt: statement.date(at: 2)
            )
        }
        results.append(contentsOf: projectResults)

        let tabTitleResults = try query(
            """
            SELECT t.id, t.project_id, t.title, p.title, t.updated_at, p.is_archived
            FROM tabs t
            JOIN projects p ON p.id = t.project_id
            WHERE t.title LIKE ? ESCAPE '\\'
            ORDER BY t.updated_at DESC
            LIMIT 30
            """,
            bindings: [.text(pattern)]
        ) { statement in
            let projectDescriptor = statement.int(at: 5) == 1
                ? "\(statement.text(at: 3)) · 标签标题 · 已归档"
                : "\(statement.text(at: 3)) · 标签标题"
            return SearchResult(
                id: "tab-title-\(statement.text(at: 0))",
                kind: .tabTitle,
                projectID: statement.text(at: 1),
                tabID: statement.text(at: 0),
                entryID: nil,
                attachmentID: nil,
                primaryText: statement.text(at: 2),
                secondaryText: projectDescriptor,
                snippet: makeSnippet(from: statement.text(at: 2), query: normalizedQuery),
                updatedAt: statement.date(at: 4)
            )
        }
        results.append(contentsOf: tabTitleResults)

        let tabBodyResults: [SearchResult] = if fullTextPattern.isEmpty {
            []
        } else {
            try query(
                """
                SELECT t.id, t.project_id, t.title, t.body, p.title, t.updated_at, p.is_archived
                FROM text_tabs_fts f
                JOIN tabs t ON t.id = f.tab_id
                JOIN projects p ON p.id = t.project_id
                WHERE f.body MATCH ?
                ORDER BY t.updated_at DESC
                LIMIT 40
                """,
                bindings: [.text(fullTextPattern)]
            ) { statement in
                let projectDescriptor = statement.int(at: 6) == 1
                    ? "\(statement.text(at: 4)) · 文本标签 · 已归档"
                    : "\(statement.text(at: 4)) · 文本标签"
                return SearchResult(
                    id: "tab-body-\(statement.text(at: 0))",
                    kind: .tabBody,
                    projectID: statement.text(at: 1),
                    tabID: statement.text(at: 0),
                    entryID: nil,
                    attachmentID: nil,
                    primaryText: statement.text(at: 2),
                    secondaryText: projectDescriptor,
                    snippet: makeSnippet(from: statement.text(at: 3), query: normalizedQuery),
                    updatedAt: statement.date(at: 5)
                )
            }
        }
        results.append(contentsOf: tabBodyResults)

        let logResults: [SearchResult] = if fullTextPattern.isEmpty {
            []
        } else {
            try query(
                """
                SELECT e.id, e.project_id, e.tab_id, e.note_text, p.title, t.title, e.updated_at, e.recorded_at, p.is_archived
                FROM log_entries_fts f
                JOIN log_entries e ON e.id = f.entry_id
                JOIN projects p ON p.id = e.project_id
                JOIN tabs t ON t.id = e.tab_id
                WHERE f.note_text MATCH ?
                ORDER BY e.updated_at DESC
                LIMIT 80
                """,
                bindings: [.text(fullTextPattern)]
            ) { statement in
                let note = statement.text(at: 3)
                let recordedAt = statement.date(at: 7)
                let projectDescriptor = statement.int(at: 8) == 1
                    ? "\(statement.text(at: 4)) · \(statement.text(at: 5)) · 已归档"
                    : "\(statement.text(at: 4)) · \(statement.text(at: 5))"
                return SearchResult(
                    id: "entry-\(statement.text(at: 0))",
                    kind: .logEntry,
                    projectID: statement.text(at: 1),
                    tabID: statement.text(at: 2),
                    entryID: statement.text(at: 0),
                    attachmentID: nil,
                    primaryText: "\(TimeFormats.clockString(from: recordedAt)) \(note)",
                    secondaryText: projectDescriptor,
                    snippet: makeSnippet(from: note, query: normalizedQuery),
                    updatedAt: statement.date(at: 6)
                )
            }
        }
        results.append(contentsOf: logResults)

        let attachmentResults = try query(
            """
            SELECT a.id, a.project_id, a.file_name, p.title, a.updated_at, p.is_archived, a.kind
            FROM attachments a
            JOIN projects p ON p.id = a.project_id
            WHERE a.file_name LIKE ? ESCAPE '\\'
            ORDER BY a.updated_at DESC
            LIMIT 40
            """,
            bindings: [.text(pattern)]
        ) { statement in
            let projectDescriptor = statement.int(at: 5) == 1
                ? "\(statement.text(at: 3)) · \(attachmentKindLabel(rawValue: statement.text(at: 6))) · 已归档"
                : "\(statement.text(at: 3)) · \(attachmentKindLabel(rawValue: statement.text(at: 6)))"
            return SearchResult(
                id: "attachment-\(statement.text(at: 0))",
                kind: .attachment,
                projectID: statement.text(at: 1),
                tabID: nil,
                entryID: nil,
                attachmentID: statement.text(at: 0),
                primaryText: statement.text(at: 2),
                secondaryText: projectDescriptor,
                snippet: makeSnippet(from: statement.text(at: 2), query: normalizedQuery),
                updatedAt: statement.date(at: 4)
            )
        }
        results.append(contentsOf: attachmentResults)

        return results
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.primaryText < rhs.primaryText
            }
            .prefix(120)
            .map { $0 }
    }

    private func insertMainTab(projectID: String, now: Date) throws {
        let timestamp = TimeFormats.iso8601String(from: now)
        try execute(
            """
            INSERT INTO tabs (id, project_id, kind, title, sort_index, body, created_at, updated_at)
            VALUES (?, ?, 'main_log', '主场记', 0, '', ?, ?)
            """,
            bindings: [.text(UUID().uuidString), .text(projectID), .text(timestamp), .text(timestamp)]
        )
    }

    private func runMigrations() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS projects (
              id TEXT PRIMARY KEY NOT NULL,
              title TEXT NOT NULL,
              is_archived INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              archived_at TEXT
            );
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS tabs (
              id TEXT PRIMARY KEY NOT NULL,
              project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
              kind TEXT NOT NULL,
              title TEXT NOT NULL,
              sort_index INTEGER NOT NULL,
              body TEXT NOT NULL DEFAULT '',
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS log_entries (
              id TEXT PRIMARY KEY NOT NULL,
              project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
              tab_id TEXT NOT NULL REFERENCES tabs(id) ON DELETE CASCADE,
              recorded_at TEXT NOT NULL,
              note_text TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS attachments (
              id TEXT PRIMARY KEY NOT NULL,
              project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
              file_name TEXT NOT NULL,
              relative_path TEXT NOT NULL,
              kind TEXT NOT NULL,
              file_size INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS app_meta (
              key TEXT PRIMARY KEY NOT NULL,
              value TEXT NOT NULL
            );
            """
        )

        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS log_entries_fts USING fts5(
              entry_id UNINDEXED,
              project_id UNINDEXED,
              tab_id UNINDEXED,
              note_text,
              tokenize = 'unicode61'
            );
            """
        )
        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS text_tabs_fts USING fts5(
              tab_id UNINDEXED,
              project_id UNINDEXED,
              body,
              tokenize = 'unicode61'
            );
            """
        )

        try execute("CREATE INDEX IF NOT EXISTS idx_projects_title ON projects(title);")
        try execute("CREATE INDEX IF NOT EXISTS idx_projects_updated_at ON projects(updated_at);")
        try execute("CREATE INDEX IF NOT EXISTS idx_tabs_project_sort ON tabs(project_id, sort_index);")
        try execute("CREATE INDEX IF NOT EXISTS idx_tabs_title ON tabs(title);")
        try execute("CREATE INDEX IF NOT EXISTS idx_log_entries_project_tab_time ON log_entries(project_id, tab_id, recorded_at);")
        try execute("CREATE INDEX IF NOT EXISTS idx_attachments_project_created ON attachments(project_id, created_at);")
        try execute("CREATE INDEX IF NOT EXISTS idx_attachments_file_name ON attachments(file_name);")

        let currentFullTextVersion = try stringValue(forMetaKey: "fts_schema_version")
        if currentFullTextVersion != Self.fullTextSchemaVersion {
            try rebuildFullTextIndexes()
            try setMetaValue(Self.fullTextSchemaVersion, for: "fts_schema_version")
        }
    }

    private func seedIfNeeded() throws {
        let count = try queryValue("SELECT COUNT(*) FROM projects")
        if count == 0 {
            _ = try createProject()
        }
    }

    private func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query<T>(
        _ sql: String,
        bindings: [SQLiteValue] = [],
        transform: (SQLiteStatement) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                rows.append(try transform(SQLiteStatement(raw: statement)))
                continue
            }
            if result == SQLITE_DONE {
                return rows
            }
            throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func queryValue(_ sql: String, bindings: [SQLiteValue] = []) throws -> Int {
        let rows: [Int] = try query(sql, bindings: bindings) { statement in
            statement.int(at: 0)
        }
        return rows.first ?? 0
    }

    private func nextDefaultTextTabTitle(projectID: String) throws -> String {
        let titles: [String] = try query(
            """
            SELECT title
            FROM tabs
            WHERE project_id = ? AND kind = 'text'
            """,
            bindings: [.text(projectID)]
        ) { statement in
            statement.text(at: 0)
        }
        let existingTitles = Set(titles)
        var index = 1
        while existingTitles.contains("标签 \(index)") {
            index += 1
        }
        return "标签 \(index)"
    }

    private func rebuildFullTextIndexes() throws {
        try execute("DELETE FROM log_entries_fts;")
        try execute(
            """
            INSERT INTO log_entries_fts (entry_id, project_id, tab_id, note_text)
            SELECT id, project_id, tab_id, note_text
            FROM log_entries
            WHERE note_text <> ''
            """
        )
        try execute("DELETE FROM text_tabs_fts;")
        try execute(
            """
            INSERT INTO text_tabs_fts (tab_id, project_id, body)
            SELECT id, project_id, body
            FROM tabs
            WHERE kind = 'text' AND body <> ''
            """
        )
    }

    private func upsertTextTabSearchIndex(tabID: String) throws {
        try execute("DELETE FROM text_tabs_fts WHERE tab_id = ?", bindings: [.text(tabID)])
        let rows = try query(
            """
            SELECT id, project_id, body
            FROM tabs
            WHERE id = ? AND kind = 'text' AND body <> ''
            LIMIT 1
            """,
            bindings: [.text(tabID)]
        ) { statement in
            (
                tabID: statement.text(at: 0),
                projectID: statement.text(at: 1),
                body: statement.text(at: 2)
            )
        }
        if let row = rows.first {
            try execute(
                """
                INSERT INTO text_tabs_fts (tab_id, project_id, body)
                VALUES (?, ?, ?)
                """,
                bindings: [.text(row.tabID), .text(row.projectID), .text(row.body)]
            )
        }
    }

    func performTransaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let value = try operation()
            try execute("COMMIT;")
            return value
        } catch {
            do {
                try execute("ROLLBACK;")
            } catch {
                throw DatabaseError.executeFailed("事务回滚失败：\(error.localizedDescription)")
            }
            throw error
        }
    }

    private func stringValue(forMetaKey key: String) throws -> String? {
        let rows: [String] = try query(
            """
            SELECT value
            FROM app_meta
            WHERE key = ?
            LIMIT 1
            """,
            bindings: [.text(key)]
        ) { statement in
            statement.text(at: 0)
        }
        return rows.first
    }

    private func setMetaValue(_ value: String, for key: String) throws {
        try execute(
            """
            INSERT INTO app_meta (key, value)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            bindings: [.text(key), .text(value)]
        )
    }

    private func lastBackupAt() throws -> Date? {
        guard let value = try stringValue(forMetaKey: "last_backup_at") else {
            return nil
        }
        return TimeFormats.iso8601Date(from: value)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        return statement!
    }

    private func bind(_ bindings: [SQLiteValue], to statement: OpaquePointer) throws {
        for (index, value) in bindings.enumerated() {
            let parameterIndex = Int32(index + 1)
            let result: Int32
            switch value {
            case .text(let string):
                result = sqlite3_bind_text(statement, parameterIndex, string, -1, SQLITE_TRANSIENT)
            case .int(let intValue):
                result = sqlite3_bind_int(statement, parameterIndex, Int32(intValue))
            case .int64(let intValue):
                result = sqlite3_bind_int64(statement, parameterIndex, sqlite3_int64(intValue))
            case .null:
                result = sqlite3_bind_null(statement, parameterIndex)
            }

            if result != SQLITE_OK {
                throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func likePattern(for query: String) -> String {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    private func ftsPattern(for query: String) -> String {
        let components = searchTerms(from: query)
        return components
            .map { term in
                let escaped = sanitizeFTSSearchTerm(term)
                guard escaped.isEmpty == false else { return nil }
                return "\"\(escaped)\""
            }
            .compactMap { $0 }
            .joined(separator: " AND ")
    }

    private func makeSnippet(from text: String, query: String, maxLength: Int = 80) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }

        let searchCandidates = searchTerms(from: query).sorted { lhs, rhs in
            lhs.count > rhs.count
        }
        let matchedRange = searchCandidates.compactMap { candidate in
            trimmed.range(of: candidate, options: [.caseInsensitive, .diacriticInsensitive])
        }.first ?? trimmed.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])

        guard let range = matchedRange else {
            if trimmed.count <= maxLength { return trimmed }
            let prefix = String(trimmed.prefix(maxLength))
            return prefix + "..."
        }

        let matchOffset = trimmed.distance(from: trimmed.startIndex, to: range.lowerBound)
        let lowerOffset = max(0, matchOffset - (maxLength / 2))
        let lowerBound = trimmed.index(trimmed.startIndex, offsetBy: lowerOffset)
        let upperBound = trimmed.index(
            lowerBound,
            offsetBy: min(maxLength, trimmed.distance(from: lowerBound, to: trimmed.endIndex))
        )
        var snippet = String(trimmed[lowerBound..<upperBound])

        if lowerBound > trimmed.startIndex {
            snippet = "..." + snippet
        }
        if upperBound < trimmed.endIndex {
            snippet += "..."
        }
        return snippet
    }

    private func searchTerms(from query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        let pattern = #""([^"]+)"|(\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [trimmed]
        }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let matches = regex.matches(in: trimmed, range: range)
        let terms = matches.compactMap { match -> String? in
            for captureIndex in 1..<match.numberOfRanges {
                let captureRange = match.range(at: captureIndex)
                guard captureRange.location != NSNotFound,
                      let stringRange = Range(captureRange, in: trimmed)
                else {
                    continue
                }
                let term = sanitizeFTSSearchTerm(String(trimmed[stringRange]))
                if term.isEmpty == false, isFTSOperator(term) == false {
                    return term
                }
            }
            return nil
        }

        if terms.isEmpty {
            return [trimmed]
        }

        if trimmed.contains(where: \.isWhitespace) == false, terms.count == 1 {
            return [trimmed]
        }

        return terms
    }

    private func sanitizeFTSSearchTerm(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.whitespaces.contains(scalar)
                || isCJKScalar(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isFTSOperator(_ term: String) -> Bool {
        switch term.uppercased() {
        case "AND", "OR", "NOT":
            return true
        default:
            return false
        }
    }

    private func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x3040...0x309F,
             0x30A0...0x30FF,
             0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    private func attachmentKindLabel(rawValue: String) -> String {
        AttachmentKind(rawValue: rawValue)?.label ?? "附件"
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteValue {
    case text(String)
    case int(Int)
    case int64(Int64)
    case null
}

struct SQLiteStatement {
    let raw: OpaquePointer

    func text(at index: Int32) -> String {
        guard let pointer = sqlite3_column_text(raw, index) else { return "" }
        return String(cString: pointer)
    }

    func int(at index: Int32) -> Int {
        Int(sqlite3_column_int(raw, index))
    }

    func int64(at index: Int32) -> Int64 {
        Int64(sqlite3_column_int64(raw, index))
    }

    func date(at index: Int32) -> Date {
        let value = text(at: index)
        return TimeFormats.iso8601Date(from: value) ?? .now
    }

    func optionalDate(at index: Int32) -> Date? {
        let value = text(at: index)
        guard value.isEmpty == false else { return nil }
        return TimeFormats.iso8601Date(from: value)
    }
}
