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
    let original = try #require(TimeFormats.iso8601Date(from: "2026-04-16T15:58:30.000Z"))
    let parsed = try #require(TimeFormats.parseClock("00:05:00", relativeTo: original))
    let calendar = Calendar.current

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
    let store = TimeNoteStore()
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
    let store = TimeNoteStore()
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
    let store = TimeNoteStore()
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
    let store = TimeNoteStore()
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
    let store = TimeNoteStore()
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
    let store = TimeNoteStore()
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
    let store = TimeNoteStore()
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
