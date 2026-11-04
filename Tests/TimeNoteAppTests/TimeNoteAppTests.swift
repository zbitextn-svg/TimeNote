import Foundation
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
    #expect(AppInfo.version == "1.1.23")
    #expect(script.contains("APP_VERSION=\"${APP_VERSION:-\(AppInfo.version)}\""))
}
