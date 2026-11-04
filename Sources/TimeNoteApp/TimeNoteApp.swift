import AppKit
import SwiftUI

@main
struct TimeNoteApp: App {
    var body: some Scene {
        WindowGroup {
            RootWindowView()
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建项目") {
                    NotificationCenter.default.post(name: .timeNoteCreateProject, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button("新建文本标签") {
                    NotificationCenter.default.post(name: .timeNoteNewTextTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Divider()

                Button("导出项目…") {
                    NotificationCenter.default.post(name: .timeNoteExportProject, object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)
            }

            CommandMenu("场记") {
                Button("记录场记") {
                    NotificationCenter.default.post(name: .timeNoteFocusInput, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)

                Button("搜索") {
                    NotificationCenter.default.post(name: .timeNoteFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Divider()

                ForEach(1...9, id: \.self) { number in
                    Button(number == 1 ? "主场记" : "标签 \(number)") {
                        NotificationCenter.default.post(name: .timeNoteSelectTab, object: number - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                }

                Divider()

                Button("复制当前标签全部内容") {
                    NotificationCenter.default.post(name: .timeNoteCopyCurrentTab, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("显示/隐藏附件") {
                    NotificationCenter.default.post(name: .timeNoteToggleAttachments, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .option])

                Button("立即备份") {
                    NotificationCenter.default.post(name: .timeNoteCreateBackup, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }
    }
}

private struct RootWindowView: View {
    @StateObject private var store = TimeNoteStore()

    var body: some View {
        ContentView(store: store)
            .onAppear {
                #if DEBUG
                // 开发调试：TIMENOTE_APPEARANCE=light/dark 强制外观，便于检查两套配色
                switch ProcessInfo.processInfo.environment["TIMENOTE_APPEARANCE"] {
                case "light":
                    NSApp.appearance = NSAppearance(named: .aqua)
                case "dark":
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                default:
                    break
                }
                #endif
            }
    }
}

extension Notification.Name {
    static let timeNoteCreateProject = Notification.Name("TimeNote.createProject")
    static let timeNoteFocusSearch = Notification.Name("TimeNote.focusSearch")
    static let timeNoteCreateBackup = Notification.Name("TimeNote.createBackup")
    static let timeNoteNewTextTab = Notification.Name("TimeNote.newTextTab")
    static let timeNoteFocusInput = Notification.Name("TimeNote.focusInput")
    static let timeNoteSelectTab = Notification.Name("TimeNote.selectTab")
    static let timeNoteToggleAttachments = Notification.Name("TimeNote.toggleAttachments")
    static let timeNoteExportProject = Notification.Name("TimeNote.exportProject")
    static let timeNoteCopyCurrentTab = Notification.Name("TimeNote.copyCurrentTab")
    /// 窗口失活/退出时通知视图层立即 flush 自身草稿（EntryRowView 等）
    static let timeNoteFlushPendingEdits = Notification.Name("TimeNote.flushPendingEdits")
}
