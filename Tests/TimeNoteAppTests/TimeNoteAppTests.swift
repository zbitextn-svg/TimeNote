import Foundation
import PDFKit
import SQLite3
import Testing
@testable import TimeNoteApp

@Test
func parseClockKeepsSameDay() throws {
    let original = try #require(TimeFormats.iso8601Date(from: "2026-04-16T11:22:33.000Z"))
    let parsed = try #require(TimeFormats.parseClock("08:09:10", relativeTo: original))
    #expect(TimeFormats.clockString(from: parsed) == "08:09:10")
}

@Test
func parseClockCrossesMidnightToNearestDay() throws {
    // 用本地时区构造 23:58:30，避免测试结果依赖运行机器的时区（原写法只在 UTC+8 下成立）
    let calendar = Calendar.current
    let original = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 16, hour: 23, minute: 58, second: 30)))
    let parsed = try #require(TimeFormats.parseClock("00:05:00", relativeTo: original))

    #expect(TimeFormats.clockString(from: parsed) == "00:05:00")
    #expect(calendar.component(.day, from: parsed) != calendar.component(.day, from: original))
}

@Test
func archivedProjectsCanBeFetchedAndRestored() throws {
    let database = try makeTestDatabase()
    let active = try database.createProject(title: "进行中项目")
    let archived = try database.createProject(title: "归档项目")

    try database.archiveProject(id: archived.id)

    let activeProjects = try database.fetchProjects()
    let archivedProjects = try database.fetchArchivedProjects()

    #expect(activeProjects.map(\.id).contains(active.id))
    #expect(activeProjects.map(\.id).contains(archived.id) == false)
    #expect(archivedProjects.map(\.id).contains(archived.id))
    #expect(archivedProjects.first(where: { $0.id == archived.id })?.archivedAt != nil)

    try database.unarchiveProject(id: archived.id)

    let restoredActiveProjects = try database.fetchProjects()
    let restoredArchivedProjects = try database.fetchArchivedProjects()

    #expect(restoredActiveProjects.map(\.id).contains(archived.id))
    #expect(restoredArchivedProjects.isEmpty)
}

@Test
func searchIncludesArchivedProjects() throws {
    let database = try makeTestDatabase()
    let archivedProject = try database.createProject(title: "带关键字的归档项目")
    let mainTab = try #require(try database.fetchMainTab(projectID: archivedProject.id))

    try database.insertLogEntry(
        projectID: archivedProject.id,
        tabID: mainTab.id,
        recordedAt: .now,
        noteText: "关键字场记"
    )
    try database.archiveProject(id: archivedProject.id)

    let results = try database.search(query: "关键字")

    #expect(results.contains(where: { $0.projectID == archivedProject.id }))
    #expect(results.contains(where: { $0.secondaryText.contains("已归档") }))
}

@Test
func newTextTabUsesFirstAvailableDefaultTitle() throws {
    let database = try makeTestDatabase()
    let project = try database.createProject(title: "标签命名项目")
    let first = try database.createTextTab(projectID: project.id)
    let second = try database.createTextTab(projectID: project.id)

    try database.deleteTab(tabID: first.id)
    let replacement = try database.createTextTab(projectID: project.id)

    #expect(second.title == "标签 2")
    #expect(replacement.title == "标签 1")
}

@MainActor
@Test
func attachmentFilesAreCopiedIntoProjectDirectory() throws {
    let sandboxRoot = try makeTemporaryDirectory()
    let sourceURL = sandboxRoot.appendingPathComponent("现场画面.png")
    try Data("image-bytes".utf8).write(to: sourceURL, options: .atomic)

    let service = AttachmentService(rootURL: sandboxRoot)
    let storedFile = try service.importFile(at: sourceURL, projectID: "project-1")
    let copiedURL = try service.attachmentURL(relativePath: storedFile.relativePath)

    #expect(storedFile.kind == .image)
    #expect(storedFile.fileName == "现场画面.png")
    #expect(FileManager.default.fileExists(atPath: copiedURL.path))
    #expect(copiedURL.path.contains("/attachments/project-1/"))
}

