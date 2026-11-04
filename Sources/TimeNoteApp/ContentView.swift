import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: TimeNoteStore
    @AppStorage("TimeNote.showsArchivedProjects") private var showsArchivedProjects = false
    @State private var projectTitleDraft = ""
    @State private var renamingTabID: String?
    @State private var renamingTabTitle = ""
    @State private var pendingConfirmation: PendingConfirmation?
    @FocusState private var renamingTabFocused: Bool
    @FocusState private var searchFieldFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var projectTitleSaveTask: Task<Void, Never>?
    @State private var isDropTargeted = false
    /// 递增时让文本标签编辑器获得焦点（重命名回车确认后使用）
    @State private var editorFocusRequest = 0
    /// 重命名输入框是否真正获得过焦点（用于区分"点了别处"和"焦点还没落到输入框上"）
    @State private var renameFieldDidGainFocus = false

    var body: some View {
        layoutWithDialogs
            .onAppear {
                alignSidebarToSelection()
                projectTitleDraft = store.selectedProject?.title ?? ""
            }
            .onChange(of: store.selectedProjectID) { oldProjectID, _ in
                // 切换项目前，立即 flush 旧项目的标题重命名草稿，避免被 cancel 丢失
                flushPendingProjectRename(projectID: oldProjectID)
                alignSidebarToSelection()
                projectTitleDraft = store.selectedProject?.title ?? ""
                renamingTabID = nil
            }
            .onChange(of: store.selectedTabID) { _, newTabID in
                // 正在重命名时切到了别的标签（点击、⌘数字、搜索跳转等）：先提交重命名
                if let renaming = renamingTabID, renaming != newTabID {
                    finishRenaming(tabID: renaming)
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                // 窗口失活/进入后台时，立即 flush 所有待保存草稿
                if newPhase == .inactive || newPhase == .background {
                    flushAllPendingEdits()
                }
            }
            .modifier(CommandHandlers(
                store: store,
                focusSearch: { searchFieldFocused = true },
                newTextTab: { createTextTabAndRename() },
                flushAll: { flushAllPendingEdits() }
            ))
    }

    private var layout: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .inspector(isPresented: $store.isAttachmentPanelPresented) {
                    AttachmentInspector(store: store) { attachment in
                        pendingConfirmation = .deleteAttachment(id: attachment.id, name: attachment.fileName)
                    }
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 420)
                }
                .toolbar { detailToolbar }
        }
        .navigationTitle(store.selectedProject?.title ?? "TimeNote")
        .modifier(HiddenToolbarTitle())
        .tint(Theme.accent)
        .frame(minWidth: 920, minHeight: 580)
        .background(WindowAccessor { window in
            store.attachWindow(window)
        })
    }

    private var layoutWithDialogs: some View {
        layout
            .alert(currentAlertTitle, isPresented: alertIsPresented) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(currentAlertMessage ?? "")
            }
            .confirmationDialog(
                pendingConfirmation?.title ?? "",
                isPresented: confirmationIsPresented,
                titleVisibility: .visible
            ) {
                confirmationButtons
            } message: {
                Text(pendingConfirmation?.message ?? "")
            }
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { currentAlertMessage != nil },
            set: { isPresented in
                guard isPresented == false else { return }
                if store.startupNotice != nil {
                    store.startupNotice = nil
                } else if store.transientError != nil {
                    store.transientError = nil
                } else {
                    store.transientNotice = nil
                }
            }
        )
    }

    private var confirmationIsPresented: Binding<Bool> {
        Binding(
            get: { pendingConfirmation != nil },
            set: { isPresented in
                if isPresented == false {
                    pendingConfirmation = nil
                }
            }
        )
    }

    @ViewBuilder
    private var confirmationButtons: some View {
        if let confirmation = pendingConfirmation {
            Button(confirmation.confirmLabel, role: confirmation.role) {
                performConfirmation(confirmation)
                pendingConfirmation = nil
            }
            Button("取消", role: .cancel) {
                pendingConfirmation = nil
            }
        }
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            SidebarSearchField(
                text: Binding(
                    get: { store.searchQuery },
                    set: { store.updateSearchQuery($0) }
                ),
                isFocused: $searchFieldFocused,
                onClear: { store.clearSearch() }
            )
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)

            List(selection: Binding(
                get: { store.selectedProjectID },
                set: { newValue in
                    guard let newValue, newValue != store.selectedProjectID else { return }
                    store.clearSearch()
                    store.selectProject(id: newValue)
                }
            )) {
                Section("进行中") {
                    if store.projects.isEmpty {
                        Text("暂无项目")
                            .font(.callout)
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        ForEach(store.projects) { project in
                            projectRow(project)
                        }
                    }
                }

                if store.archivedProjects.isEmpty == false {
                    Section(isExpanded: Binding(
                        get: { showsArchivedProjects },
                        set: { newValue in
                            showsArchivedProjects = newValue
                            syncSelectionForSidebar()
                        }
                    )) {
                        ForEach(store.archivedProjects) { project in
                            projectRow(project)
                        }
                    } header: {
                        HStack {
                            Text("已归档")
                            Spacer()
                            Text("\(store.archivedProjects.count)")
                                .monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 8) {
                Button {
                    store.createProject()
                } label: {
                    Label("新建项目", systemImage: "plus")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .help("新建项目（⌘N）")

                Text(AppInfo.displayVersion)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .help("TimeNote 版本")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
    }

    @ViewBuilder
    private func projectRow(_ project: Project) -> some View {
        ProjectRowView(project: project, stats: store.stats(for: project.id))
            .tag(Optional(project.id))
            .contextMenu {
                Button("复制项目") {
                    store.selectProject(id: project.id)
                    store.duplicateSelectedProject()
                }

                if project.isArchived {
                    Button("恢复项目") {
                        store.unarchiveProject(id: project.id)
                    }
                } else {
                    Button("归档项目") {
                        pendingConfirmation = .archiveProject(id: project.id, name: project.title)
                    }
                }

                Divider()

                Button("删除项目…", role: .destructive) {
                    pendingConfirmation = .deleteProject(id: project.id, name: project.title)
                }
            }
    }

    // MARK: - 详情区

    @ViewBuilder
    private var detail: some View {
        if store.selectedProject != nil {
            VStack(spacing: 0) {
                header
                tabStrip
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                contentBody
            }
            .background(Theme.canvas.ignoresSafeArea())
            .overlay(alignment: .top) {
                ZStack {
                    toastOverlay
                }
                .animation(.spring(duration: 0.3), value: store.toast?.id)
            }
            .overlay {
                if isDropTargeted {
                    DropHighlightView()
                }
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
                handleAttachmentDrop(providers: providers)
            }
        } else {
            ContentUnavailableView {
                Label("还没有项目", systemImage: "list.bullet.clipboard")
            } description: {
                Text("新建一个项目，就可以开始现场记录。")
            } actions: {
                Button("新建项目") {
                    store.createProject()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas.ignoresSafeArea())
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.toggleWindowPinned()
            } label: {
                Label(
                    store.isWindowPinned ? "取消置顶" : "窗口置顶",
                    systemImage: store.isWindowPinned ? "pin.fill" : "pin"
                )
            }
            .help(store.isWindowPinned ? "取消窗口置顶" : "让窗口始终显示在最前面")

            Button {
                store.isAttachmentPanelPresented.toggle()
            } label: {
                Label("附件", systemImage: store.attachments.isEmpty ? "paperclip" : "paperclip.badge.ellipsis")
            }
            .help("显示或隐藏附件（⌥⌘A）")
            .disabled(store.selectedProject == nil)

            Button {
                store.exportCurrentProject()
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .help("把整个项目导出为 .txt（⌘E）")
            .disabled(store.selectedProject == nil)

            Menu {
                Button("复制当前标签全部内容") {
                    store.copyCurrentTab()
                }
                Button("立即备份") {
                    store.createManualBackup()
                }

                Divider()

                Button("复制项目") {
                    store.duplicateSelectedProject()
                }

                if let selectedProject = store.selectedProject {
                    if selectedProject.isArchived {
                        Button("恢复项目") {
                            store.unarchiveProject(id: selectedProject.id)
                        }
                    } else {
                        Button("归档项目…") {
                            pendingConfirmation = .archiveProject(id: selectedProject.id, name: selectedProject.title)
                        }
                    }

                    Button("删除项目…", role: .destructive) {
                        pendingConfirmation = .deleteProject(id: selectedProject.id, name: selectedProject.title)
                    }
                }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .help("更多操作")
            .disabled(store.selectedProject == nil)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField("项目标题", text: $projectTitleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .onChange(of: projectTitleDraft) { _, newValue in
                        scheduleProjectRename(newValue)
                    }
                    .onSubmit {
                        flushPendingProjectRename()
                        store.focusMainLogInput()
                    }

                if store.selectedProject?.isArchived == true {
                    Label("已归档", systemImage: "archivebox")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.surfaceMuted))
                }
            }

            HStack(spacing: 6) {
                Text(headerMetaText)
                if store.isWindowPinned {
                    Text("·")
                    Label("已置顶", systemImage: "pin.fill")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.pageHorizontal)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerMetaText: String {
        let stats = store.selectedProjectStats
        let count = stats?.entryCount ?? 0
        guard count > 0, let lastAt = stats?.lastRecordedAt else {
            return "还没有场记"
        }
        let dayText = TimeFormats.relativeDayLabel(for: lastAt) ?? TimeFormats.shortDateString(from: lastAt)
        return "\(count) 条场记 · 最近 \(dayText) \(TimeFormats.clockString(from: lastAt))"
    }

    // MARK: 标签栏

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(store.tabs.enumerated()), id: \.element.id) { index, tab in
                    if renamingTabID == tab.id, tab.kind == .text {
                        TextField("标签名", text: $renamingTabTitle)
                            .textFieldStyle(.plain)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(width: 150)
                            .background(CardBackground(radius: Theme.Radius.small + 1))
                            .focused($renamingTabFocused)
                            .onSubmit {
                                finishRenaming(tabID: tab.id)
                                // 回车确认后把光标交给正文编辑器，方便直接开始写
                                editorFocusRequest += 1
                            }
                            .onAppear {
                                // 输入框创建出来之后再请求焦点；
                                // 若在创建前就设置，焦点会落空并立刻被判定为"失焦"，重命名框一闪就关掉
                                Task { @MainActor in
                                    renamingTabFocused = true
                                }
                            }
                            .onExitCommand {
                                cancelRenaming()
                            }
                            .onChange(of: renamingTabFocused) { _, isFocused in
                                if isFocused {
                                    renameFieldDidGainFocus = true
                                } else if renameFieldDidGainFocus, renamingTabID == tab.id {
                                    // 只有真正拿到过焦点后再失焦，才算"点了别处、确认重命名"
                                    finishRenaming(tabID: tab.id)
                                }
                            }
                    } else {
                        TabPill(
                            tab: tab,
                            isSelected: store.selectedTabID == tab.id && isSearching == false,
                            badge: tab.kind == .mainLog ? store.entries.count : nil,
                            shortcutIndex: index < 9 ? index + 1 : nil,
                            onClose: tab.kind == .text ? { requestDeleteTab(tab) } : nil
                        )
                        .onTapGesture {
                            // 点了另一个标签：先提交正在进行的重命名（不必先按回车），再切换。
                            // 注意排除被重命名的标签本身——双击开始重命名时，第二下单击也会走到这里，
                            // 如果不排除，刚打开的重命名框会被立刻关掉。
                            if let renaming = renamingTabID, renaming != tab.id {
                                finishRenaming(tabID: renaming)
                            }
                            store.clearSearch()
                            store.selectTab(id: tab.id)
                        }
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                guard tab.kind == .text else { return }
                                startRenaming(tab)
                            }
                        )
                        .contextMenu {
                            if tab.kind == .text {
                                Button("重命名") {
                                    startRenaming(tab)
                                }
                                Button("左移") {
                                    store.moveTab(tabID: tab.id, direction: -1)
                                }
                                .disabled(index <= 1)
                                Button("右移") {
                                    store.moveTab(tabID: tab.id, direction: 1)
                                }
                                .disabled(index >= store.tabs.count - 1)
                                Divider()
                                Button("删除标签…", role: .destructive) {
                                    requestDeleteTab(tab)
                                }
                            } else {
                                Button("复制全部场记") {
                                    store.selectTab(id: tab.id)
                                    store.copyCurrentTab()
                                }
                            }
                        }
                    }
                }

                Button {
                    createTextTabAndRename()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(HoverIconButtonStyle())
                .help("新建文本标签（⌘T）")
                .padding(.leading, 2)
            }
            .padding(.horizontal, Theme.Spacing.pageHorizontal - 4)
            // 顶部留出位置给标签右上角的删除按钮，避免被滚动区域裁掉
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .padding(.top, -8)
    }

    // MARK: 内容

    private var isSearching: Bool {
        store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    @ViewBuilder
    private var contentBody: some View {
        if isSearching {
            SearchResultsView(store: store)
        } else if store.isOnMainLogTab {
            MainLogView(store: store) { entry in
                store.deleteEntry(entry.id)
            }
        } else {
            HSplitView {
                MainLogView(store: store, shouldAutoFocusInput: false, compactLayout: true) { entry in
                    store.deleteEntry(entry.id)
                }
                .frame(minWidth: 300, idealWidth: 440)
                TextTabEditor(
                    store: store,
                    allowsAutoFocus: renamingTabID == nil,
                    focusRequest: editorFocusRequest
                )
                    .frame(minWidth: 260)
            }
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = store.toast {
            ToastView(
                toast: toast,
                onAction: { store.performToastAction() },
                onDismiss: { store.dismissToast() }
            )
            .padding(.top, 104)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(toast.id)
        }
    }

    // MARK: - 行为

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
        if selectedProject.isArchived {
            showsArchivedProjects = true
        }
    }

    private func syncSelectionForSidebar() {
        let currentSelectionIsVisible = currentSidebarProjects.contains { $0.id == store.selectedProjectID }
        guard currentSelectionIsVisible == false else { return }
        store.selectProject(id: currentSidebarProjects.first?.id)
    }

    private var currentSidebarProjects: [Project] {
        store.projects + (showsArchivedProjects ? store.archivedProjects : [])
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

    private func scheduleProjectRename(_ title: String) {
        guard let projectID = store.selectedProjectID else { return }
        projectTitleSaveTask?.cancel()
        projectTitleSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
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

    /// 点标签右上角的 × 或右键「删除标签」：空标签直接删除，有内容时先确认
    private func requestDeleteTab(_ tab: TabItem) {
        guard tab.kind == .text else { return }
        if renamingTabID == tab.id {
            cancelRenaming()
        }
        if store.textTabHasContent(tab.id) {
            pendingConfirmation = .deleteTab(id: tab.id, name: tab.title)
        } else {
            store.deleteTab(tabID: tab.id)
        }
    }

    private func createTextTabAndRename() {
        guard store.selectedProject != nil else { return }
        if let renaming = renamingTabID {
            finishRenaming(tabID: renaming)
        }
        store.clearSearch()
        if let tabID = store.addTextTab(),
           let tab = store.tabs.first(where: { $0.id == tabID }) {
            startRenaming(tab)
        }
    }

    private func startRenaming(_ tab: TabItem) {
        if let renaming = renamingTabID, renaming != tab.id {
            finishRenaming(tabID: renaming)
        }
        store.selectTab(id: tab.id)
        renameFieldDidGainFocus = false
        renamingTabID = tab.id
        renamingTabTitle = tab.title
    }

    private func finishRenaming(tabID: String) {
        guard renamingTabID == tabID else { return }
        let trimmed = renamingTabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false, store.tabs.contains(where: { $0.id == tabID }) {
            store.renameTab(tabID: tabID, title: trimmed)
        }
        // 名称为空时保留原名，不再弹窗打断
        renamingTabID = nil
        renamingTabTitle = ""
        renamingTabFocused = false
        renameFieldDidGainFocus = false
    }

    private func cancelRenaming() {
        renamingTabID = nil
        renamingTabTitle = ""
        renamingTabFocused = false
        renameFieldDidGainFocus = false
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
                    store.importAttachments(from: [url])
                }
            }
        }
        return true
    }
}

/// 菜单命令与应用生命周期通知的处理（拆出来以减轻类型检查负担）
private struct CommandHandlers: ViewModifier {
    @ObservedObject var store: TimeNoteStore
    let focusSearch: () -> Void
    let newTextTab: () -> Void
    let flushAll: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .timeNoteFocusSearch)) { _ in
                focusSearch()
            }
            .onReceive(NotificationCenter.default.publisher(for: .timeNoteCreateProject)) { _ in
                store.createProject()
            }
            .onReceive(NotificationCenter.default.publisher(for: .timeNoteCreateBackup)) { _ in
                store.createManualBackup()
            }
            .onReceive(NotificationCenter.default.publisher(for: .timeNoteNewTextTab)) { _ in
                newTextTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .timeNoteFocusInput)) { _ in
                store.clearSearch()
                store.focusMainLogInput()
            }
            .modifier(MoreCommandHandlers(store: store, flushAll: flushAll))
    }
}

