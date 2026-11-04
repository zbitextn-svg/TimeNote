import AppKit
import Foundation
import SwiftUI

/// 轻量提示条（替代"完成"类弹窗），可附带一个操作按钮，例如"撤销"。
struct ToastMessage: Identifiable, Equatable {
    enum Style: Equatable {
        case success
        case info
    }

    let id = UUID()
    let text: String
    let style: Style
    let actionTitle: String?
}

@MainActor
final class TimeNoteStore: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var archivedProjects: [Project] = []
    @Published private(set) var attachments: [AttachmentItem] = []
    @Published private(set) var tabs: [TabItem] = []
    @Published private(set) var entries: [LogEntry] = []
    @Published var selectedProjectID: String?
    @Published var selectedTabID: String?
    /// 主场记输入框内容。从空变为非空时锁定时间戳（见 `pendingEntryStartedAt`）。
    @Published var entryInputText = "" {
        didSet { syncPendingEntryStart() }
    }
    /// 当前这条场记的时间戳：用户开始输入的时刻，提交时使用；输入清空后重置。
    @Published private(set) var pendingEntryStartedAt: Date?
    @Published var currentTextTabBody = ""
    @Published var highlightedEntryID: String?
    @Published var highlightedAttachmentID: String?
    @Published var isAttachmentPanelPresented = false
    @Published private(set) var projectStats: [String: ProjectEntryStats] = [:]
    @Published private(set) var toast: ToastMessage?
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
    /// 搜索防抖等待中（用于显示"搜索中"而不是闪一下"没有结果"）
    @Published private(set) var isSearchPending = false
    @Published private(set) var isWindowPinned: Bool

    private let database: SQLiteDatabase
    private let attachmentService: AttachmentService
    private var toastAction: (() -> Void)?
    private var toastDismissTask: Task<Void, Never>?
    private let exportService = ExportService()
    private let windowService = WindowService()
    private var textAutosaveTasks: [String: Task<Void, Never>] = [:]
    private var textDraftBodies: [String: String] = [:]
    private var textDraftRevisions: [String: Int] = [:]
    /// 发布出去，保存完成时界面能从"正在保存"刷新为"已保存"
    @Published private var textTabSavedAt: [String: Date] = [:]
    private var inputHistory: [String] = []
    private var inputHistoryIndex: Int?
    private var searchTask: Task<Void, Never>?
    private static let windowPinnedDefaultsKey = "TimeNote.windowPinned"
    private static let inputHistoryDefaultsPrefix = "TimeNote.inputHistory."
    private enum Timing {
        static let searchDebounce = Duration.milliseconds(220)
        static let textTabAutosave = Duration.milliseconds(350)
        static let highlightDuration = Duration.seconds(1.6)
        static let toastDuration = Duration.seconds(3)
        static let undoToastDuration = Duration.seconds(6)
    }

    /// - Parameter rootDirectory: 数据目录。传 nil 时使用默认目录（可被 `TIMENOTE_DATA_DIR` 覆盖）。
    ///   测试应传入临时目录，避免读写真实数据。
    init(rootDirectory: URL? = nil) {
        isWindowPinned = UserDefaults.standard.bool(forKey: Self.windowPinnedDefaultsKey)
        attachmentService = AttachmentService(rootURL: rootDirectory)
        do {
            let initialized = try Self.makeDatabase(rootDirectory: rootDirectory)
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
            #if DEBUG
            if ProcessInfo.processInfo.environment["TIMENOTE_DEMO_SEED"] == "1" {
                try DemoData.seedIfNeeded(database)
            }
            #endif
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
        entries.max { lhs, rhs in
            lhs.createdAt < rhs.createdAt
        }
    }

    var displayedEntries: [LogEntry] {
        Array(entries.reversed())
    }

    /// 按日期分组、最新在前，供主场记列表显示。
    var displayedDayGroups: [LogDayGroup] {
        entries.groupedByDay(newestFirst: true)
    }

    var selectedProjectStats: ProjectEntryStats? {
        guard let selectedProjectID else { return nil }
        return projectStats[selectedProjectID]
    }

    func stats(for projectID: String) -> ProjectEntryStats? {
        projectStats[projectID]
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
            // 先删数据库记录（事务内），成功后再删附件文件；
            // 反过来的话，数据库删除失败会留下"记录还在、文件已没"的残缺项目。
            try database.deleteProject(id: id)
            try? attachmentService.deleteProjectAttachmentDirectory(projectID: id)
            UserDefaults.standard.removeObject(forKey: inputHistoryDefaultsKey(projectID: id))
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
            // 不改变当前选中的标签：用户可能是点了别的标签才结束重命名的，
            // 这里如果强行选回被重命名的标签，就会出现"点主场记回不去"的问题。
            refreshCurrentProject()
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

    /// ⌘1…⌘9 切换标签
    func selectTab(atIndex index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectTab(id: tabs[index].id)
    }

    /// 回到主场记并聚焦输入框（⌘L）
    func focusMainLogInput() {
        if let mainTab = tabs.first(where: { $0.kind == .mainLog }), selectedTabID != mainTab.id {
            selectTab(id: mainTab.id)
        } else {
            inputFocusNonce += 1
        }
    }

    /// 把锁定的时间戳刷新为当前时间
    func resetPendingEntryTime() {
        guard pendingEntryStartedAt != nil else { return }
        pendingEntryStartedAt = Date()
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

        let recordedAt = pendingEntryStartedAt ?? Date()
        performDatabaseUpdate {
            try database.insertLogEntry(
                projectID: selectedProjectID,
                tabID: mainTab.id,
                recordedAt: recordedAt,
                noteText: trimmed
            )
            recordInputHistory(trimmed)
            entryInputText = ""
            pendingEntryStartedAt = nil
            inputHistoryIndex = nil
            shouldForceLatestScroll = true
            lastSubmittedNote = trimmed
            lastSubmittedAt = recordedAt
            submissionFeedbackToken += 1
            refreshEntries()
            refreshProjectStats()
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
        // 从数据库读取原记录，而不是依赖当前显示的 entries：
        // 编辑中途切换项目时，行视图在消失前才保存，此时 entries 已是新项目的数据。
        let existing: LogEntry
        do {
            guard let fetched = try database.fetchEntry(id: entryID) else { return }
            existing = fetched
        } catch {
            transientError = error.localizedDescription
            return
        }
        guard let updatedDate = TimeFormats.parseClock(timeText, relativeTo: existing.recordedAt) else {
            transientError = "时间格式应为 HH:mm:ss"
            return
        }

        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            transientError = "记录内容不能为空"
            return
        }
        let timeChanged = TimeFormats.clockString(from: updatedDate) != TimeFormats.clockString(from: existing.recordedAt)
        guard timeChanged || trimmed != existing.noteText else { return }

        performDatabaseUpdate {
            try database.updateLogEntry(id: entryID, recordedAt: timeChanged ? updatedDate : existing.recordedAt, noteText: trimmed)
            if existing.projectID == selectedProjectID {
                refreshEntries()
            }
            refreshProjectStats()
            // 只有时间被修改（可能重新排序）时才高亮并定位；改文字时不打扰正在编辑的用户
            if timeChanged, existing.projectID == selectedProjectID {
                highlightEntry(entryID)
            }
        }
    }

    func deleteEntry(_ entryID: String) {
        performDatabaseUpdate {
            guard let entry = try database.fetchEntry(id: entryID) else { return }
            try database.deleteLogEntry(id: entryID)
            if entry.projectID == selectedProjectID {
                refreshEntries()
            }
            refreshProjectStats()
            showToast(
                "已删除 \(TimeFormats.clockString(from: entry.recordedAt)) 的场记",
                style: .info,
                actionTitle: "撤销"
            ) { [weak self] in
                self?.restoreDeletedEntry(entry)
            }
        }
    }

    private func restoreDeletedEntry(_ entry: LogEntry) {
        performDatabaseUpdate {
            try database.restoreLogEntry(entry)
            if entry.projectID == selectedProjectID {
                refreshEntries()
                highlightEntry(entry.id)
            }
            refreshProjectStats()
        }
    }

    func copyEntry(_ entry: LogEntry) {
        exportService.copyToPasteboard("\(TimeFormats.clockString(from: entry.recordedAt)) \(entry.noteText)")
        showToast("已复制这条场记", style: .success)
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
            showToast("已复制“\(tab.title)”的全部内容", style: .success)
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
                showToast("已导出：\(exportedURL.lastPathComponent)", style: .success)
            }
        } catch {
            transientError = error.localizedDescription
        }
    }

    func createManualBackup() {
        performDatabaseUpdate {
            if let backupURL = try database.createBackupIfNeeded(force: true, minimumInterval: 0) {
                showToast("已创建备份：\(backupURL.lastPathComponent)", style: .success)
            } else {
                showToast("当前无需创建新的备份", style: .info)
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
            isAttachmentPanelPresented = true
            showToast(importedFiles.count == 1 ? "已导入附件“\(importedFiles[0].fileName)”" : "已导入 \(importedFiles.count) 个附件", style: .success)
        }
    }

    func revealAttachment(_ attachment: AttachmentItem) {
        do {
            let url = try attachmentService.attachmentURL(relativePath: attachment.relativePath)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            transientError = error.localizedDescription
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
            isSearchPending = false
            return
        }

        isSearchPending = true
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: Timing.searchDebounce)
            guard Task.isCancelled == false else { return }
            do {
                searchResults = try database.search(query: trimmed)
            } catch {
                transientError = error.localizedDescription
            }
            isSearchPending = false
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchQuery = ""
        searchResults = []
        isSearchPending = false
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
                markTextTabSaved(tabID: tabID, body: body)
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
            markTextTabSaved(tabID: tabID, body: body)
        } catch {
            transientError = error.localizedDescription
        }
        textDraftBodies.removeValue(forKey: tabID)
        textDraftRevisions.removeValue(forKey: tabID)
    }

    /// 保存成功后同步内存中的标签内容。
    ///
    /// 之前只清掉草稿、没有更新 `tabs` 里的 body，之后重新选中这个标签时会读到创建时的旧内容
    /// （通常是空的），编辑器显示为空；此时再输入就会用残缺内容覆盖已保存的文本。
    private func markTextTabSaved(tabID: String, body: String) {
        if let index = tabs.firstIndex(where: { $0.id == tabID }), tabs[index].body != body {
            tabs[index].body = body
        }
        textTabSavedAt[tabID] = .now
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
            isAttachmentPanelPresented = true
            highlightedAttachmentID = attachmentID
            showToast("已定位到附件“\(attachment.fileName)”", style: .info)
            Task { @MainActor in
                try? await Task.sleep(for: Timing.highlightDuration)
                if highlightedAttachmentID == attachmentID {
                    highlightedAttachmentID = nil
                }
            }
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
        projectStats = try database.fetchEntryStats()
    }

    private func refreshProjectStats() {
        do {
            projectStats = try database.fetchEntryStats()
        } catch {
            transientError = error.localizedDescription
        }
    }

    // MARK: - Toast

    func showToast(
        _ text: String,
        style: ToastMessage.Style = .success,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        toastDismissTask?.cancel()
        toastAction = action
        let message = ToastMessage(text: text, style: style, actionTitle: action == nil ? nil : actionTitle)
        toast = message
        let duration = action == nil ? Timing.toastDuration : Timing.undoToastDuration
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard Task.isCancelled == false else { return }
            if toast?.id == message.id {
                toast = nil
                toastAction = nil
            }
        }
    }

    func performToastAction() {
        let action = toastAction
        dismissToast()
        action?()
    }

    func dismissToast() {
        toastDismissTask?.cancel()
        toast = nil
        toastAction = nil
    }

    private func syncPendingEntryStart() {
        let hasContent = entryInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if hasContent, pendingEntryStartedAt == nil {
            pendingEntryStartedAt = Date()
        } else if hasContent == false, pendingEntryStartedAt != nil {
            pendingEntryStartedAt = nil
        }
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
                    markTextTabSaved(tabID: tabID, body: body)
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

    private static func makeDatabase(rootDirectory: URL?) throws -> (database: SQLiteDatabase, recovery: LaunchRecoveryResult?, notice: String?) {
        let databaseURL = try rootDirectory.map { AppPaths.databaseURL(in: $0) } ?? SQLiteDatabase.defaultDatabaseURL()
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
