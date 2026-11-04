import AppKit
import Foundation
import SwiftUI

@MainActor
final class TimeNoteStore: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var archivedProjects: [Project] = []
    @Published private(set) var attachments: [AttachmentItem] = []
    @Published private(set) var tabs: [TabItem] = []
    @Published private(set) var entries: [LogEntry] = []
    @Published var selectedProjectID: String?
    @Published var selectedTabID: String?
    @Published var entryInputText = ""
    @Published var currentTextTabBody = ""
    @Published var highlightedEntryID: String?
    @Published var inputFocusNonce = 0
    @Published private(set) var submissionFeedbackToken = 0
    @Published private(set) var shouldForceLatestScroll = false
    @Published private(set) var lastSubmittedNote = ""
    @Published private(set) var lastSubmittedAt: Date?
    @Published var transientError: String?
    @Published var transientNotice: String?
    @Published var startupNotice: String?
    @Published var searchQuery = ""
    @Published private(set) var searchResults: [SearchResult] = []
    @Published private(set) var isWindowPinned: Bool

    private let database: SQLiteDatabase
    private let attachmentService = AttachmentService()
    private let exportService = ExportService()
    private let windowService = WindowService()
    private var textAutosaveTasks: [String: Task<Void, Never>] = [:]
    private var textDraftBodies: [String: String] = [:]
    private var textDraftRevisions: [String: Int] = [:]
    private var textTabSavedAt: [String: Date] = [:]
    private var inputHistory: [String] = []
    private var inputHistoryIndex: Int?
    private var searchTask: Task<Void, Never>?
    private static let windowPinnedDefaultsKey = "TimeNote.windowPinned"
    private static let inputHistoryDefaultsPrefix = "TimeNote.inputHistory."
    private enum Timing {
        static let searchDebounce = Duration.milliseconds(220)
        static let textTabAutosave = Duration.milliseconds(350)
        static let highlightDuration = Duration.seconds(1.2)
    }

    init() {
        isWindowPinned = UserDefaults.standard.bool(forKey: Self.windowPinnedDefaultsKey)
        do {
            let initialized = try Self.makeDatabase()
            database = initialized.database
            startupNotice = initialized.notice
            if let recovery = initialized.recovery {
                try database.recordRecovery(recovery)
            }
            do {
                _ = try database.createBackupIfNeeded()
            } catch {
                appendStartupNotice("自动备份未完成：\(error.localizedDescription)")
            }
            windowService.setAlwaysOnTop(isWindowPinned)
            try reloadAll()
        } catch {
            fatalError("TimeNote 初始化失败：\(error.localizedDescription)")
        }
    }

    var selectedProject: Project? {
        guard let selectedProjectID else { return nil }
        return allProjects.first(where: { $0.id == selectedProjectID })
    }

    var selectedTab: TabItem? {
        guard let selectedTabID else { return nil }
        return tabs.first(where: { $0.id == selectedTabID })
    }

    var isOnMainLogTab: Bool {
        selectedTab?.kind == .mainLog
    }

    var latestEntry: LogEntry? {
        entries.last
    }

    var displayedEntries: [LogEntry] {
        Array(entries.reversed())
    }

    var currentTextTabIsSaving: Bool {
        guard let selectedTab, selectedTab.kind == .text else { return false }
        return textDraftBodies[selectedTab.id] != nil || textAutosaveTasks[selectedTab.id] != nil
    }

    var currentTextTabLastSavedAt: Date? {
        guard let selectedTab, selectedTab.kind == .text else { return nil }
        return textTabSavedAt[selectedTab.id]
    }

    func createProject() {
        performDatabaseUpdate {
            let project = try database.createProject()
            try reloadAll()
            selectProject(id: project.id)
        }
    }

    func duplicateSelectedProject() {
        guard let selectedProjectID else { return }
        performDatabaseUpdate {
            let originalAttachments = try database.fetchAttachments(projectID: selectedProjectID)
            var duplicatedProjectID: String?
            do {
                let duplicated = try database.performTransaction {
                    let duplicated = try database.duplicateProject(id: selectedProjectID)
                    duplicatedProjectID = duplicated.id
                    for attachment in originalAttachments {
                        let duplicatedFile = try attachmentService.duplicateAttachment(
                            relativePath: attachment.relativePath,
                            originalFileName: attachment.fileName,
                            targetProjectID: duplicated.id
                        )
                        try database.insertAttachment(
                            projectID: duplicated.id,
                            fileName: duplicatedFile.fileName,
                            relativePath: duplicatedFile.relativePath,
                            kind: duplicatedFile.kind,
                            fileSize: duplicatedFile.fileSize
                        )
                    }
                    return duplicated
                }
                try reloadAll()
                selectProject(id: duplicated.id)
            } catch {
                if let duplicatedProjectID {
                    try? attachmentService.deleteProjectAttachmentDirectory(projectID: duplicatedProjectID)
                }
                throw error
            }
        }
    }

    func archiveProject(id: String) {
        performDatabaseUpdate {
            let wasSelected = selectedProjectID == id
            try database.archiveProject(id: id)
            try reloadAll()
            if wasSelected {
                selectProject(id: projects.first?.id)
            }
        }
    }

    func unarchiveProject(id: String) {
        performDatabaseUpdate {
            try database.unarchiveProject(id: id)
            try reloadAll()
            selectProject(id: id)
        }
    }

    func deleteProject(id: String) {
        performDatabaseUpdate {
            let wasSelected = selectedProjectID == id
            let projectTabs = try database.fetchTabs(projectID: id)
            clearTextState(for: projectTabs.map(\.id))
            try attachmentService.deleteProjectAttachmentDirectory(projectID: id)
            try database.deleteProject(id: id)
            try reloadAll()
            if wasSelected {
                selectProject(id: projects.first?.id ?? archivedProjects.first?.id)
            }
        }
    }

    func renameSelectedProject(_ title: String) {
        guard let selectedProjectID else { return }
        renameProject(id: selectedProjectID, title: title)
    }

    func renameProject(id: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        if allProjects.first(where: { $0.id == id })?.title == trimmed {
            return
        }
        performDatabaseUpdate {
            try database.renameProject(id: id, title: trimmed)
            try reloadProjectCollections()
        }
    }

    func selectProject(id: String?) {
        // 切换项目前，立即 flush 所有待保存的文本标签草稿，避免数据丢失
        flushPendingTextDrafts()
        // 清空主场记输入草稿，防止旧项目的内容串到新项目
        entryInputText = ""
        inputHistoryIndex = nil
        selectedProjectID = id
        inputHistory = loadInputHistory(projectID: id)
        refreshCurrentProject()
    }

    @discardableResult
    func addTextTab() -> String? {
        guard let selectedProjectID else { return nil }
        var createdTabID: String?
        performDatabaseUpdate {
            let tab = try database.createTextTab(projectID: selectedProjectID)
            createdTabID = tab.id
            refreshCurrentProject()
            selectedTabID = tab.id
            currentTextTabBody = tab.body
        }
        return createdTabID
    }

    func renameTab(tabID: String, title: String) {
        performDatabaseUpdate {
            try database.renameTab(tabID: tabID, title: title)
            refreshCurrentProject()
            selectedTabID = tabID
        }
    }

    func deleteTab(tabID: String) {
        performDatabaseUpdate {
            try database.deleteTab(tabID: tabID)
            clearTextState(for: [tabID])
            refreshCurrentProject()
        }
    }

    func moveTab(tabID: String, direction: Int) {
        guard let selectedProjectID else { return }
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let newIndex = index + direction
        guard tabs.indices.contains(newIndex) else { return }
        guard tabs[newIndex].kind != .mainLog else { return }

        var reordered = tabs
        reordered.swapAt(index, newIndex)
        let orderedIDs = reordered.map(\.id)
        performDatabaseUpdate {
            try database.updateTabOrder(projectID: selectedProjectID, orderedTabIDs: orderedIDs)
            refreshCurrentProject()
            selectedTabID = tabID
        }
    }

    func selectTab(id: String) {
        // 切换标签前，立即 flush 旧文本标签的草稿，避免切回时旧草稿覆盖新输入
        if let oldTabID = selectedTabID, oldTabID != id {
            flushTextTabDraft(tabID: oldTabID)
        }
        selectedTabID = id
        if let tab = selectedTab, tab.kind == .text {
            currentTextTabBody = textDraftBodies[tab.id] ?? tab.body
        } else {
            inputFocusNonce += 1
        }
        refreshEntries()
    }

    func submitMainLogEntry() {
        guard
            let selectedProjectID,
            let mainTab = tabs.first(where: { $0.kind == .mainLog })
        else {
            return
        }

        let trimmed = entryInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        performDatabaseUpdate {
            try database.insertLogEntry(
                projectID: selectedProjectID,
                tabID: mainTab.id,
                recordedAt: Date(),
                noteText: trimmed
            )
            recordInputHistory(trimmed)
            entryInputText = ""
            inputHistoryIndex = nil
            shouldForceLatestScroll = true
            lastSubmittedNote = trimmed
            lastSubmittedAt = .now
            submissionFeedbackToken += 1
            refreshEntries()
            inputFocusNonce += 1
        }
    }

    func recallPreviousInput() {
        guard inputHistory.isEmpty == false else { return }
        if inputHistoryIndex == 0 {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
            return
        }
        let nextIndex = max((inputHistoryIndex ?? inputHistory.count) - 1, 0)
        inputHistoryIndex = nextIndex
        entryInputText = inputHistory[nextIndex]
    }

    func recallNextInput() {
        guard inputHistory.isEmpty == false else { return }
        guard let inputHistoryIndex else {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
            entryInputText = ""
            return
        }
        let nextIndex = inputHistoryIndex + 1
        if nextIndex >= inputHistory.count {
            self.inputHistoryIndex = nil
            entryInputText = ""
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        } else {
            self.inputHistoryIndex = nextIndex
            entryInputText = inputHistory[nextIndex]
        }
    }

    func updateEntry(_ entryID: String, timeText: String, noteText: String) {
        guard let existing = entries.first(where: { $0.id == entryID }) else { return }
        guard let updatedDate = TimeFormats.parseClock(timeText, relativeTo: existing.recordedAt) else {
            transientError = "时间格式应为 HH:mm:ss"
            return
        }

        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            transientError = "记录内容不能为空"
            return
        }

        performDatabaseUpdate {
            try database.updateLogEntry(id: entryID, recordedAt: updatedDate, noteText: trimmed)
            refreshEntries()
            highlightedEntryID = entryID
            Task { @MainActor in
                try? await Task.sleep(for: Timing.highlightDuration)
                if highlightedEntryID == entryID {
                    highlightedEntryID = nil
                }
            }
        }
    }

    func updateCurrentTextTabBody(_ body: String) {
        currentTextTabBody = body
        guard let tab = selectedTab, tab.kind == .text else { return }
        textDraftBodies[tab.id] = body
        let revision = (textDraftRevisions[tab.id] ?? 0) + 1
        textDraftRevisions[tab.id] = revision
        scheduleTextAutosave(tabID: tab.id, body: body, revision: revision)
    }

    func copyCurrentTab() {
        guard let tab = selectedTab else { return }
        do {
            let content: String
            switch tab.kind {
            case .mainLog:
                let rows = try database.fetchEntries(projectID: tab.projectID, tabID: tab.id)
                content = exportService.makeCurrentTabCopyContent(tab: tab, entries: rows)
            case .text:
                var resolvedTab = tab
                resolvedTab.body = resolvedTextBody(for: tab)
                content = exportService.makeCurrentTabCopyContent(tab: resolvedTab, entries: [])
            }
            exportService.copyToPasteboard(content)
        } catch {
            transientError = error.localizedDescription
        }
    }

    func exportCurrentProject() {
        guard let project = selectedProject else { return }

        do {
            let projectTabs = resolvedTabsSnapshot(for: project.id)
            var entriesByTab: [String: [LogEntry]] = [:]

            for tab in projectTabs where tab.kind == .mainLog {
                entriesByTab[tab.id] = try database.fetchEntries(projectID: project.id, tabID: tab.id)
            }

            let content = exportService.makeProjectExportContent(
                project: project,
                tabs: projectTabs,
                entriesByTab: entriesByTab
            )
            if let exportedURL = try exportService.export(content: content, suggestedFileName: project.title) {
                transientNotice = "已导出到 \(exportedURL.path)"
            }
        } catch {
            transientError = error.localizedDescription
        }
    }

    func createManualBackup() {
        performDatabaseUpdate {
            if let backupURL = try database.createBackupIfNeeded(force: true, minimumInterval: 0) {
                transientNotice = "已创建备份：\(backupURL.lastPathComponent)"
            } else {
                transientNotice = "当前无需创建新的备份。"
            }
        }
    }

    func importAttachments() {
        let urls = attachmentService.chooseImportURLs()
        importAttachments(from: urls)
    }

    func importAttachments(from urls: [URL]) {
        guard let selectedProjectID else { return }
        guard urls.isEmpty == false else { return }

        performDatabaseUpdate {
            var importedFiles: [StoredAttachmentFile] = []
            do {
                for url in urls {
                    let storedFile = try attachmentService.importFile(at: url, projectID: selectedProjectID)
                    importedFiles.append(storedFile)
                }
                try database.performTransaction {
                    for storedFile in importedFiles {
                        try database.insertAttachment(
                            projectID: selectedProjectID,
                            fileName: storedFile.fileName,
                            relativePath: storedFile.relativePath,
                            kind: storedFile.kind,
                            fileSize: storedFile.fileSize
                        )
                    }
                }
            } catch {
                for storedFile in importedFiles {
                    try? attachmentService.deleteAttachment(relativePath: storedFile.relativePath)
                }
                throw error
            }
            refreshCurrentProject()
        }
    }

    func openAttachment(_ attachment: AttachmentItem) {
        do {
            try attachmentService.openAttachment(relativePath: attachment.relativePath)
        } catch {
            transientError = error.localizedDescription
        }
    }

    func deleteAttachment(_ attachment: AttachmentItem) {
        performDatabaseUpdate {
            try database.performTransaction {
                try database.deleteAttachment(id: attachment.id)
                try attachmentService.deleteAttachment(relativePath: attachment.relativePath)
            }
            refreshCurrentProject()
        }
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            searchResults = []
            return
        }

        searchTask = Task { @MainActor in
            try? await Task.sleep(for: Timing.searchDebounce)
            guard Task.isCancelled == false else { return }
            do {
                searchResults = try database.search(query: trimmed)
            } catch {
                transientError = error.localizedDescription
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchQuery = ""
        searchResults = []
    }

    func highlightEntryInList(_ entryID: String) {
        highlightEntry(entryID)
    }

    func consumeForcedLatestScroll() -> Bool {
        let shouldForce = shouldForceLatestScroll
        shouldForceLatestScroll = false
        return shouldForce
    }

    func flushPendingTextDrafts() {
        for (tabID, body) in textDraftBodies {
            do {
                try database.updateTabBody(tabID: tabID, body: body)
                textTabSavedAt[tabID] = .now
            } catch {
                transientError = error.localizedDescription
            }
        }
        for task in textAutosaveTasks.values {
            task.cancel()
        }
        textAutosaveTasks.removeAll()
        textDraftBodies.removeAll()
    }

    /// 立即 flush 单个文本标签的草稿到数据库（用于切标签场景）
    private func flushTextTabDraft(tabID: String) {
        guard let body = textDraftBodies[tabID] else { return }
        textAutosaveTasks[tabID]?.cancel()
        textAutosaveTasks[tabID] = nil
        do {
            try database.updateTabBody(tabID: tabID, body: body)
            textTabSavedAt[tabID] = .now
        } catch {
            transientError = error.localizedDescription
        }
        textDraftBodies.removeValue(forKey: tabID)
        textDraftRevisions.removeValue(forKey: tabID)
    }

    /// 统一 flush 入口：flush 所有待保存草稿，并通知视图层 flush 各自的本地草稿
    func flushAllPendingEdits() {
        flushPendingTextDrafts()
        // 通知视图层（EntryRowView 等）立即 flush 自身的 @State 草稿
        NotificationCenter.default.post(name: .timeNoteFlushPendingEdits, object: nil)
    }

    func activateSearchResult(_ result: SearchResult) {
        // 切换项目前 flush 所有草稿，清空主场记输入，防止跨项目串数据
        flushPendingTextDrafts()
        entryInputText = ""
        inputHistoryIndex = nil
        selectedProjectID = result.projectID
        refreshCurrentProject()

        do {
            if let tabID = result.tabID {
                selectTab(id: tabID)
            } else if let mainTab = try database.fetchMainTab(projectID: result.projectID) {
                selectTab(id: mainTab.id)
            }
        } catch {
            transientError = error.localizedDescription
        }

        if let entryID = result.entryID {
            highlightEntry(entryID)
        }

        if let attachmentID = result.attachmentID,
           let attachment = attachments.first(where: { $0.id == attachmentID }) {
            highlightedEntryID = nil
            transientError = "已定位到附件“\(attachment.fileName)”。如需打开，请在附件区点击。"
        }

        clearSearch()
    }

    func attachWindow(_ window: NSWindow?) {
        windowService.attach(window: window)
        windowService.setAlwaysOnTop(isWindowPinned)
    }

    func toggleWindowPinned() {
        setWindowPinned(!isWindowPinned)
    }

    func setWindowPinned(_ pinned: Bool) {
        isWindowPinned = pinned
        UserDefaults.standard.set(pinned, forKey: Self.windowPinnedDefaultsKey)
        windowService.setAlwaysOnTop(pinned)
    }

    private func reloadAll() throws {
        try reloadProjectCollections()
        if selectedProjectID == nil || allProjects.contains(where: { $0.id == selectedProjectID }) == false {
            selectedProjectID = projects.first?.id ?? archivedProjects.first?.id
        }
        inputHistory = loadInputHistory(projectID: selectedProjectID)
        inputHistoryIndex = nil
        refreshCurrentProject()
    }

    private func reloadProjectCollections() throws {
        projects = try database.fetchProjects()
        archivedProjects = try database.fetchArchivedProjects()
    }

    private func refreshCurrentProject() {
        guard let selectedProjectID else {
            attachments = []
            tabs = []
            entries = []
            selectedTabID = nil
            currentTextTabBody = ""
            inputHistory = []
            inputHistoryIndex = nil
            return
        }

        do {
            attachments = try database.fetchAttachments(projectID: selectedProjectID)
            tabs = try database.fetchTabs(projectID: selectedProjectID).map { tab in
                var resolvedTab = tab
                if let draftBody = textDraftBodies[tab.id] {
                    resolvedTab.body = draftBody
                }
                return resolvedTab
            }
            let fallbackTabID = tabs.first(where: { $0.kind == .mainLog })?.id ?? tabs.first?.id
            if tabs.contains(where: { $0.id == selectedTabID }) == false {
                selectedTabID = fallbackTabID
            }
            if let selectedTab, selectedTab.kind == .text {
                currentTextTabBody = textDraftBodies[selectedTab.id] ?? selectedTab.body
            }
            refreshEntries()
        } catch {
            transientError = error.localizedDescription
        }
    }

    private func refreshEntries() {
        guard
            let selectedProjectID,
            let mainTab = tabs.first(where: { $0.kind == .mainLog })
        else {
            entries = []
            return
        }

        do {
            entries = try database.fetchEntries(projectID: selectedProjectID, tabID: mainTab.id)
        } catch {
            transientError = error.localizedDescription
        }
    }

    private func performDatabaseUpdate(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            transientError = error.localizedDescription
        }
    }

    private func highlightEntry(_ entryID: String) {
        highlightedEntryID = entryID
        Task { @MainActor in
            try? await Task.sleep(for: Timing.highlightDuration)
            if highlightedEntryID == entryID {
                highlightedEntryID = nil
            }
        }
    }

    private var allProjects: [Project] {
        projects + archivedProjects
    }

    private func clearTextState(for tabIDs: [String]) {
        for tabID in tabIDs {
            textAutosaveTasks[tabID]?.cancel()
            textAutosaveTasks[tabID] = nil
            textDraftBodies[tabID] = nil
            textDraftRevisions[tabID] = nil
            textTabSavedAt[tabID] = nil
        }
    }

    private func resolvedTabsSnapshot(for projectID: String) -> [TabItem] {
        let baseTabs = selectedProjectID == projectID ? tabs : (try? database.fetchTabs(projectID: projectID)) ?? []
        return baseTabs.map { tab in
            var resolvedTab = tab
            resolvedTab.body = resolvedTextBody(for: tab)
            return resolvedTab
        }
    }

    private func resolvedTextBody(for tab: TabItem) -> String {
        if tab.kind == .text {
            if selectedTabID == tab.id {
                return currentTextTabBody
            }
            if let draft = textDraftBodies[tab.id] {
                return draft
            }
        }
        return tab.body
    }

    private func recordInputHistory(_ value: String) {
        guard value.isEmpty == false else { return }
        if inputHistory.last != value {
            inputHistory.append(value)
        }
        if inputHistory.count > 30 {
            inputHistory.removeFirst(inputHistory.count - 30)
        }
        saveInputHistory()
    }

    private func inputHistoryDefaultsKey(projectID: String) -> String {
        Self.inputHistoryDefaultsPrefix + projectID
    }

    private func loadInputHistory(projectID: String?) -> [String] {
        guard let projectID else { return [] }
        return UserDefaults.standard.stringArray(forKey: inputHistoryDefaultsKey(projectID: projectID)) ?? []
    }

    private func saveInputHistory() {
        guard let selectedProjectID else { return }
        UserDefaults.standard.set(inputHistory, forKey: inputHistoryDefaultsKey(projectID: selectedProjectID))
    }

    private func scheduleTextAutosave(tabID: String, body: String, revision: Int) {
        textAutosaveTasks[tabID]?.cancel()
        textAutosaveTasks[tabID] = Task { @MainActor in
            try? await Task.sleep(for: Timing.textTabAutosave)
            guard Task.isCancelled == false else { return }
            do {
                try database.updateTabBody(tabID: tabID, body: body)
                textAutosaveTasks[tabID] = nil

                let currentRevision = textDraftRevisions[tabID] ?? revision
                if currentRevision == revision {
                    textDraftBodies.removeValue(forKey: tabID)
                    textTabSavedAt[tabID] = .now
                    return
                }

                if let latestBody = textDraftBodies[tabID] {
                    scheduleTextAutosave(tabID: tabID, body: latestBody, revision: currentRevision)
                }
            } catch {
                textAutosaveTasks[tabID] = nil
                transientError = error.localizedDescription
            }
        }
    }

    private func appendStartupNotice(_ message: String) {
        if let startupNotice, startupNotice.isEmpty == false {
            self.startupNotice = startupNotice + "\n" + message
        } else {
            startupNotice = message
        }
    }

    private static func makeDatabase() throws -> (database: SQLiteDatabase, recovery: LaunchRecoveryResult?, notice: String?) {
        let databaseURL = try SQLiteDatabase.defaultDatabaseURL()
        do {
            let launchRecovery = try RecoveryService.prepareDatabaseForLaunch(at: databaseURL)
            let database = try SQLiteDatabase(path: databaseURL)
            return (database, launchRecovery, launchRecovery?.userMessage)
        } catch {
            let fallbackDirectory = databaseURL
                .deletingLastPathComponent()
                .appendingPathComponent("Fallback", isDirectory: true)
            try? pruneFallbackDatabases(in: fallbackDirectory, keepLast: 3)
            let fallbackURL = fallbackDirectory
                .appendingPathComponent("timenote-fallback-\(UUID().uuidString).sqlite")
            let fallbackDatabase = try SQLiteDatabase(path: fallbackURL)
            let notice = "主数据库启动失败，已改用恢复目录中的备用数据库。该会话数据会保留在本机，请尽快导出并检查主数据库：\(error.localizedDescription)"
            return (fallbackDatabase, nil, notice)
        }
    }

    private static func pruneFallbackDatabases(in directory: URL, keepLast limit: Int) throws {
        guard limit >= 0 else { return }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
            .filter { $0.pathExtension == "sqlite" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
        for file in files.dropFirst(limit) {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: file.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: file.path + "-shm"))
        }
    }
}
