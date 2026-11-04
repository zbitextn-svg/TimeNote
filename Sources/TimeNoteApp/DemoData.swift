#if DEBUG
import Foundation

/// 开发调试用的演示数据。仅在 DEBUG 构建且设置了环境变量 `TIMENOTE_DEMO_SEED=1` 时写入，
/// 并且只在数据库还是全新状态（只有一个空的默认项目）时执行。
enum DemoData {
    static func seedIfNeeded(_ database: SQLiteDatabase) throws {
        let existing = try database.fetchProjects(includeArchived: true)
        let stats = try database.fetchEntryStats()
        guard existing.count <= 1, stats.isEmpty else { return }

        try database.performTransaction {
            for project in existing {
                try database.deleteProject(id: project.id)
            }

            let calendar = Calendar.current
            let today = calendar.startOfDay(for: .now)
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

            func at(_ day: Date, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
                calendar.date(bySettingHour: hour, minute: minute, second: second, of: day) ?? day
            }

            // 归档项目
            let archived = try database.createProject(title: "宣传片《城市之光》")
            if let tab = try database.fetchMainTab(projectID: archived.id) {
                try database.insertLogEntry(projectID: archived.id, tabID: tab.id, recordedAt: at(yesterday, 9, 0, 0), noteText: "全片收工")
            }
            try database.archiveProject(id: archived.id)

            // 访谈项目
            let interview = try database.createProject(title: "人物访谈 · 张老师")
            if let tab = try database.fetchMainTab(projectID: interview.id) {
                let rows: [(Int, Int, Int, String)] = [
                    (14, 2, 11, "A/B 机开机，收音正常"),
                    (14, 5, 40, "Q1 讲到童年在弄堂里学琴，情绪很好，可做开场"),
                    (14, 18, 3, "Q3 回答偏长，后期可剪 2'30\" 左右"),
                    (14, 26, 52, "窗外施工噪音，暂停 1 分钟"),
                ]
                for row in rows {
                    try database.insertLogEntry(projectID: interview.id, tabID: tab.id, recordedAt: at(yesterday, row.0, row.1, row.2), noteText: row.3)
                }
            }

            // 主演示项目
            let main = try database.createProject(title: "《夏至》第 12 天 · 外景")
            guard let mainTab = try database.fetchMainTab(projectID: main.id) else { return }
            let yesterdayRows: [(Int, Int, Int, String)] = [
                (17, 40, 5, "第 23 场收工，明早 6:30 集合"),
                (17, 12, 44, "23-4-2 OK，保留"),
                (16, 58, 20, "23-4-1 NG，女主台词卡住"),
            ]
            for row in yesterdayRows {
                try database.insertLogEntry(projectID: main.id, tabID: mainTab.id, recordedAt: at(yesterday, row.0, row.1, row.2), noteText: row.3)
            }
            let todayRows: [(Int, Int, Int, String)] = [
                (8, 2, 15, "开机，天气晴，顺光"),
                (8, 15, 47, "24-1-1 NG，跟焦虚了"),
                (8, 19, 3, "24-1-2 OK ★ 导演很满意，最后半拍有路人入画，后期可裁"),
                (8, 31, 26, "24-2-1 演员抢词"),
                (8, 34, 58, "24-2-2 OK"),
                (9, 2, 10, "换 B 机位，长焦 85mm"),
                (9, 10, 31, "24-3-1 飞机声，补录环境音 30 秒"),
                (9, 22, 9, "A 机换卡 A012 → A013"),
                (9, 40, 0, "24-3-3 OK ★ 情绪最好的一条"),
                (10, 5, 44, "转场至桥下，预计 20 分钟"),
                (10, 31, 18, "25-1-1 OK，道具自行车链条需要检查"),
            ]
            for row in todayRows {
                try database.insertLogEntry(projectID: main.id, tabID: mainTab.id, recordedAt: at(today, row.0, row.1, row.2), noteText: row.3)
            }

            let shotList = try database.createTextTab(projectID: main.id, title: "镜头表")
            try database.updateTabBody(
                tabID: shotList.id,
                body: """
                第 24 场 · 河堤 · 日外
                1. 全景：女主骑车入画，由远及近
                2. 中景：停车回头
                3. 特写：手里的信封

                第 25 场 · 桥下 · 日外
                1. 跟拍：自行车穿过桥洞
                """
            )
            _ = try database.createTextTab(projectID: main.id, title: "道具与服装")
        }
    }
}
#endif