@MainActor
@Test
func duplicatedProjectKeepsAttachmentReferencesAndSearchFindsFileNames() throws {
    let database = try makeTestDatabase()
    let attachmentRoot = try makeTemporaryDirectory()
    let service = AttachmentService(rootURL: attachmentRoot)
    let project = try database.createProject(title: "带附件项目")
    let sourceURL = attachmentRoot.appendingPathComponent("拍摄现场.mov")
    try Data("video-bytes".utf8).write(to: sourceURL, options: .atomic)
    let originalFile = try service.importFile(at: sourceURL, projectID: project.id)
    try database.insertAttachment(
        projectID: project.id,
        fileName: originalFile.fileName,
        relativePath: originalFile.relativePath,
        kind: originalFile.kind,
        fileSize: originalFile.fileSize
    )

    let duplicate = try database.duplicateProject(id: project.id)
    let duplicatedFile = try service.duplicateAttachment(
        relativePath: originalFile.relativePath,
        originalFileName: originalFile.fileName,
        targetProjectID: duplicate.id
    )
    try database.insertAttachment(
        projectID: duplicate.id,
        fileName: duplicatedFile.fileName,
        relativePath: duplicatedFile.relativePath,
        kind: duplicatedFile.kind,
        fileSize: duplicatedFile.fileSize
    )
    let duplicateAttachments = try database.fetchAttachments(projectID: duplicate.id)
    let searchResults = try database.search(query: "现场.mov")

    #expect(duplicateAttachments.count == 1)
    #expect(duplicateAttachments.first?.fileName == "拍摄现场.mov")
    #expect(duplicateAttachments.first?.relativePath.contains("/\(duplicate.id)/") == true)
    #expect(searchResults.contains(where: { $0.kind == .attachment && $0.projectID == project.id }))
    #expect(searchResults.contains(where: { $0.kind == .attachment && $0.projectID == duplicate.id }))
}

@Test
func attachmentFileSizeUsesInt64() throws {
    let database = try makeTestDatabase()
    let project = try database.createProject(title: "大附件项目")
    let oversizedBytes = Int64(Int32.max) + 4_096

    try database.insertAttachment(
        projectID: project.id,
        fileName: "超大素材.mov",
        relativePath: "attachments/\(project.id)/oversized.mov",
        kind: .video,
        fileSize: oversizedBytes
    )

    let attachments = try database.fetchAttachments(projectID: project.id)
    #expect(attachments.first?.fileSize == oversizedBytes)
}

@Test
func corruptedDatabaseCanRestoreFromLatestBackup() throws {
    let databaseURL = try makeTestDatabaseURL()
    let projectTitle = "恢复前项目"

    do {
        let database = try SQLiteDatabase(path: databaseURL)
        _ = try database.createProject(title: projectTitle)
        let backupURL = try #require(try database.createBackupIfNeeded(force: true))
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
    }

    try Data("corrupted".utf8).write(to: databaseURL, options: .atomic)

    let recovery = try RecoveryService.prepareDatabaseForLaunch(at: databaseURL)
    guard case .restoredFromBackup(let backupFileName) = recovery else {
        Issue.record("Expected backup restoration, got \(String(describing: recovery))")
        return
    }

    #expect(backupFileName.contains("timenote-backup-"))

    let restoredDatabase = try SQLiteDatabase(path: databaseURL)
    let projects = try restoredDatabase.fetchProjects()
    #expect(projects.contains(where: { $0.title == projectTitle }))
}

private func makeTestDatabase() throws -> SQLiteDatabase {
    try SQLiteDatabase(path: makeTestDatabaseURL())
}

private func makeTestDatabaseURL() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent("timenote-test.sqlite")
}

/// 使用临时数据目录的 store，绝不读写真实的 ~/Library/Application Support/TimeNote
@MainActor
private func makeIsolatedStore() throws -> TimeNoteStore {
    TimeNoteStore(rootDirectory: try makeTemporaryDirectory())
}

private func makeTemporaryDirectory() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

// MARK: - Save Link Regression Tests (Bug Fix: Flush Pending Edits on Interrupt)

@MainActor
@Test
func test_selectProject_clearsEntryInputText() throws {
    let store = try makeIsolatedStore()
    store.createProject()
    let projectA = try #require(store.selectedProjectID)
    store.createProject()
    let projectB = try #require(store.selectedProjectID)
    defer {
        store.deleteProject(id: projectA)
        store.deleteProject(id: projectB)
    }

    // Simulate unsaved draft in the main log input field
    store.entryInputText = "未保存的草稿"

    // Switching project must clear the input draft to prevent cross-project leakage (P0-2)
    store.selectProject(id: projectA)
    #expect(store.entryInputText == "")
}

@MainActor
@Test
func test_selectProject_flushesPendingTextDraftsBeforeSwitch() throws {
    let store = try makeIsolatedStore()
    store.createProject()
    let projectA = try #require(store.selectedProjectID)
    let textTabA = try #require(store.addTextTab())
    store.updateCurrentTextTabBody("文本标签草稿 A")
    // Creating project B triggers selectProject → flushPendingTextDrafts (P0-2)
    store.createProject()
    let projectB = try #require(store.selectedProjectID)
    defer {
        store.deleteProject(id: projectA)
        store.deleteProject(id: projectB)
    }

    // Switch back to A and refresh tabs from DB to verify the draft was persisted
    store.selectProject(id: projectA)
    let savedTab = store.tabs.first(where: { $0.id == textTabA })
    #expect(savedTab?.body == "文本标签草稿 A")
}

