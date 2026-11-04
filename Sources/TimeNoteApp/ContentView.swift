import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Color Tokens

private enum ColorTokens {
    static let windowBackground = Color(light: Color(hex: "#F9F6F2"), dark: Color(hex: "#1E1B18"))
    static let sidebarBackground = Color(light: Color(hex: "#F2EDE8"), dark: Color(hex: "#1C1A18"))
    static let timestampAmber = Color(light: Color(hex: "#E8860A"), dark: Color(hex: "#F5A623"))
    static let entryCardBackground = Color(
        light: Color(hex: "#FFFFFF").opacity(0.72),
        dark: Color(hex: "#282622").opacity(0.85)
    )
    static let entryCardBorder = Color(light: Color(hex: "#E0D8D0"), dark: Color(hex: "#3D3830"))
}

// MARK: - Color Helpers

private extension Color {
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&value)

        let a: UInt64
        let r: UInt64
        let g: UInt64
        let b: UInt64

        switch sanitized.count {
        case 6:
            (a, r, g, b) = (255, value >> 16, value >> 8 & 0xFF, value & 0xFF)
        case 8:
            (a, r, g, b) = (value >> 24, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            switch appearance.name {
            case .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastVibrantDark:
                return NSColor(dark)
            default:
                return NSColor(light)
            }
        })
    }
}