private struct MoreCommandHandlers: ViewModifier {
    @ObservedObject var store: TimeNoteStore
    let flushAll: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .timeNoteSelectTab)) { notification in
                if let index = notification.object as? Int {
                    store.clearSearch()
                    store.selectTab(atIndex: index)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .timeNoteToggleAttachments)) { _ in
                store.isAttachmentPanelPresented.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .timeNoteExportProject)) { _ in
                store.exportCurrentProject()
            }
            .onReceive(NotificationCenter.default.publisher(for: .timeNoteCopyCurrentTab)) { _ in
                store.copyCurrentTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                // NSApplication 级别兜底：覆盖 scenePhase 未捕获的失活场景
                flushAll()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                flushAll()
            }
    }
}

/// macOS 15+ 隐藏工具栏中的窗口标题（标题已显示在内容区，可直接编辑）；macOS 14 保持默认。
private struct HiddenToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

// MARK: - 侧边栏组件

private struct SidebarSearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            TextField("搜索全部项目", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused(isFocused)
                .onExitCommand {
                    onClear()
                }
            if text.isEmpty == false {
                Button {
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            } else {
                Text("⌘F")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

private struct ProjectRowView: View {
    let project: Project
    let stats: ProjectEntryStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        guard let stats, stats.entryCount > 0 else {
            return "空项目"
        }
        var parts = ["\(stats.entryCount) 条"]
        if let lastAt = stats.lastRecordedAt {
            parts.append(TimeFormats.relativeDayLabel(for: lastAt) ?? TimeFormats.shortDateString(from: lastAt))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 标签

private struct TabPill: View {
    let tab: TabItem
    let isSelected: Bool
    let badge: Int?
    let shortcutIndex: Int?
    /// 文本标签右上角的删除按钮；主场记传 nil，不显示
    var onClose: (() -> Void)? = nil
    @State private var isHovered = false
    @State private var isCloseHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.kind == .mainLog ? "list.bullet.rectangle" : "doc.text")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
            Text(tab.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(isSelected ? Theme.accentSoft : Theme.surfaceMuted))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.Radius.small + 1, style: .continuous)
                    .fill(Theme.surface)
                    .shadow(color: .black.opacity(0.06), radius: 1.5, y: 0.5)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.small + 1, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
            } else if isHovered {
                RoundedRectangle(cornerRadius: Theme.Radius.small + 1, style: .continuous)
                    .fill(Theme.hover)
            }
        }
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            if let onClose, isSelected || isHovered || isCloseHovered {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .heavy))
                        .foregroundStyle(isCloseHovered ? Color.white : Theme.textSecondary)
                        .frame(width: 16, height: 16)
                        .background(
                            Circle().fill(isCloseHovered ? Theme.danger : Theme.surfaceMuted)
                        )
                        .overlay(
                            Circle().strokeBorder(isCloseHovered ? Color.clear : Theme.hairline, lineWidth: 1)
                        )
                        .contentShape(Circle().inset(by: -4))
                }
                .buttonStyle(.plain)
                .onHover { isCloseHovered = $0 }
                .help("删除标签")
                .accessibilityLabel("删除标签“\(tab.title)”")
                .offset(x: 7, y: -7)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered || isSelected || isCloseHovered)
        .onHover { isHovered = $0 }
        .help(helpText)
    }

    private var helpText: String {
        var text = tab.kind == .mainLog ? "主场记" : "双击重命名，右键可排序或删除"
        if let shortcutIndex {
            text += "（⌘\(shortcutIndex)）"
        }
        return text
    }
}