@MainActor
@Test
func test_selectTab_flushesOldTabDraftBeforeSwitch() throws {
    let store = try makeIsolatedStore()
    store.createProject()
    let projectID = try #require(store.selectedProjectID)
    defer { store.deleteProject(id: projectID) }

    let tabA = try #require(store.addTextTab())
    let tabB = try #require(store.addTextTab())

    // Switch to A, edit, switch to B — selectTab must flush A's draft (P0-3)
    store.selectTab(id: tabA)
    store.updateCurrentTextTabBody("标签 A 草稿")
    store.selectTab(id: tabB)

    // Refresh tabs from DB to verify persistence
    store.selectProject(id: projectID)
    let savedTabA = store.tabs.first(where: { $0.id == tabA })
    #expect(savedTabA?.body == "标签 A 草稿")
}

@MainActor
@Test
func test_flushTextTabDraft_synchronizesWriteAndClearsDraft() throws {
    let store = try makeIsolatedStore()
    store.createProject()
    let projectID = try #require(store.selectedProjectID)
    defer { store.deleteProject(id: projectID) }

    let tabA = try #require(store.addTextTab())
    let tabB = try #require(store.addTextTab())

    // Edit tab A, then switch to B — flushTextTabDraft must write synchronously + clear draft
    store.selectTab(id: tabA)
    store.updateCurrentTextTabBody("同步写入内容")
    store.selectTab(id: tabB)

    // Refresh tabs from DB, then switch back to A
    store.selectProject(id: projectID)
    store.selectTab(id: tabA)

    // Draft was cleared; body must come from DB (not a stale in-memory draft)
    #expect(store.currentTextTabBody == "同步写入内容")
    let savedTab = store.tabs.first(where: { $0.id == tabA })
    #expect(savedTab?.body == "同步写入内容")
}

@MainActor
@Test
func test_flushAllPendingEdits_isIdempotent() throws {
    let store = try makeIsolatedStore()
    store.createProject()
    let projectID = try #require(store.selectedProjectID)
    let tabID = try #require(store.addTextTab())
    defer { store.deleteProject(id: projectID) }

    store.updateCurrentTextTabBody("幂等测试内容")

    // Calling flushAllPendingEdits twice must not crash or set transientError (P0-1 idempotency)
    store.flushAllPendingEdits()
    store.flushAllPendingEdits()
    #expect(store.transientError == nil)

    // Verify content was persisted to DB
    store.selectProject(id: projectID)
    let savedTab = store.tabs.first(where: { $0.id == tabID })
    #expect(savedTab?.body == "幂等测试内容")
}

@MainActor
@Test
func test_flushPendingProjectRename_supportsExplicitProjectID() throws {
    let store = try makeIsolatedStore()
    store.createProject()
    let projectA = try #require(store.selectedProjectID)
    store.createProject()
    let projectB = try #require(store.selectedProjectID)
    defer {
        store.deleteProject(id: projectA)
        store.deleteProject(id: projectB)
    }

    // Rename project A by explicit ID while project B is the selected project.
    // This validates the foundation of flushPendingProjectRename(projectID:) (P0-4)
    store.renameProject(id: projectA, title: "显式重命名 A")

    let renamedProjectA = store.projects.first(where: { $0.id == projectA })
    #expect(renamedProjectA?.title == "显式重命名 A")

    // The currently selected project B must not be affected
    let selectedProjectB = store.projects.first(where: { $0.id == projectB })
    #expect(selectedProjectB?.title != "显式重命名 A")
}

@MainActor
@Test
func test_rapidTabSwitching_preservesAllDrafts() throws {
    let store = try makeIsolatedStore()
    store.createProject()
    let projectID = try #require(store.selectedProjectID)
    defer { store.deleteProject(id: projectID) }

    let tabA = try #require(store.addTextTab())
    let tabB = try #require(store.addTextTab())

    // Rapid switching A→B→A→B with edits each time (Scenario 2)
    store.selectTab(id: tabA)
    store.updateCurrentTextTabBody("A-1")
    store.selectTab(id: tabB)
    store.updateCurrentTextTabBody("B-1")
    store.selectTab(id: tabA)
    store.updateCurrentTextTabBody("A-2")
    store.selectTab(id: tabB)
    store.updateCurrentTextTabBody("B-2")

    // Flush remaining draft on tab B
    store.flushAllPendingEdits()

    // Refresh tabs from DB and verify both tabs have their latest content
    store.selectProject(id: projectID)
    let savedTabA = store.tabs.first(where: { $0.id == tabA })
    let savedTabB = store.tabs.first(where: { $0.id == tabB })
    #expect(savedTabA?.body == "A-2")
    #expect(savedTabB?.body == "B-2")
}


// MARK: - v22 回归测试