struct ContentView: View {
    @ObservedObject var store: TimeNoteStore
    @AppStorage("TimeNote.showsArchivedProjects") private var showsArchivedProjects = false
    @AppStorage("TimeNote.showsAttachments") private var showsAttachments = false
    @State private var projectTitleDraft = ""
    @State private var renamingTabID: String?
    @State private var renamingTabTitle = ""
    @State private var pendingConfirmation: PendingConfirmation?
    @FocusState private var renamingTabFocused: Bool
    @FocusState private var searchFieldFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var projectTitleSaveTask: Task<Void, Never>?
    @State private var isAttachmentDropTarget = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .background(WindowAccessor { window in
            store.attachWindow(window)
        })
        .alert(currentAlertTitle, isPresented: Binding(
            get: { currentAlertMessage != nil },
            set: {
                if !$0 {
                    if store.startupNotice != nil {
                        store.startupNotice = nil
                    } else if store.transientError != nil {
                        store.transientError = nil
                    } else {
                        store.transientNotice = nil
                    }
                }
            }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(currentAlertMessage ?? "")
        }
        .confirmationDialog(
            pendingConfirmation?.title ?? "",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingConfirmation {
                Button(pendingConfirmation.confirmLabel, role: pendingConfirmation.role) {
                    performConfirmation(pendingConfirmation)
                    self.pendingConfirmation = nil
                }
                Button("取消", role: .cancel) {
                    self.pendingConfirmation = nil
                }
            }
        } message: {
            if let pendingConfirmation {
                Text(pendingConfirmation.message)
            }
        }
        .onAppear {
            alignSidebarToSelection()
        }
        .onChange(of: store.selectedProjectID) { oldProjectID, _ in
            // 切换项目前，立即 flush 旧项目的标题重命名草稿，避免被 cancel 丢失
            flushPendingProjectRename(projectID: oldProjectID)
            alignSidebarToSelection()
            projectTitleDraft = store.selectedProject?.title ?? ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .timeNoteFocusSearch)) { _ in
            searchFieldFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .timeNoteCreateProject)) { _ in
            store.createProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .timeNoteCreateBackup)) { _ in
            store.createManualBackup()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 窗口失活/进入后台时，立即 flush 所有待保存草稿
            if newPhase == .inactive || newPhase == .background {
                flushAllPendingEdits()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            // NSApplication 级别兆底：覆盖 scenePhase 未捕获的失活场景
            flushAllPendingEdits()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            flushAllPendingEdits()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("项目")
                    .font(.headline)
                Spacer()
                Button {
                    store.createProject()
                } label: {
                    Label("新建项目", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .help("新建项目")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            List(selection: Binding(
                get: { store.selectedProjectID },
                set: { store.selectProject(id: $0) }
            )) {
                Section("进行中") {
                    if store.projects.isEmpty {
                        Text("暂无项目")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.projects) { project in
                            projectRow(project)
                        }
                    }
                }

                if store.archivedProjects.isEmpty == false {
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { showsArchivedProjects },
                            set: { newValue in
                                showsArchivedProjects = newValue
                                syncSelectionForSidebar()
                            }
                        )
                    ) {
                        ForEach(store.archivedProjects) { project in
                            projectRow(project)
                        }
                    } label: {
                        HStack {
                            Text("已归档")
                            Spacer()
                            Text("\(store.archivedProjects.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .frame(minWidth: 250)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        .background(ColorTokens.sidebarBackground.ignoresSafeArea())
    }

    @ViewBuilder
    private var detail: some View {
        if store.selectedProject != nil {
            VStack(spacing: 0) {
                header
                Divider()
                contentBody
                Divider()
                attachmentsSection
                Divider()
                tabsBar
            }
            .background(ColorTokens.windowBackground.ignoresSafeArea())
        } else {
            ContentUnavailableView(
                store.archivedProjects.isEmpty == false && showsArchivedProjects
                    ? "还没有选中归档项目"
                    : "还没有项目",
                systemImage: showsArchivedProjects ? "archivebox" : "document.badge.plus",
                description: Text(
                    showsArchivedProjects
                        ? "展开归档项目列表，或新建一个项目继续记录。"
                        : "先创建一个项目，就可以开始现场记事。"
                )
            )
            .background(ColorTokens.windowBackground.ignoresSafeArea())
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField(
                "项目标题",
                text: $projectTitleDraft
            )
            .textFieldStyle(.plain)
            .font(.title2.weight(.semibold))
            .frame(minWidth: 260)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(Color.accentColor.opacity(0.35))
            }
            .onAppear {
                projectTitleDraft = store.selectedProject?.title ?? ""
            }
            .onChange(of: projectTitleDraft) { _, newValue in
                scheduleProjectRename(newValue)
            }

            TextField(
                "搜索项目、标签和场记内容",
                text: Binding(
                    get: { store.searchQuery },
                    set: { store.updateSearchQuery($0) }
                )
            )
            .textFieldStyle(.plain)
            .frame(maxWidth: 280)
            .padding(.leading, 28)
            .padding(.trailing, 30)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ColorTokens.entryCardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(ColorTokens.entryCardBorder, lineWidth: 1)
                    )
            )
            .focused($searchFieldFocused)
            .overlay(alignment: .leading) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
            }
            .overlay(alignment: .trailing) {
                if store.searchQuery.isEmpty == false {
                    Button {
                        store.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }
            }
            .onExitCommand {
                store.clearSearch()
            }

            if store.selectedProject?.isArchived == true {
                Label("已归档", systemImage: "archivebox.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                store.toggleWindowPinned()
            } label: {
                Image(systemName: store.isWindowPinned ? "pin.fill" : "pin")
                    .foregroundStyle(store.isWindowPinned ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(store.isWindowPinned ? "当前窗口已置顶" : "置顶当前窗口")

            Button("导出项目") {
                store.exportCurrentProject()
            }
            .buttonStyle(.borderedProminent)

            Menu("更多操作") {
                Button("复制当前标签") {
                    store.copyCurrentTab()
                }

                Button(store.isWindowPinned ? "取消置顶" : "窗口置顶") {
                    store.toggleWindowPinned()
                }

                Button("立即备份") {
                    store.createManualBackup()
                }

                Divider()

                Button("复制项目") {
                    store.duplicateSelectedProject()
                }

                Button(store.selectedProject?.isArchived == true ? "恢复项目" : "归档项目") {
                    if let selectedProject = store.selectedProject {
                        if selectedProject.isArchived {
                            store.unarchiveProject(id: selectedProject.id)
                        } else {
                            pendingConfirmation = .archiveProject(
                                id: selectedProject.id,
                                name: selectedProject.title
                            )
                        }
                    }
                }

                Button("删除项目", role: .destructive) {
                    if let selectedProject = store.selectedProject {
                        pendingConfirmation = .deleteProject(
                            id: selectedProject.id,
                            name: selectedProject.title
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var contentBody: some View {
        if store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            SearchResultsView(store: store)
        } else if store.isOnMainLogTab {
            MainLogView(store: store)
        } else {
            HSplitView {
                MainLogView(store: store, title: "主场记", shouldAutoFocusInput: false, compactLayout: true)
                    .frame(minWidth: 420)
                TextTabEditor(store: store)
                    .frame(minWidth: 320)
            }
        }
    }

    private var tabsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.tabs) { tab in
                    Group {
                        if renamingTabID == tab.id, tab.kind == .text {
                            TextField(
                                "标签名",
                                text: $renamingTabTitle
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 180, idealWidth: 220, maxWidth: 260)
                            .focused($renamingTabFocused)
                            .onSubmit {
                                finishRenaming(tabID: tab.id)
                            }
                            .onAppear {
                                renamingTabFocused = true
                            }
                            .onExitCommand {
                                if renamingTabID == tab.id {
                                    cancelRenaming(tab)
                                }
                            }
                            .onChange(of: renamingTabFocused) { _, isFocused in
                                if isFocused == false, renamingTabID == tab.id {
                                    finishRenaming(tabID: tab.id)
                                }
                            }
                        } else {
                            Button {
                                store.selectTab(id: tab.id)
                            } label: {
                                Text(tab.title)
                                    .lineLimit(1)
                                    .font(.callout.weight(store.selectedTabID == tab.id ? .semibold : .regular))
                                    .foregroundStyle(store.selectedTabID == tab.id ? Color.white : Color.primary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule()
                                            .fill(store.selectedTabID == tab.id ? Color.accentColor : Color.secondary.opacity(0.10))
                                    )
                            }
                            .buttonStyle(.plain)
                            .onTapGesture(count: 2) {
                                guard tab.kind == .text else { return }
                                startRenaming(tab)
                            }
                            .contextMenu {
                                if tab.kind == .text {
                                    Button("重命名") {
                                        startRenaming(tab)
                                    }
                                    Button("左移") {
                                        store.moveTab(tabID: tab.id, direction: -1)
                                    }
                                    Button("右移") {
                                        store.moveTab(tabID: tab.id, direction: 1)
                                    }
                                    Divider()
                                    Button("删除标签", role: .destructive) {
                                        pendingConfirmation = .deleteTab(
                                            id: tab.id,
                                            name: tab.title
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                Button {
                    if let tabID = store.addTextTab(),
                       let tab = store.tabs.first(where: { $0.id == tabID }) {
                        startRenaming(tab)
                    }
                } label: {
                    Label("新建标签", systemImage: "plus")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(
            ColorTokens.windowBackground
                .overlay(alignment: .top) {
                    Rectangle()
                        .frame(height: 1)
                        .foregroundStyle(ColorTokens.entryCardBorder.opacity(0.7))
                }
        )
    }

    private var attachmentsSection: some View {
        DisclosureGroup(isExpanded: $showsAttachments) {
            VStack(alignment: .leading, spacing: 0) {
                if store.attachments.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "paperclip")
                            .foregroundStyle(.secondary)
                        Text("还没有附件，支持导入图片、音频和视频，也支持拖入窗口。")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.attachments) { attachment in
                                Button {
                                    store.openAttachment(attachment)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: attachment.kind.systemImageName)
                                            .font(.title3)
                                            .foregroundStyle(Color.accentColor)
                                            .frame(width: 24)

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(attachment.fileName)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text("\(attachment.kind.label) · \(formattedFileSize(attachment.fileSize))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        Image(systemName: "arrow.up.forward.square")
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(ColorTokens.entryCardBackground)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                    .stroke(ColorTokens.entryCardBorder, lineWidth: 1)
                                            )
                                    )
                                    .shadow(color: Color.black.opacity(0.03), radius: 2, x: 0, y: 1)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("打开附件") {
                                        store.openAttachment(attachment)
                                    }
                                    Divider()
                                    Button("删除附件", role: .destructive) {
                                        pendingConfirmation = .deleteAttachment(
                                            id: attachment.id,
                                            name: attachment.fileName
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                    .frame(maxHeight: attachmentListMaxHeight)
                }
            }
        } label: {
            HStack {
                Label("附件", systemImage: "paperclip")
                    .font(.headline)
                Spacer()
                Button("导入附件") {
                    store.importAttachments()
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isAttachmentDropTarget ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .background(.regularMaterial)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isAttachmentDropTarget) { providers in
            handleAttachmentDrop(providers: providers)
        }
    }

    @ViewBuilder
    private func projectRow(_ project: Project) -> some View {
        HStack {
            Text(project.title)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(store.selectedProjectID == project.id ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .tag(Optional(project.id))
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowBackground(Color.clear)
            .contextMenu {
                Button("复制项目") {
                    store.selectProject(id: project.id)
                    store.duplicateSelectedProject()
                }

                if project.isArchived {
                    Button("恢复项目") {
                        store.selectProject(id: project.id)
                        store.unarchiveProject(id: project.id)
                    }
                } else {
                    Button("归档项目") {
                        pendingConfirmation = .archiveProject(
                            id: project.id,
                            name: project.title
                        )
                    }
                }

                Divider()

                Button("删除项目", role: .destructive) {
                    pendingConfirmation = .deleteProject(
                        id: project.id,
                        name: project.title
                    )
                }
            }
    }

    private func performConfirmation(_ confirmation: PendingConfirmation) {
        switch confirmation {
        case .archiveProject(let id, _):
            store.archiveProject(id: id)
        case .deleteProject(let id, _):
            store.deleteProject(id: id)
        case .deleteAttachment(let id, _):
            if let attachment = store.attachments.first(where: { $0.id == id }) {
                store.deleteAttachment(attachment)
            }
        case .deleteTab(let id, _):
            store.deleteTab(tabID: id)
        }
    }

    private func alignSidebarToSelection() {
        guard let selectedProject = store.selectedProject else { return }
        showsArchivedProjects = selectedProject.isArchived || showsArchivedProjects
    }

    private func syncSelectionForSidebar() {
        let currentSelectionIsVisible = currentSidebarProjects.contains { $0.id == store.selectedProjectID }
        guard currentSelectionIsVisible == false else { return }
        store.selectProject(id: currentSidebarProjects.first?.id)
    }

    private var currentSidebarProjects: [Project] {
        let activeProjects = store.projects
        let archivedProjects = showsArchivedProjects ? store.archivedProjects : []
        return activeProjects + archivedProjects
    }

    private var currentAlertTitle: String {
        if store.startupNotice != nil {
            return "启动提示"
        }
        return store.transientError != nil ? "提示" : "完成"
    }

    private var currentAlertMessage: String? {
        store.startupNotice ?? store.transientError ?? store.transientNotice
    }

    private func formattedFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var attachmentListMaxHeight: CGFloat {
        min(max(CGFloat(store.attachments.count) * 64, 140), 320)
    }

    private func scheduleProjectRename(_ title: String) {
        guard let projectID = store.selectedProjectID else { return }
        projectTitleSaveTask?.cancel()
        projectTitleSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard Task.isCancelled == false else { return }
            store.renameProject(id: projectID, title: title)
        }
    }

    private func flushPendingProjectRename(projectID: String? = nil) {
        projectTitleSaveTask?.cancel()
        projectTitleSaveTask = nil
        let targetID = projectID ?? store.selectedProjectID
        guard let targetID else { return }
        store.renameProject(id: targetID, title: projectTitleDraft)
    }

    /// 统一 flush 入口：flush 项目标题草稿 + 文本标签草稿 + 通知视图层 flush 本地草稿
    private func flushAllPendingEdits() {
        flushPendingProjectRename()
        store.flushAllPendingEdits()
    }

    private func startRenaming(_ tab: TabItem) {
        store.selectTab(id: tab.id)
        renamingTabID = tab.id
        renamingTabTitle = tab.title
        renamingTabFocused = true
    }

    private func finishRenaming(tabID: String) {
        let trimmed = renamingTabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tab = store.tabs.first(where: { $0.id == tabID }) else {
            renamingTabID = nil
            renamingTabTitle = ""
            renamingTabFocused = false
            return
        }
        if trimmed.isEmpty == false {
            store.renameTab(tabID: tabID, title: trimmed)
        } else {
            store.transientError = "标签名不能为空"
            renamingTabTitle = tab.title
        }
        renamingTabID = nil
        renamingTabTitle = ""
        renamingTabFocused = false
    }

    private func cancelRenaming(_ tab: TabItem) {
        renamingTabID = nil
        renamingTabTitle = tab.title
        renamingTabFocused = false
    }

    private func handleAttachmentDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard fileProviders.isEmpty == false else { return false }

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL? else {
                    return
                }
                Task { @MainActor in
                    showsAttachments = true
                    store.importAttachments(from: [url])
                }
            }
        }
        return true
    }
}

private struct MainLogView: View {
    @ObservedObject var store: TimeNoteStore
    @AppStorage("TimeNote.mainLogShortcutHintUses") private var shortcutHintUses = 0
    let title: String?
    let shouldAutoFocusInput: Bool
    let compactLayout: Bool
    @State private var visibleEntryIDs: Set<String> = []
    @State private var showJumpToLatestButton = false
    @State private var showSubmissionFeedback = false

    init(store: TimeNoteStore, title: String? = nil, shouldAutoFocusInput: Bool = true, compactLayout: Bool = false) {
        self.store = store
        self.title = title
        self.shouldAutoFocusInput = shouldAutoFocusInput
        self.compactLayout = compactLayout
    }

    var body: some View {
        VStack(spacing: 0) {
            if let title {
                HStack {
                    Text(title)
                        .font(compactLayout ? .callout.weight(.semibold) : .headline)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, compactLayout ? 10 : 12)
                Divider()
            }

            ScrollViewReader { proxy in
                ZStack(alignment: .topTrailing) {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(store.displayedEntries) { entry in
                                EntryRowView(
                                    entry: entry,
                                    isHighlighted: store.highlightedEntryID == entry.id
                                ) { timeText, noteText in
                                    store.updateEntry(entry.id, timeText: timeText, noteText: noteText)
                                }
                                .id(entry.id)
                                .onAppear {
                                    visibleEntryIDs.insert(entry.id)
                                    if entry.id == store.displayedEntries.first?.id {
                                        showJumpToLatestButton = false
                                    }
                                }
                                .onDisappear {
                                    visibleEntryIDs.remove(entry.id)
                                }
                            }
                        }
                        .padding(16)
                    }
                    .background(ColorTokens.windowBackground)
                    .onChange(of: store.highlightedEntryID) { _, newValue in
                        guard let newValue else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                    .onChange(of: store.latestEntry?.id) { oldValue, newValue in
                        guard let newValue else { return }
                        let shouldFollowLatest = store.consumeForcedLatestScroll()
                            || oldValue == nil
                            || oldValue.flatMap { visibleEntryIDs.contains($0) } == true
                        if shouldFollowLatest {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(newValue, anchor: .top)
                            }
                            showJumpToLatestButton = false
                        } else {
                            showJumpToLatestButton = true
                        }
                    }
                    if showJumpToLatestButton, let latestID = store.latestEntry?.id {
                        Button("回到最新") {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(latestID, anchor: .top)
                            }
                            showJumpToLatestButton = false
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(16)
                    }
                }
            }

            Divider()

            VStack(spacing: compactLayout ? 8 : 10) {
                if let similarEntryText {
                    HStack(spacing: 8) {
                        Image(systemName: "text.magnifyingglass")
                            .foregroundStyle(.secondary)
                        Text("相似记录：\(similarEntryText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .font(compactLayout ? .caption2 : .caption)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if showSubmissionFeedback, let lastSubmittedAt = store.lastSubmittedAt {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("已记录 \(TimeFormats.clockString(from: lastSubmittedAt)) 「\(truncatedSubmittedNote)」")
                            .font(compactLayout ? .caption2 : .caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                HStack(spacing: 12) {
                    ZStack(alignment: .topLeading) {
                        if store.entryInputText.isEmpty {
                            Text("输入内容后按 Enter 快速记录，Shift+Enter 换行")
                                .foregroundStyle(.secondary)
                                .font(compactLayout ? .caption : .body)
                                .padding(.horizontal, compactLayout ? 12 : 14)
                                .padding(.top, compactLayout ? 9 : 10)
                                .padding(.bottom, compactLayout ? 9 : 10)
                                .allowsHitTesting(false)
                        }
                        SubmitLogInputView(
                            text: $store.entryInputText,
                            focusToken: shouldAutoFocusInput ? store.inputFocusNonce : -1,
                            shouldAutoFocus: shouldAutoFocusInput,
                            onHistoryPrevious: {
                                store.recallPreviousInput()
                            },
                            onHistoryNext: {
                                store.recallNextInput()
                            }
                        ) {
                            store.submitMainLogEntry()
                        }
                    }
                    .frame(minHeight: compactLayout ? 56 : 64, maxHeight: compactLayout ? 82 : 96)

                    Button("提交") {
                        store.submitMainLogEntry()
                    }
                    .controlSize(compactLayout ? .small : .regular)
                }

                HStack {
                    Spacer()
                    if shouldShowShortcutHint, compactLayout == false {
                        Text("Enter 提交 · Shift+Enter 换行")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: similarEntryText)
            .animation(.easeInOut(duration: 0.25), value: showSubmissionFeedback)
            .padding(.horizontal, compactLayout ? 10 : 12)
            .padding(.vertical, compactLayout ? 8 : 10)
            .background(.thickMaterial)
        }
        .onChange(of: store.submissionFeedbackToken) { _, newValue in
            guard newValue > 0 else { return }
            if shortcutHintUses < 4 {
                shortcutHintUses += 1
            }
            showSubmissionFeedback = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                showSubmissionFeedback = false
            }
        }
        .onChange(of: store.selectedProjectID) { _, _ in
            visibleEntryIDs.removeAll()
            showJumpToLatestButton = false
        }
        .onChange(of: store.entries.count) { _, _ in
            visibleEntryIDs.removeAll()
        }
    }

    private var similarEntryText: String? {
        let current = store.entryInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty == false else { return nil }
        let normalizedCurrent = current.replacingOccurrences(of: " ", with: "").lowercased()
        guard normalizedCurrent.count >= 3 else { return nil }

        return store.displayedEntries
            .map(\.noteText)
            .first { note in
                let normalizedNote = note.replacingOccurrences(of: " ", with: "").lowercased()
                guard normalizedNote.isEmpty == false else { return false }
                return normalizedNote.contains(normalizedCurrent)
                    || normalizedCurrent.contains(normalizedNote)
                    || normalizedNote.hasPrefix(normalizedCurrent)
            }
    }

    private var shouldShowShortcutHint: Bool {
        shortcutHintUses < 4
    }

    private var truncatedSubmittedNote: String {
        let trimmed = store.lastSubmittedNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 24 else { return trimmed }
        return String(trimmed.prefix(24)) + "..."
    }
}

private struct TextTabEditor: View {
    @ObservedObject var store: TimeNoteStore
    @State private var draftBody = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.selectedTab?.title ?? "文本标签")
                    .font(.headline.weight(.semibold))
                Spacer()
                if store.currentTextTabIsSaving {
                    Label("正在保存", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.10))
                        )
                } else if let savedAt = store.currentTextTabLastSavedAt {
                    Text("已保存 \(TimeFormats.clockString(from: savedAt))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.accentColor.opacity(0.10))
                        )
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.thinMaterial)

            Divider()

            TextEditor(text: Binding(
                get: { draftBody },
                set: {
                    draftBody = $0
                    store.updateCurrentTextTabBody($0)
                }
            ))
            .font(.body)
            .lineSpacing(4)
            .padding(20)
            .scrollContentBackground(.hidden)
            .focused($editorFocused)
        }
        .background(ColorTokens.windowBackground)
        .onAppear {
            draftBody = store.currentTextTabBody
            editorFocused = true
        }
        .onChange(of: store.selectedTabID) { _, _ in
            draftBody = store.currentTextTabBody
            editorFocused = true
        }
        .onChange(of: store.currentTextTabBody) { _, newValue in
            if draftBody != newValue {
                draftBody = newValue
            }
        }
    }
}

private struct SearchResultsView: View {
    @ObservedObject var store: TimeNoteStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("搜索结果")
                    .font(.headline)
                Spacer()
                Text("\(store.searchResults.count) 条")
                    .foregroundStyle(.secondary)
                Button("清空搜索") {
                    store.clearSearch()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if store.searchResults.isEmpty {
                ContentUnavailableView(
                    "没有找到结果",
                    systemImage: "magnifyingglass",
                    description: Text("试试别的关键词。")
                )
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.searchResults) { result in
                            Button {
                                store.activateSearchResult(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(result.primaryText)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(result.kind.label)
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(kindBadgeColor(result.kind))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule()
                                                    .fill(kindBadgeColor(result.kind).opacity(0.12))
                                            )
                                    }

                                    Text(result.secondaryText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    if result.snippet.isEmpty == false {
                                        Text(result.snippet)
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(ColorTokens.entryCardBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(ColorTokens.entryCardBorder, lineWidth: 1)
                                        )
                                )
                                .shadow(color: Color.black.opacity(0.03), radius: 2, x: 0, y: 1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(.regularMaterial)
        .onExitCommand {
            store.clearSearch()
        }
    }

    private func kindBadgeColor(_ kind: SearchResultKind) -> Color {
        switch kind {
        case .logEntry:
            return ColorTokens.timestampAmber
        case .tabBody:
            return .green
        case .tabTitle:
            return .blue
        case .attachment:
            return .secondary
        case .project:
            return .purple
        }
    }
}

private struct SubmitLogInputView: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    let shouldAutoFocus: Bool
    let onHistoryPrevious: () -> Void
    let onHistoryNext: () -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onHistoryPrevious: onHistoryPrevious,
            onHistoryNext: onHistoryNext
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let textView = SubmitAwareTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onHistoryPrevious = onHistoryPrevious
        textView.onHistoryNext = onHistoryNext
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.updateBorderAppearance()

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        }
        if shouldAutoFocus, context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let onSubmit: () -> Void
        let onHistoryPrevious: () -> Void
        let onHistoryNext: () -> Void
        weak var textView: SubmitAwareTextView?
        var lastFocusToken = Int.min

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onHistoryPrevious: @escaping () -> Void,
            onHistoryNext: @escaping () -> Void
        ) {
            _text = text
            self.onSubmit = onSubmit
            self.onHistoryPrevious = onHistoryPrevious
            self.onHistoryNext = onHistoryNext
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
        }
    }
}

private final class SubmitAwareTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onHistoryPrevious: (() -> Void)?
    var onHistoryNext: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderAppearance()
    }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isPlainEnter = event.keyCode == 36 || event.keyCode == 76
        let isArrowUp = event.keyCode == 126
        let isArrowDown = event.keyCode == 125
        let shouldSubmit = isPlainEnter && modifiers.isEmpty
        if shouldSubmit {
            onSubmit?()
            return
        }
        if modifiers.isEmpty, isArrowUp, shouldRecallPreviousHistory {
            onHistoryPrevious?()
            return
        }
        if modifiers.isEmpty, isArrowDown, shouldRecallNextHistory {
            onHistoryNext?()
            return
        }
        super.keyDown(with: event)
    }

    fileprivate func updateBorderAppearance() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    private var shouldRecallPreviousHistory: Bool {
        guard selectedRange().length == 0 else { return false }
        return currentLineRange.location == 0
    }

    private var shouldRecallNextHistory: Bool {
        guard selectedRange().length == 0 else { return false }
        return NSMaxRange(currentLineRange) >= (string as NSString).length
    }

    private var currentLineRange: NSRange {
        let text = string as NSString
        let location = min(selectedRange().location, text.length)
        return text.lineRange(for: NSRange(location: location, length: 0))
    }
}

private struct EntryRowView: View {
    let entry: LogEntry
    let isHighlighted: Bool
    let onSave: (String, String) -> Void

    @State private var timeText: String
    @State private var noteText: String
    @State private var validationError: String?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var isHovered = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case time
        case note
    }

    init(entry: LogEntry, isHighlighted: Bool, onSave: @escaping (String, String) -> Void) {
        self.entry = entry
        self.isHighlighted = isHighlighted
        self.onSave = onSave
        _timeText = State(initialValue: TimeFormats.clockString(from: entry.recordedAt))
        _noteText = State(initialValue: entry.noteText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                TextField("HH:mm:ss", text: $timeText)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .textFieldStyle(.plain)
                    .foregroundStyle(ColorTokens.timestampAmber)
                    .frame(width: 100)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(ColorTokens.timestampAmber.opacity(0.10))
                    )
                    .focused($focusedField, equals: .time)
                    .onChange(of: timeText) { _, _ in
                        scheduleSave()
                    }

                TextField("记录内容", text: $noteText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .font(.body)
                    .focused($focusedField, equals: .note)
                    .onChange(of: noteText) { _, _ in
                        scheduleSave()
                    }
            }

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button {
                    copyEntryLine()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .opacity(isHovered ? 1 : 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.10) : ColorTokens.entryCardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isHighlighted ? Color.accentColor.opacity(0.25) : ColorTokens.entryCardBorder, lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.04), radius: 3, x: 0, y: 1)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button("复制整行") {
                copyEntryLine()
            }
        }
        .onChange(of: entry.recordedAt) { _, newValue in
            if focusedField != .time {
                timeText = TimeFormats.clockString(from: newValue)
            }
        }
        .onChange(of: entry.noteText) { _, newValue in
            if focusedField != .note {
                noteText = newValue
            }
        }
        .onChange(of: focusedField) { _, newValue in
            if newValue == nil {
                flushPendingSave()
            } else {
                validationError = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .timeNoteFlushPendingEdits)) { _ in
            // 窗口失活时由 store 统一通知，立即 flush 本地草稿
            flushPendingSave()
        }
        .onDisappear {
            // 视图销毁时（切项目/切标签）立即 flush，防止草稿丢失
            flushPendingSave()
        }
    }

    private func scheduleSave() {
        validationError = nil
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard Task.isCancelled == false else { return }
            flushPendingSave()
        }
    }

    private func flushPendingSave() {
        autosaveTask?.cancel()
        validationError = nil

        guard timeText != TimeFormats.clockString(from: entry.recordedAt) || noteText != entry.noteText else {
            return
        }
        guard TimeFormats.parseClock(timeText, relativeTo: entry.recordedAt) != nil else {
            validationError = "时间格式必须是 HH:mm:ss（原时间 \(TimeFormats.clockString(from: entry.recordedAt))）"
            return
        }
        guard noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            validationError = "记录内容不能为空"
            return
        }
        onSave(timeText, noteText)
    }

    private func copyEntryLine() {
        let line = "\(timeText) \(noteText)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }
}

private enum PendingConfirmation: Identifiable {
    case archiveProject(id: String, name: String)
    case deleteProject(id: String, name: String)
    case deleteAttachment(id: String, name: String)
    case deleteTab(id: String, name: String)

    var id: String {
        switch self {
        case .archiveProject(let id, _):
            return "archive-\(id)"
        case .deleteProject(let id, _):
            return "delete-project-\(id)"
        case .deleteAttachment(let id, _):
            return "delete-attachment-\(id)"
        case .deleteTab(let id, _):
            return "delete-tab-\(id)"
        }
    }

    var title: String {
        switch self {
        case .archiveProject:
            return "确认归档项目？"
        case .deleteProject:
            return "确认删除项目？"
        case .deleteAttachment:
            return "确认删除附件？"
        case .deleteTab:
            return "确认删除标签？"
        }
    }

    var message: String {
        switch self {
        case .archiveProject(_, let name):
            return "“\(name)” 将从主列表移除，但仍可在后续归档视图中恢复。"
        case .deleteProject(_, let name):
            return "“\(name)” 以及其中的标签和记录会被永久删除。"
        case .deleteAttachment(_, let name):
            return "“\(name)” 的记录和已导入文件都会被删除。"
        case .deleteTab(_, let name):
            return "“\(name)” 中的文本内容将被删除。"
        }
    }

    var confirmLabel: String {
        switch self {
        case .archiveProject:
            return "归档"
        case .deleteProject, .deleteAttachment, .deleteTab:
            return "删除"
        }
    }

    var role: ButtonRole? {
        switch self {
        case .archiveProject:
            return nil
        case .deleteProject, .deleteAttachment, .deleteTab:
            return .destructive
        }
    }
}