// MARK: - 主场记

private struct MainLogView: View {
    @ObservedObject var store: TimeNoteStore
    @AppStorage("TimeNote.mainLogShortcutHintUses") private var shortcutHintUses = 0
    let shouldAutoFocusInput: Bool
    let compactLayout: Bool
    let onDeleteEntry: (LogEntry) -> Void
    @State private var visibleEntryIDs: Set<String> = []
    @State private var showJumpToLatestButton = false
    @State private var showSubmissionFeedback = false
    @State private var inputContentHeight: CGFloat = 38
    @State private var pendingScrollTarget: String?
    @State private var displayedProjectID: String?

    init(
        store: TimeNoteStore,
        shouldAutoFocusInput: Bool = true,
        compactLayout: Bool = false,
        onDeleteEntry: @escaping (LogEntry) -> Void
    ) {
        self.store = store
        self.shouldAutoFocusInput = shouldAutoFocusInput
        self.compactLayout = compactLayout
        self.onDeleteEntry = onDeleteEntry
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ZStack(alignment: .top) {
                    if store.entries.isEmpty {
                        emptyState
                    } else {
                        entryList
                    }

                    if showJumpToLatestButton, let latestID = store.latestEntry?.id {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(latestID, anchor: .center)
                            }
                            showJumpToLatestButton = false
                        } label: {
                            Label("有新记录", systemImage: "arrow.up")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Theme.accent))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .onAppear {
                    // 从搜索结果跳转过来时，视图是新建的，onChange 不会触发，这里补一次定位
                    if let highlighted = store.highlightedEntryID {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(120))
                            pendingScrollTarget = highlighted
                        }
                    }
                }
                .onChange(of: pendingScrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    pendingScrollTarget = nil
                }
                .onChange(of: store.highlightedEntryID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
                .onChange(of: store.selectedProjectID) { _, _ in
                    // 切换项目：回到列表顶部（最新的记录在最上面）
                    visibleEntryIDs.removeAll()
                    showJumpToLatestButton = false
                    displayedProjectID = store.selectedProjectID
                    proxy.scrollTo(Self.topAnchorID, anchor: .top)
                }
                .onChange(of: store.latestEntry?.id) { oldValue, newValue in
                    guard let newValue else { return }
                    // 项目切换引起的变化由上面的 onChange 处理
                    guard displayedProjectID == store.selectedProjectID else {
                        displayedProjectID = store.selectedProjectID
                        proxy.scrollTo(Self.topAnchorID, anchor: .top)
                        return
                    }
                    let shouldFollowLatest = store.consumeForcedLatestScroll()
                        || oldValue == nil
                        || oldValue.flatMap { visibleEntryIDs.contains($0) } == true
                    if shouldFollowLatest {
                        let isTopRow = store.displayedDayGroups.first?.entries.first?.id == newValue
                        withAnimation(.easeInOut(duration: 0.25)) {
                            if isTopRow {
                                proxy.scrollTo(Self.topAnchorID, anchor: .top)
                            } else {
                                proxy.scrollTo(newValue, anchor: .center)
                            }
                        }
                        showJumpToLatestButton = false
                    } else {
                        withAnimation { showJumpToLatestButton = true }
                    }
                }
            }

            composer
        }
        .background(Theme.canvas)
        .onChange(of: store.submissionFeedbackToken) { _, newValue in
            guard newValue > 0 else { return }
            if shortcutHintUses < 6 {
                shortcutHintUses += 1
            }
            withAnimation { showSubmissionFeedback = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation { showSubmissionFeedback = false }
            }
        }
        .onAppear {
            displayedProjectID = store.selectedProjectID
        }
    }

    private static let topAnchorID = "timenote-log-top"

    private var entryList: some View {
        let latestID = store.latestEntry?.id
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Color.clear
                    .frame(height: 0)
                    .id(Self.topAnchorID)
                ForEach(store.displayedDayGroups) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            EntryRowView(
                                entry: entry,
                                isHighlighted: store.highlightedEntryID == entry.id,
                                compact: compactLayout,
                                onSave: { timeText, noteText in
                                    store.updateEntry(entry.id, timeText: timeText, noteText: noteText)
                                },
                                onCopy: {
                                    store.copyEntry(entry)
                                },
                                onDelete: {
                                    onDeleteEntry(entry)
                                }
                            )
                            .id(entry.id)
                            .onAppear {
                                visibleEntryIDs.insert(entry.id)
                                if entry.id == latestID {
                                    showJumpToLatestButton = false
                                }
                            }
                            .onDisappear {
                                visibleEntryIDs.remove(entry.id)
                            }
                        }
                    } header: {
                        DayHeaderView(day: group.day, count: group.entries.count, compact: compactLayout)
                    }
                }
            }
            .padding(.horizontal, compactLayout ? 8 : Theme.Spacing.pageHorizontal - Theme.Spacing.rowHorizontal)
            .padding(.bottom, 16)
        }
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("还没有场记")
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)
            Text("在下方输入内容，按 Enter 记录第一条。\n时间会在你开始输入时自动锁定。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 输入区

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showSubmissionFeedback, let lastSubmittedAt = store.lastSubmittedAt {
                feedbackLine(
                    icon: "checkmark.circle.fill",
                    tint: Theme.success,
                    text: "已记录 \(TimeFormats.clockString(from: lastSubmittedAt))  \(truncatedSubmittedNote)"
                )
            } else if let similarEntryText {
                feedbackLine(
                    icon: "text.magnifyingglass",
                    tint: Theme.textTertiary,
                    text: "相似记录：\(similarEntryText)"
                )
            }

            HStack(alignment: .center, spacing: 10) {
                TimeLockBadge(lockedAt: store.pendingEntryStartedAt, compact: compactLayout) {
                    store.resetPendingEntryTime()
                }

                ZStack(alignment: .topLeading) {
                    if store.entryInputText.isEmpty {
                        Text(compactLayout ? "记录场记，Enter 提交" : "记录场记…  Enter 提交，Shift+Enter 换行")
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.leading, 13)
                            .padding(.top, 9)
                            .allowsHitTesting(false)
                    }
                    SubmitLogInputView(
                        text: $store.entryInputText,
                        contentHeight: $inputContentHeight,
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
                .frame(height: min(max(inputContentHeight, 38), compactLayout ? 84 : 120))
                .background(CardBackground(radius: Theme.Radius.medium))

                Button {
                    store.submitMainLogEntry()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(canSubmit ? Theme.accent : Theme.textTertiary.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .disabled(canSubmit == false)
                .help("记录（Enter）")
            }

            if shortcutHintUses < 6, compactLayout == false {
                Text("Enter 记录 · Shift+Enter 换行 · ↑↓ 历史输入 · 点时间可刷新")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, compactLayout ? 10 : Theme.Spacing.pageHorizontal)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(
            Theme.canvas
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
        )
    }

    private func feedbackLine(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .font(.caption)
        .transition(.opacity)
    }

    private var canSubmit: Bool {
        store.entryInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var similarEntryText: String? {
        let current = store.entryInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCurrent = current.replacingOccurrences(of: " ", with: "").lowercased()
        guard normalizedCurrent.count >= 3 else { return nil }

        return store.displayedEntries
            .lazy
            .map(\.noteText)
            .first { note in
                let normalizedNote = note.replacingOccurrences(of: " ", with: "").lowercased()
                guard normalizedNote.count >= 3 else { return false }
                return normalizedNote.contains(normalizedCurrent) || normalizedCurrent.contains(normalizedNote)
            }
    }

    private var truncatedSubmittedNote: String {
        let trimmed = store.lastSubmittedNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 28 else { return trimmed }
        return String(trimmed.prefix(28)) + "…"
    }
}

/// 输入框左侧的时间：未输入时显示实时时钟，开始输入后锁定并高亮，点击可刷新为当前时间。
private struct TimeLockBadge: View {
    let lockedAt: Date?
    let compact: Bool
    let onReset: () -> Void

    var body: some View {
        Button(action: onReset) {
            HStack(spacing: 4) {
                Image(systemName: lockedAt == nil ? "clock" : "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                if let lockedAt {
                    Text(TimeFormats.clockString(from: lockedAt))
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(TimeFormats.clockString(from: context.date))
                    }
                }
            }
            .font(Theme.timeFont)
            .monospacedDigit()
            .foregroundStyle(lockedAt == nil ? Theme.textTertiary : Theme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(lockedAt == nil ? Color.clear : Theme.accentSoft)
            )
            .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(lockedAt == nil)
        .help(lockedAt == nil ? "开始输入时会锁定这一刻的时间" : "已锁定开始输入的时间，点击刷新为当前时间")
    }
}

private struct DayHeaderView: View {
    let day: Date
    let count: Int
    let compact: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let relative = TimeFormats.relativeDayLabel(for: day) {
                Text(relative)
                    .foregroundStyle(Theme.textPrimary)
                Text(TimeFormats.dayHeaderString(from: day))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text(TimeFormats.dayHeaderString(from: day))
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer()
            Text("\(count) 条")
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, Theme.Spacing.rowHorizontal)
        .padding(.top, compact ? 10 : 14)
        .padding(.bottom, 6)
        .background(Theme.canvas)
    }
}

private struct EntryRowView: View {
    let entry: LogEntry
    let isHighlighted: Bool
    let compact: Bool
    let onSave: (String, String) -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

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

    init(
        entry: LogEntry,
        isHighlighted: Bool,
        compact: Bool,
        onSave: @escaping (String, String) -> Void,
        onCopy: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.entry = entry
        self.isHighlighted = isHighlighted
        self.compact = compact
        self.onSave = onSave
        self.onCopy = onCopy
        self.onDelete = onDelete
        _timeText = State(initialValue: TimeFormats.clockString(from: entry.recordedAt))
        _noteText = State(initialValue: entry.noteText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: compact ? 10 : 14) {
                TextField("HH:mm:ss", text: $timeText)
                    .textFieldStyle(.plain)
                    .font(Theme.timeFont)
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .frame(width: 68, alignment: .leading)
                    .focused($focusedField, equals: .time)
                    .onSubmit {
                        flushPendingSave(showErrors: true)
                    }

                TextField("记录内容", text: $noteText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1...8)
                    .lineSpacing(2)
                    .focused($focusedField, equals: .note)
                    .onChange(of: noteText) { _, _ in
                        scheduleNoteAutosave()
                    }

                HStack(spacing: 2) {
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("复制这一条")
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .help("删除这一条（可撤销）")
                }
                .buttonStyle(HoverIconButtonStyle())
                .opacity(isHovered && focusedField == nil ? 1 : 0)
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[VerticalAlignment.center] + 4
                }
            }

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .padding(.leading, compact ? 78 : 82)
            }
        }
        .padding(.horizontal, Theme.Spacing.rowHorizontal)
        .padding(.vertical, compact ? 6 : 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium - 2, style: .continuous)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium - 2, style: .continuous)
                .strokeBorder(focusedField != nil ? Theme.accent.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.18), value: isHighlighted)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityAction(named: "复制这一条") {
            onCopy()
        }
        .accessibilityAction(named: "删除这一条") {
            onDelete()
        }
        .contextMenu {
            Button("复制这一条") {
                onCopy()
            }
            Divider()
            Button("删除", role: .destructive) {
                onDelete()
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
        .onChange(of: focusedField) { oldValue, newValue in
            if newValue == nil || (oldValue == .time && newValue != .time) {
                flushPendingSave(showErrors: true)
            } else {
                validationError = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .timeNoteFlushPendingEdits)) { _ in
            // 窗口失活时由 store 统一通知，立即 flush 本地草稿
            flushPendingSave(showErrors: false)
        }
        .onDisappear {
            // 视图销毁时（切项目/切标签/滚出屏幕）立即 flush，防止草稿丢失
            flushPendingSave(showErrors: false)
        }
    }

    private var rowBackground: Color {
        if isHighlighted {
            return Theme.accentSoft
        }
        if focusedField != nil {
            return Theme.surface
        }
        if isHovered {
            return Theme.hover
        }
        return .clear
    }

    /// 只自动保存正文；时间修改要等编辑完成（回车或离开输入框）才保存，避免记录在编辑中途跳动位置
    private func scheduleNoteAutosave() {
        validationError = nil
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard Task.isCancelled == false else { return }
            let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, noteText != entry.noteText else { return }
            onSave(TimeFormats.clockString(from: entry.recordedAt), noteText)
        }
    }

    private func flushPendingSave(showErrors: Bool) {
        autosaveTask?.cancel()

        let originalTime = TimeFormats.clockString(from: entry.recordedAt)
        guard timeText != originalTime || noteText != entry.noteText else {
            validationError = nil
            return
        }
        guard TimeFormats.parseClock(timeText, relativeTo: entry.recordedAt) != nil else {
            if showErrors {
                validationError = "时间格式应为 HH:mm:ss（原时间 \(originalTime)）"
            } else {
                timeText = originalTime
            }
            return
        }
        guard noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            if showErrors {
                validationError = "内容不能为空；如需删除，请使用右侧的删除按钮"
            } else {
                noteText = entry.noteText
            }
            return
        }
        validationError = nil
        onSave(timeText, noteText)
    }
}