@Test
func searchFindsChineseSubstringsInLogEntriesAndTextTabs() throws {
    let database = try makeTestDatabase()
    let project = try database.createProject(title: "外景")
    let mainTab = try #require(try database.fetchMainTab(projectID: project.id))
    try database.insertLogEntry(projectID: project.id, tabID: mainTab.id, recordedAt: .now, noteText: "24-2-1 演员抢词，重来")
    let textTab = try database.createTextTab(projectID: project.id, title: "备忘")
    try database.updateTabBody(tabID: textTab.id, body: "明天需要准备道具自行车")

    // FTS5 unicode61 会把连续汉字当成整词，旧实现搜不到这些子串
    let entryResults = try database.search(query: "演员")
    #expect(entryResults.contains(where: { $0.kind == .logEntry }))

    let bodyResults = try database.search(query: "自行车")
    #expect(bodyResults.contains(where: { $0.kind == .tabBody && $0.tabID == textTab.id }))

    // 多关键词为"且"关系
    #expect(try database.search(query: "24-2 抢词").contains(where: { $0.kind == .logEntry }))
    #expect(try database.search(query: "24-2 不存在").contains(where: { $0.kind == .logEntry }) == false)

    // LIKE 通配符需要被转义
    #expect(try database.search(query: "%").isEmpty)
}

@Test
func nestedTransactionsUseSavepoints() throws {
    let database = try makeTestDatabase()
    // duplicateProject 内部会再调用 createProject / insertLogEntry 等自带事务的方法
    let project = try database.createProject(title: "嵌套事务")
    let mainTab = try #require(try database.fetchMainTab(projectID: project.id))
    try database.insertLogEntry(projectID: project.id, tabID: mainTab.id, recordedAt: .now, noteText: "第一条")

    let copy = try database.performTransaction {
        try database.duplicateProject(id: project.id)
    }
    let copiedTab = try #require(try database.fetchMainTab(projectID: copy.id))
    #expect(try database.fetchEntries(projectID: copy.id, tabID: copiedTab.id).count == 1)

    // 内层失败只回滚内层
    struct Boom: Error {}
    try database.performTransaction {
        _ = try? database.performTransaction { () throws -> Void in
            try database.insertLogEntry(projectID: project.id, tabID: mainTab.id, recordedAt: .now, noteText: "会被回滚")
            throw Boom()
        }
        try database.insertLogEntry(projectID: project.id, tabID: mainTab.id, recordedAt: .now, noteText: "保留")
    }
    let notes = try database.fetchEntries(projectID: project.id, tabID: mainTab.id).map(\.noteText)
    #expect(notes.contains("保留"))
    #expect(notes.contains("会被回滚") == false)
}

@Test
func deletedLogEntryCanBeRestoredWithOriginalTime() throws {
    let database = try makeTestDatabase()
    let project = try database.createProject(title: "删除恢复")
    let mainTab = try #require(try database.fetchMainTab(projectID: project.id))
    let recordedAt = try #require(TimeFormats.iso8601Date(from: "2026-04-16T08:09:10.000Z"))
    let entry = try #require(try database.insertLogEntry(projectID: project.id, tabID: mainTab.id, recordedAt: recordedAt, noteText: "要删的"))

    try database.deleteLogEntry(id: entry.id)
    #expect(try database.fetchEntry(id: entry.id) == nil)
    #expect(try database.search(query: "要删的").isEmpty)

    try database.restoreLogEntry(entry)
    let restored = try #require(try database.fetchEntry(id: entry.id))
    #expect(restored.recordedAt == recordedAt)
    #expect(restored.noteText == "要删的")
}

@Test
func entryStatsCountPerProject() throws {
    let database = try makeTestDatabase()
    let project = try database.createProject(title: "统计")
    let mainTab = try #require(try database.fetchMainTab(projectID: project.id))
    try database.insertLogEntry(projectID: project.id, tabID: mainTab.id, recordedAt: .now, noteText: "一")
    try database.insertLogEntry(projectID: project.id, tabID: mainTab.id, recordedAt: .now, noteText: "二")

    let stats = try database.fetchEntryStats()
    #expect(stats[project.id]?.entryCount == 2)
    #expect(stats[project.id]?.lastRecordedAt != nil)
}

@Test
func integrityCheckDoesNotQuarantineHealthyDatabase() throws {
    let databaseURL = try makeTestDatabaseURL()
    let database = try SQLiteDatabase(path: databaseURL)
    _ = try database.createProject(title: "健康的数据库")

    #expect(RecoveryService.checkIntegrity(at: databaseURL) == .ok)
    #expect(try RecoveryService.prepareDatabaseForLaunch(at: databaseURL) == nil)
    #expect(FileManager.default.fileExists(atPath: databaseURL.path))
}

@Test
func exportAddsDayHeadersOnlyWhenEntriesSpanMultipleDays() throws {
    let service = ExportService()
    let day1 = try #require(TimeFormats.iso8601Date(from: "2026-04-16T04:00:00.000Z"))
    let day2 = day1.addingTimeInterval(24 * 60 * 60)
    func entry(_ date: Date, _ text: String) -> LogEntry {
        LogEntry(id: UUID().uuidString, projectID: "p", tabID: "t", recordedAt: date, noteText: text, createdAt: date, updatedAt: date)
    }

    let singleDay = service.logLines(for: [entry(day1, "A"), entry(day1.addingTimeInterval(60), "B")])
    #expect(singleDay.count == 2)
    #expect(singleDay.allSatisfy { $0.hasPrefix("——") == false })

    let multiDay = service.logLines(for: [entry(day2, "C"), entry(day1, "A")])
    #expect(multiDay.first?.hasPrefix("——") == true)
    #expect(multiDay.contains { $0.hasSuffix(" A") })
    #expect(multiDay.firstIndex { $0.hasSuffix(" A") }! < multiDay.firstIndex { $0.hasSuffix(" C") }!)
}

