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

            CommandMenu("TimeNote") {
                Button("搜索") {
                    NotificationCenter.default.post(name: .timeNoteFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

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
    }
}

extension Notification.Name {
    static let timeNoteCreateProject = Notification.Name("TimeNote.createProject")
    static let timeNoteFocusSearch = Notification.Name("TimeNote.focusSearch")
    static let timeNoteCreateBackup = Notification.Name("TimeNote.createBackup")
    /// 窗口失活/退出时通知视图层立即 flush 自身草稿（EntryRowView 等）
    static let timeNoteFlushPendingEdits = Notification.Name("TimeNote.flushPendingEdits")
}