// MARK: - 文本标签

private struct TextTabEditor: View {
    @ObservedObject var store: TimeNoteStore
    /// 正在重命名标签时为 false：编辑器不能抢走标题输入框的焦点，
    /// 否则输入的标签名会跑进正文、重命名框也会被提前关闭。
    let allowsAutoFocus: Bool
    let focusRequest: Int
    @State private var draftBody = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Theme.accent)
                Text(store.selectedTab?.title ?? "文本标签")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                saveStatus
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            TextEditor(text: Binding(
                get: { draftBody },
                set: {
                    draftBody = $0
                    store.updateCurrentTextTabBody($0)
                }
            ))
            .font(Theme.bodyFont)
            .lineSpacing(5)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .scrollContentBackground(.hidden)
            .focused($editorFocused)

            HStack {
                Text("\(draftBody.count) 字")
                    .monospacedDigit()
                Spacer()
                Text("自动保存")
            }
            .font(.caption2)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .background(Theme.surface)
        .onAppear {
            draftBody = store.currentTextTabBody
            if allowsAutoFocus {
                editorFocused = true
            }
        }
        .onChange(of: store.selectedTabID) { _, _ in
            draftBody = store.currentTextTabBody
            if allowsAutoFocus {
                editorFocused = true
            }
        }
        .onChange(of: focusRequest) { _, _ in
            editorFocused = true
        }
        .onChange(of: store.currentTextTabBody) { _, newValue in
            if draftBody != newValue {
                draftBody = newValue
            }
        }
    }

    @ViewBuilder
    private var saveStatus: some View {
        if store.currentTextTabIsSaving {
            Label("正在保存", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        } else if let savedAt = store.currentTextTabLastSavedAt {
            Label("已保存 \(TimeFormats.clockString(from: savedAt))", systemImage: "checkmark")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - 搜索结果

private struct SearchResultsView: View {
    @ObservedObject var store: TimeNoteStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textTertiary)
                Text("“\(store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))” 的搜索结果")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(store.searchResults.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.surfaceMuted))
                Spacer()
                Button("清除搜索") {
                    store.clearSearch()
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Theme.Spacing.pageHorizontal)
            .padding(.vertical, 12)

            if store.searchResults.isEmpty, store.isSearchPending {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.searchResults.isEmpty {
                ContentUnavailableView(
                    "没有找到结果",
                    systemImage: "magnifyingglass",
                    description: Text("可以用空格分隔多个关键词，例如“24-3 OK”。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.searchResults) { result in
                            SearchResultRow(result: result, terms: terms) {
                                store.activateSearchResult(result)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.pageHorizontal - Theme.Spacing.rowHorizontal)
                    .padding(.bottom, 16)
                }
            }
        }
        .background(Theme.canvas)
    }

    private var terms: [String] {
        store.searchQuery
            .replacingOccurrences(of: "\"", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    let terms: [String]
    let onActivate: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onActivate) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: result.kind.systemImageName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .fill(tint.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(highlightedText(result.primaryText, terms: terms))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    if result.snippet.isEmpty == false {
                        Text(highlightedText(result.snippet, terms: terms))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                    Text("\(result.kind.label) · \(result.secondaryText)")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.rowHorizontal)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium - 2, style: .continuous)
                    .fill(isHovered ? Theme.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var tint: Color {
        switch result.kind {
        case .logEntry:
            return Theme.accent
        case .tabBody:
            return Theme.success
        case .tabTitle:
            return .blue
        case .attachment:
            return Theme.textSecondary
        case .project:
            return .purple
        }
    }
}

// MARK: - 附件面板

private struct AttachmentInspector: View {
    @ObservedObject var store: TimeNoteStore
    let onRequestDelete: (AttachmentItem) -> Void
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("附件")
                    .font(.system(size: 13, weight: .semibold))
                if store.attachments.isEmpty == false {
                    Text("\(store.attachments.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button {
                    store.importAttachments()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(HoverIconButtonStyle())
                .help("导入图片、音频或视频")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if store.attachments.isEmpty {
                dropZone
                    .padding(14)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(store.attachments) { attachment in
                                AttachmentRow(
                                    attachment: attachment,
                                    isHighlighted: store.highlightedAttachmentID == attachment.id,
                                    onOpen: { store.openAttachment(attachment) },
                                    onReveal: { store.revealAttachment(attachment) },
                                    onDelete: { onRequestDelete(attachment) }
                                )
                                .id(attachment.id)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .onChange(of: store.highlightedAttachmentID) { _, newValue in
                        guard let newValue else { return }
                        withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                    }
                }

                Text("把文件拖到窗口任意位置即可导入")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL? else {
                        return
                    }
                    Task { @MainActor in
                        store.importAttachments(from: [url])
                    }
                }
            }
            return providers.isEmpty == false
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(isDropTargeted ? Theme.accent : Theme.textTertiary)
            Text("拖入图片、音频或视频")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
            Button("选择文件…") {
                store.importAttachments()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Theme.accent : Theme.hairline,
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
        )
    }
}

private struct AttachmentRow: View {
    let attachment: AttachmentItem
    let isHighlighted: Bool
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: attachment.kind.systemImageName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.small + 1, style: .continuous)
                        .fill(Theme.accentSoft)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(attachment.kind.label) · \(ByteCountFormatter.string(fromByteCount: attachment.fileSize, countStyle: .file))")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium - 2, style: .continuous)
                .fill(isHighlighted ? Theme.accentSoft : (isHovered ? Theme.hover : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .help("双击打开")
        .contextMenu {
            Button("打开", action: onOpen)
            Button("在访达中显示", action: onReveal)
            Divider()
            Button("删除附件…", role: .destructive, action: onDelete)
        }
    }
}

// MARK: - 提示条 & 拖放

private struct ToastView: View {
    let toast: ToastMessage
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.style == .success ? "checkmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(toast.style == .success ? Theme.success : Theme.accent)
            Text(toast.text)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if let actionTitle = toast.actionTitle {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderless)
                    .font(.callout.weight(.semibold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        )
        .onTapGesture {
            if toast.actionTitle == nil {
                onDismiss()
            }
        }
    }
}

private struct DropHighlightView: View {
    var body: some View {
        ZStack {
            Theme.accent.opacity(0.06)
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(10)
            Label("松开以导入为附件", systemImage: "tray.and.arrow.down.fill")
                .font(.headline)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(.regularMaterial))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 输入框（NSTextView 封装：Enter 提交、Shift+Enter 换行、↑↓ 历史）

private struct SubmitLogInputView: NSViewRepresentable {
    @Binding var text: String
    @Binding var contentHeight: CGFloat
    let focusToken: Int
    let shouldAutoFocus: Bool
    let onHistoryPrevious: () -> Void
    let onHistoryNext: () -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, contentHeight: $contentHeight)
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
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 9)
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertionPointColor = NSColor(Theme.accent)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.recalculateHeight()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        // 每次更新时刷新回调，避免闭包捕获旧状态
        textView.onSubmit = onSubmit
        textView.onHistoryPrevious = onHistoryPrevious
        textView.onHistoryNext = onHistoryNext
        if textView.string != text, textView.hasMarkedText() == false {
            textView.string = text
            textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            context.coordinator.recalculateHeight()
        }
        if shouldAutoFocus, context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var contentHeight: CGFloat
        weak var textView: SubmitAwareTextView?
        var lastFocusToken = Int.min

        init(text: Binding<String>, contentHeight: Binding<CGFloat>) {
            _text = text
            _contentHeight = contentHeight
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
            recalculateHeight()
        }

        /// 根据文字排版高度让输入框随内容增高（上限由外部 frame 控制）
        func recalculateHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer
            else {
                return
            }
            layoutManager.ensureLayout(for: textContainer)
            let height = ceil(layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2)
            guard abs(height - contentHeight) > 0.5 else { return }
            Task { @MainActor [weak self] in
                self?.contentHeight = height
            }
        }
    }
}

private final class SubmitAwareTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onHistoryPrevious: (() -> Void)?
    var onHistoryNext: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let isPlainEnter = event.keyCode == 36 || event.keyCode == 76
        let isArrowUp = event.keyCode == 126
        let isArrowDown = event.keyCode == 125
        if isPlainEnter && modifiers.isEmpty {
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

// MARK: - 确认对话框

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
            return "归档这个项目？"
        case .deleteProject:
            return "删除这个项目？"
        case .deleteAttachment:
            return "删除这个附件？"
        case .deleteTab:
            return "删除这个标签？"
        }
    }

    var message: String {
        switch self {
        case .archiveProject(_, let name):
            return "“\(name)”会移到侧边栏的“已归档”中，随时可以恢复。"
        case .deleteProject(_, let name):
            return "“\(name)”的所有场记、文本标签和附件都会被永久删除，无法撤销。"
        case .deleteAttachment(_, let name):
            return "“\(name)”的记录和已导入的文件都会被删除。"
        case .deleteTab(_, let name):
            return "“\(name)”中的文本内容将被永久删除，无法撤销。"
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