@MainActor
@Test
func submittedEntryUsesTimeWhenTypingStarted() throws {
    let store = try makeIsolatedStore()
    store.createProject()

    store.entryInputText = "开始打字"
    let lockedAt = try #require(store.pendingEntryStartedAt)
    store.entryInputText = "开始打字，继续输入了很久"
    #expect(store.pendingEntryStartedAt == lockedAt)

    store.submitMainLogEntry()
    #expect(store.pendingEntryStartedAt == nil)
    let saved = try #require(store.entries.last)
    #expect(abs(saved.recordedAt.timeIntervalSince(lockedAt)) < 0.001)

    store.entryInputText = "临时"
    #expect(store.pendingEntryStartedAt != nil)
    store.entryInputText = ""
    #expect(store.pendingEntryStartedAt == nil)
}

@MainActor
@Test
func deleteEntryCanBeUndoneFromToast() throws {
    let store = try makeIsolatedStore()
    store.createProject()
    store.entryInputText = "误记的一条"
    store.submitMainLogEntry()
    let entryID = try #require(store.entries.first?.id)

    store.deleteEntry(entryID)
    #expect(store.entries.isEmpty)
    #expect(store.toast?.actionTitle == "撤销")

    store.performToastAction()
    #expect(store.entries.map(\.id) == [entryID])
}

@MainActor
@Test
func updateEntrySavesEvenAfterSwitchingProject() throws {
    let store = try makeIsolatedStore()
    store.createProject()
    let projectA = try #require(store.selectedProjectID)
    store.entryInputText = "原始内容"
    store.submitMainLogEntry()
    let entry = try #require(store.entries.first)

    // 模拟：编辑中途切到另一个项目，行视图在消失时才提交保存
    store.createProject()
    #expect(store.selectedProjectID != projectA)
    store.updateEntry(entry.id, timeText: TimeFormats.clockString(from: entry.recordedAt), noteText: "修改后的内容")

    store.selectProject(id: projectA)
    #expect(store.entries.first?.noteText == "修改后的内容")
}

// MARK: - V1.1.23 回归测试

/// Bug2：自动保存完成后，切到主场记再切回来，编辑器显示的必须是已保存的内容（以前会变成空白）
@MainActor
@Test
func textTabShowsAutosavedBodyAfterSwitchingTabs() async throws {
    let store = try makeIsolatedStore()
    store.createProject()
    let mainTabID = try #require(store.tabs.first(where: { $0.kind == .mainLog })?.id)
    let textTabID = try #require(store.addTextTab())

    store.updateCurrentTextTabBody("对本会：第 3 场改词")
    #expect(store.currentTextTabIsSaving)

    // 等自动保存（350ms 防抖）完成
    try await Task.sleep(for: .milliseconds(900))
    #expect(store.currentTextTabIsSaving == false)
    #expect(store.currentTextTabLastSavedAt != nil)

    // 不刷新项目，直接切走再切回来
    store.selectTab(id: mainTabID)
    store.selectTab(id: textTabID)
    #expect(store.currentTextTabBody == "对本会：第 3 场改词")
    #expect(store.selectedTab?.body == "对本会：第 3 场改词")

    // 重新选中同一个标签（双击重命名时会这样做）也不能清空内容
    store.selectTab(id: textTabID)
    #expect(store.currentTextTabBody == "对本会：第 3 场改词")
}

/// Bug1：结束重命名时不能把选中状态强行改回被重命名的标签
@MainActor
@Test
func renamingTabDoesNotStealSelection() throws {
    let store = try makeIsolatedStore()
    store.createProject()
    let mainTabID = try #require(store.tabs.first(where: { $0.kind == .mainLog })?.id)
    let textTabID = try #require(store.addTextTab())

    // 用户点了主场记，随后输入框失焦触发重命名提交
    store.selectTab(id: mainTabID)
    store.renameTab(tabID: textTabID, title: "对本会")

    #expect(store.selectedTabID == mainTabID)
    #expect(store.tabs.first(where: { $0.id == textTabID })?.title == "对本会")
}

@Test
func packageScriptVersionMatchesAppVersion() throws {
    let scriptURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/package_app.sh")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)
    #expect(script.contains("APP_VERSION=\"${APP_VERSION:-\(AppInfo.version)}\""))
    // 录音转写依赖 macOS 26，安装包的最低系统版本要一致
    #expect(script.contains("<string>26.0</string>"))
    #expect(script.contains("NSMicrophoneUsageDescription"))
}

// MARK: - 标签删除按钮

@MainActor
@Test
func textTabContentCheckDecidesWhetherDeleteNeedsConfirmation() throws {
    let store = try makeIsolatedStore()
    store.createProject()
    let emptyTab = try #require(store.addTextTab())
    #expect(store.textTabHasContent(emptyTab) == false)

    let filledTab = try #require(store.addTextTab())
    // 尚未自动保存的草稿也算有内容
    store.updateCurrentTextTabBody("镜头 3 要补拍")
    #expect(store.textTabHasContent(filledTab))

    // 只有空白字符算空
    let blankTab = try #require(store.addTextTab())
    store.updateCurrentTextTabBody("  \n ")
    #expect(store.textTabHasContent(blankTab) == false)
}

@MainActor
@Test
func deletingSelectedTextTabFallsBackToMainLog() throws {
    let store = try makeIsolatedStore()
    store.createProject()
    let mainTabID = try #require(store.tabs.first(where: { $0.kind == .mainLog })?.id)
    let textTabID = try #require(store.addTextTab())
    #expect(store.selectedTabID == textTabID)

    store.deleteTab(tabID: textTabID)

    #expect(store.tabs.contains(where: { $0.id == textTabID }) == false)
    #expect(store.selectedTabID == mainTabID)
    // 主场记不能被删除
    store.deleteTab(tabID: mainTabID)
    #expect(store.tabs.contains(where: { $0.id == mainTabID }))
}

// MARK: - 录音与转写（V1.2）

@Test
func olderDatabaseGainsRecordingTablesWithoutLosingData() throws {
    let url = try makeTestDatabaseURL()
    var projectID = ""
    do {
        let database = try SQLiteDatabase(path: url)
        let project = try database.createProject(title: "老项目")
        projectID = project.id
        let mainTab = try #require(try database.fetchMainTab(projectID: project.id))
        try database.insertLogEntry(projectID: project.id, tabID: mainTab.id, recordedAt: .now, noteText: "旧版本的场记")
    }
    // 模拟 V1.1.23 的数据库：没有录音相关的表
    var handle: OpaquePointer?
    #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
    #expect(sqlite3_exec(handle, "DROP TABLE transcript_segments; DROP TABLE recordings;", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(handle)

    let upgraded = try SQLiteDatabase(path: url)
    let mainTab = try #require(try upgraded.fetchMainTab(projectID: projectID))
    #expect(try upgraded.fetchEntries(projectID: projectID, tabID: mainTab.id).map(\.noteText) == ["旧版本的场记"])
    #expect(try upgraded.fetchRecordings(projectID: projectID).isEmpty)
    let recording = try upgraded.insertRecording(projectID: projectID, title: "录音 1", relativePath: "a.caf", startedAt: .now, locale: "zh-CN")
    #expect(try upgraded.fetchRecording(id: recording.id)?.status == .recording)
}

@Test
func recordingLifecycleAndTranscriptSearch() throws {
    let database = try makeTestDatabase()
    let project = try database.createProject(title: "访谈录制")
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let recording = try database.insertRecording(
        projectID: project.id,
        title: "录音 1",
        relativePath: "attachments/\(project.id)/recordings/x.caf",
        startedAt: startedAt,
        locale: "zh-CN"
    )
    try database.insertTranscriptSegment(recordingID: recording.id, projectID: project.id, startMs: 65_000, endMs: 68_500, text: "嘉宾说到了第一次登台的经历")
    try database.insertTranscriptSegment(recordingID: recording.id, projectID: project.id, startMs: 3_000, endMs: 4_000, text: "  ")
    try database.insertTranscriptSegment(recordingID: recording.id, projectID: project.id, startMs: 1_000, endMs: 2_000, text: "开始")

    // 空白句子不保存，结果按时间排序
    #expect(try database.fetchTranscriptSegments(recordingID: recording.id).map(\.text) == ["开始", "嘉宾说到了第一次登台的经历"])
    #expect(try database.fetchUnfinishedRecordings().map(\.id) == [recording.id])

    try database.finishRecording(id: recording.id, relativePath: "attachments/\(project.id)/recordings/x.m4a", durationMs: 120_000, fileSize: 2048, status: .finished)
    let finished = try #require(try database.fetchRecording(id: recording.id))
    #expect(finished.status == .finished)
    #expect(finished.duration == 120)
    #expect(finished.relativePath.hasSuffix(".m4a"))
    #expect(try database.fetchUnfinishedRecordings().isEmpty)

    let results = try database.search(query: "登台")
    let hit = try #require(results.first(where: { $0.kind == .transcript }))
    #expect(hit.recordingID == recording.id)
    #expect(hit.recordingOffsetMs == 65_000)
    #expect(hit.projectID == project.id)

    // 删除项目时录音与转写一并删除
    try database.deleteProject(id: project.id)
    #expect(try database.fetchRecording(id: recording.id) == nil)
    #expect(try database.fetchTranscriptSegments(recordingID: recording.id).isEmpty)
}

@Test
func recordingOffsetMapsLogEntriesIntoTheRecording() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var recording = Recording(
        id: "r", projectID: "p", title: "录音 1", relativePath: "", startedAt: start,
        durationMs: 600_000, fileSize: 0, locale: "zh-CN", status: .finished, createdAt: start, updatedAt: start
    )
    #expect(recording.offset(of: start.addingTimeInterval(192)) == 192)
    #expect(recording.offset(of: start.addingTimeInterval(-1)) == nil)
    #expect(recording.offset(of: start.addingTimeInterval(601)) == nil)
    // 录制中：区间截止到当前时刻
    recording.status = .recording
    #expect(recording.offset(of: start.addingTimeInterval(900), now: start.addingTimeInterval(1000)) == 900)
    #expect(DurationFormats.string(from: 192.7) == "03:12")
    #expect(DurationFormats.string(from: 3725) == "1:02:05")
}

// MARK: - Excel / PDF 场记单

private func makeSampleReport() -> ProjectReport {
    let day1 = Date(timeIntervalSince1970: 1_800_000_000)
    let day2 = day1.addingTimeInterval(86_400)
    let entries = [
        LogEntry(id: "1", projectID: "p", tabID: "t", recordedAt: day1, noteText: "第1场 第2镜 OK <好条> & 保", createdAt: day1, updatedAt: day1),
        LogEntry(id: "2", projectID: "p", tabID: "t", recordedAt: day1.addingTimeInterval(130), noteText: "演员忘词，NG", createdAt: day1, updatedAt: day1),
        LogEntry(id: "3", projectID: "p", tabID: "t", recordedAt: day2, noteText: "第二天开机\n换场景", createdAt: day2, updatedAt: day2),
    ]
    let recording = Recording(
        id: "r", projectID: "p", title: "录音 1", relativePath: "", startedAt: day1.addingTimeInterval(-60),
        durationMs: 600_000, fileSize: 0, locale: "zh-CN", status: .finished, createdAt: day1, updatedAt: day1
    )
    let segment = TranscriptSegment(id: "s", recordingID: "r", projectID: "p", startMs: 70_000, endMs: 72_000, text: "我们再来一条")
    return ProjectReport(
        projectTitle: "测试节目",
        exportedAt: day2,
        entries: entries,
        textSections: [.init(title: "镜头表", body: "1. 全景\n2. 近景")],
        recordings: [.init(recording: recording, segments: [segment])]
    )
}

@Test
func crc32MatchesReferenceValue() {
    #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
}

@Test
func xlsxSheetNamesAndColumnsAreValid() {
    #expect(XLSXReportWriter.columnName(0) == "A")
    #expect(XLSXReportWriter.columnName(25) == "Z")
    #expect(XLSXReportWriter.columnName(26) == "AA")
    let names = XLSXReportWriter.uniqueSheetNames(["场记", "场记", "a/b:c", String(repeating: "长", count: 40)])
    #expect(names[0] == "场记")
    #expect(names[1] == "场记 (2)")
    #expect(names[2] == "a b c")
    #expect(names[3].count == 31)
    #expect(XLSXReportWriter.escape("a<b>&\u{0007}\"") == "a&lt;b&gt;&amp;&quot;")
}

@Test
func xlsxExportIsAValidWorkbook() throws {
    let report = makeSampleReport()
    let sheets = XLSXReportWriter.sheets(for: report)
    #expect(sheets.map(\.name) == ["场记", "文本标签", "录音文字"])
    // 场记表：表头 + 3 条，落在录音里的条目带录音位置
    #expect(sheets[0].rows.count == 4)
    #expect(sheets[0].rows[0] == ["日期", "时间", "内容", "录音位置"])
    #expect(sheets[0].rows[1][3] == "录音 1 · 01:00")
    #expect(sheets[0].rows[3][3] == "")

    let directory = try makeTemporaryDirectory()
    let url = directory.appendingPathComponent("场记单.xlsx")
    try XLSXReportWriter.data(for: report).write(to: url)

    // 用系统 unzip 校验压缩包结构与 CRC
    #expect(try runProcess("/usr/bin/unzip", ["-tq", url.path]).status == 0)
    let sheetXML = try runProcess("/usr/bin/unzip", ["-p", url.path, "xl/worksheets/sheet1.xml"]).output
    #expect(sheetXML.contains("第1场 第2镜 OK &lt;好条&gt; &amp; 保"))
    let workbookXML = try runProcess("/usr/bin/unzip", ["-p", url.path, "xl/workbook.xml"]).output
    #expect(workbookXML.contains("录音文字"))
}

@MainActor
@Test
func pdfExportProducesReadablePages() throws {
    var report = makeSampleReport()
    let pdf = PDFReportWriter.data(for: report)
    let document = try #require(PDFDocument(data: pdf))
    #expect(document.pageCount >= 1)
    let text = document.string ?? ""
    #expect(text.contains("测试节目"))
    #expect(text.contains("演员忘词"))
    #expect(text.contains("镜头表"))
    // 录音文字附在场记单后面
    #expect(text.contains("录音文字"))
    #expect(text.contains("我们再来一条"))

    // 很多条场记时自动分页
    let base = report.entries[0]
    let many = (0..<400).map { index in
        LogEntry(id: "m\(index)", projectID: "p", tabID: "t", recordedAt: base.recordedAt.addingTimeInterval(Double(index)), noteText: "第 \(index) 条记录", createdAt: base.createdAt, updatedAt: base.updatedAt)
    }
    report = ProjectReport(projectTitle: report.projectTitle, exportedAt: report.exportedAt, entries: many, textSections: [], recordings: [])
    let longDocument = try #require(PDFDocument(data: PDFReportWriter.data(for: report)))
    #expect(longDocument.pageCount > 5)
    #expect(longDocument.page(at: longDocument.pageCount - 1)?.string?.contains("第 399 条记录") == true)
}

@MainActor
@Test
func storeBuildsReportWithEntriesTextTabsAndRecordings() throws {
    let store = try makeIsolatedStore()
    store.createProject()
    store.entryInputText = "开机"
    store.submitMainLogEntry()
    _ = store.addTextTab()
    store.updateCurrentTextTabBody("备注内容")
    let project = try #require(store.selectedProject)

    let report = try store.makeReport(for: project)
    #expect(report.entries.map(\.noteText) == ["开机"])
    #expect(report.textSections.map(\.body) == ["备注内容"])
    #expect(report.recordings.isEmpty)
}

private func runProcess(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

@MainActor
@Test
func packageExportContainsReportsTranscriptsAndAudio() throws {
    let report = makeSampleReport()
    let directory = try makeTemporaryDirectory()
    let audioURL = directory.appendingPathComponent("source.m4a")
    try Data("fake audio".utf8).write(to: audioURL)
    let service = ExportService()
    let names = ProjectPackageBuilder.baseNames(for: report.recordings.map(\.recording), sanitize: service.sanitizeFileName)
    let baseName = try #require(names["r"])
    #expect(baseName.hasPrefix("录音 1（"))
    #expect(baseName.contains(":") == false)

    let contents = ProjectPackageBuilder.Contents(
        folderName: "测试节目 场记资料",
        pdf: PDFReportWriter.data(for: report),
        xlsx: XLSXReportWriter.data(for: report),
        text: "场记",
        transcripts: report.recordings.map { .init(fileName: baseName + ".txt", text: service.transcriptText(for: $0)) },
        audio: [.init(source: audioURL, fileName: baseName + ".m4a")]
    )
    let zipURL = directory.appendingPathComponent("资料.zip")
    try ProjectPackageBuilder.build(contents, at: zipURL)

    // 用「归档实用工具」同款的 ditto 解压，检查中文文件名与内容
    let extracted = directory.appendingPathComponent("解压", isDirectory: true)
    #expect(try runProcess("/usr/bin/ditto", ["-x", "-k", zipURL.path, extracted.path]).status == 0)
    let root = extracted.appendingPathComponent("测试节目 场记资料", isDirectory: true)
    let fileManager = FileManager.default
    #expect(fileManager.fileExists(atPath: root.appendingPathComponent("场记单.pdf").path))
    #expect(fileManager.fileExists(atPath: root.appendingPathComponent("场记单.xlsx").path))
    #expect(try Data(contentsOf: root.appendingPathComponent("录音/\(baseName).m4a")) == Data("fake audio".utf8))
    let transcript = try String(contentsOf: root.appendingPathComponent("录音文字/\(baseName).txt"), encoding: .utf8)
    #expect(transcript.contains("我们再来一条"))
    // 压缩包结构与 CRC 正确
    #expect(try runProcess("/usr/bin/unzip", ["-tq", zipURL.path]).status == 0)
}

@Test
func emptyInterruptedRecordingsAreFoundForCleanup() throws {
    let database = try makeTestDatabase()
    let project = try database.createProject(title: "清理测试")
    let empty = try database.insertRecording(projectID: project.id, title: "空", relativePath: "a.m4a", startedAt: .now, locale: "zh-CN")
    try database.finishRecording(id: empty.id, relativePath: "a.m4a", durationMs: 0, fileSize: 0, status: .interrupted)
    let withText = try database.insertRecording(projectID: project.id, title: "有字", relativePath: "b.m4a", startedAt: .now, locale: "zh-CN")
    try database.finishRecording(id: withText.id, relativePath: "b.m4a", durationMs: 0, fileSize: 0, status: .interrupted)
    try database.insertTranscriptSegment(recordingID: withText.id, projectID: project.id, startMs: 0, endMs: 100, text: "你好")
    let normal = try database.insertRecording(projectID: project.id, title: "正常", relativePath: "c.m4a", startedAt: .now, locale: "zh-CN")
    try database.finishRecording(id: normal.id, relativePath: "c.m4a", durationMs: 60_000, fileSize: 10, status: .finished)

    #expect(try database.fetchEmptyInterruptedRecordings().map(\.id) == [empty.id])
}
