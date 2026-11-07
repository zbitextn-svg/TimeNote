import Foundation

enum TabKind: String, CaseIterable, Codable {
    case mainLog = "main_log"
    case text
}

struct Project: Identifiable, Equatable {
    let id: String
    var title: String
    let isArchived: Bool
    let createdAt: Date
    let updatedAt: Date
    let archivedAt: Date?
}

struct TabItem: Identifiable, Equatable {
    let id: String
    let projectID: String
    let kind: TabKind
    var title: String
    var sortIndex: Int
    var body: String
}

struct ProjectEntryStats: Equatable {
    let entryCount: Int
    let lastRecordedAt: Date?
}

struct LogEntry: Identifiable, Equatable {
    let id: String
    let projectID: String
    let tabID: String
    var recordedAt: Date
    var noteText: String
    let createdAt: Date
    let updatedAt: Date
}

enum AttachmentKind: String, CaseIterable, Codable {
    case image
    case audio
    case video

    var label: String {
        switch self {
        case .image:
            return "图片"
        case .audio:
            return "音频"
        case .video:
            return "视频"
        }
    }

    var systemImageName: String {
        switch self {
        case .image:
            return "photo"
        case .audio:
            return "waveform"
        case .video:
            return "film"
        }
    }
}

struct AttachmentItem: Identifiable, Equatable {
    let id: String
    let projectID: String
    let fileName: String
    let relativePath: String
    let kind: AttachmentKind
    let fileSize: Int64
    let createdAt: Date
    let updatedAt: Date
}

/// 一段录音。录音按「开始时间 + 时长」对应到墙上时间，
/// 因此场记条目不需要额外字段：记录时间落在录音区间内，就能算出它在录音里的位置。
struct Recording: Identifiable, Equatable {
    enum Status: String {
        /// 正在录制（应用异常退出后会停留在这个状态，下次启动时恢复）
        case recording
        /// 正常结束
        case finished
        /// 录制中断（崩溃、断电等），已尽量恢复
        case interrupted
    }

    let id: String
    let projectID: String
    var title: String
    var relativePath: String
    let startedAt: Date
    var durationMs: Int64
    var fileSize: Int64
    var locale: String
    var status: Status
    let createdAt: Date
    var updatedAt: Date

    var duration: TimeInterval { TimeInterval(durationMs) / 1000 }
    var endedAt: Date { startedAt.addingTimeInterval(duration) }

    /// 某个时刻在这段录音里的位置（秒）；不在录音区间内时返回 nil。
    /// 正在录制的录音，区间截止到 `now`。
    func offset(of date: Date, now: Date = .now) -> TimeInterval? {
        let end = status == .recording ? now : endedAt
        guard date >= startedAt, date <= end else { return nil }
        return date.timeIntervalSince(startedAt)
    }
}

struct TranscriptSegment: Identifiable, Equatable {
    let id: String
    let recordingID: String
    let projectID: String
    let startMs: Int64
    let endMs: Int64
    var text: String

    var start: TimeInterval { TimeInterval(startMs) / 1000 }
    var end: TimeInterval { TimeInterval(endMs) / 1000 }
}

enum DurationFormats {
    /// 录音时长/位置：不足 1 小时显示 mm:ss，否则 h:mm:ss
    static func string(from seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

enum SearchResultKind: String, Equatable {
    case project
    case tabTitle = "tab_title"
    case tabBody = "tab_body"
    case logEntry = "log_entry"
    case transcript
    case attachment

    var label: String {
        switch self {
        case .project:
            return "项目"
        case .tabTitle:
            return "标签标题"
        case .tabBody:
            return "文本内容"
        case .logEntry:
            return "场记"
        case .transcript:
            return "录音文字"
        case .attachment:
            return "附件"
        }
    }

    var systemImageName: String {
        switch self {
        case .project:
            return "folder"
        case .tabTitle:
            return "rectangle.on.rectangle"
        case .tabBody:
            return "doc.text"
        case .logEntry:
            return "clock"
        case .transcript:
            return "waveform"
        case .attachment:
            return "paperclip"
        }
    }

    /// 搜索结果分组顺序：先导航型（项目、标签），再内容型。
    var sortRank: Int {
        switch self {
        case .project:
            return 0
        case .tabTitle:
            return 1
        case .logEntry:
            return 2
        case .tabBody:
            return 3
        case .transcript:
            return 4
        case .attachment:
            return 5
        }
    }
}

struct SearchResult: Identifiable, Equatable {
    let id: String
    let kind: SearchResultKind
    let projectID: String
    let tabID: String?
    let entryID: String?
    let attachmentID: String?
    let primaryText: String
    let secondaryText: String
    let snippet: String
    let updatedAt: Date
    /// 录音文字结果：所在录音与句子在录音中的位置（毫秒）
    var recordingID: String? = nil
    var recordingOffsetMs: Int64? = nil
}

enum TimeFormats {
    private static let iso8601ThreadKey = "TimeNote.iso8601Formatter"
    private static let clockThreadKey = "TimeNote.clockFormatter"
    private static let shortDateThreadKey = "TimeNote.shortDateFormatter"

    private static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func makeClockFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        // 跟随系统时区变化（外景跨时区拍摄时不需要重启应用）
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }

    private static func makeShortDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func threadLocalISO8601Formatter() -> ISO8601DateFormatter {
        if let formatter = Thread.current.threadDictionary[iso8601ThreadKey] as? ISO8601DateFormatter {
            return formatter
        }
        let formatter = makeISO8601Formatter()
        Thread.current.threadDictionary[iso8601ThreadKey] = formatter
        return formatter
    }

    private static func threadLocalClockFormatter() -> DateFormatter {
        if let formatter = Thread.current.threadDictionary[clockThreadKey] as? DateFormatter {
            return formatter
        }
        let formatter = makeClockFormatter()
        Thread.current.threadDictionary[clockThreadKey] = formatter
        return formatter
    }

    private static func threadLocalShortDateFormatter() -> DateFormatter {
        if let formatter = Thread.current.threadDictionary[shortDateThreadKey] as? DateFormatter {
            return formatter
        }
        let formatter = makeShortDateFormatter()
        Thread.current.threadDictionary[shortDateThreadKey] = formatter
        return formatter
    }

    static func iso8601String(from date: Date) -> String {
        threadLocalISO8601Formatter().string(from: date)
    }

    static func iso8601Date(from value: String) -> Date? {
        threadLocalISO8601Formatter().date(from: value)
    }

    static func clockString(from date: Date) -> String {
        threadLocalClockFormatter().string(from: date)
    }

    static func shortDateString(from date: Date) -> String {
        threadLocalShortDateFormatter().string(from: date)
    }

    /// 场记列表中的日期分组标题，例如 "11月4日 周三"；不是今年时带上年份。
    static func dayHeaderString(from date: Date, now: Date = .now) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let currentYear = calendar.component(.year, from: now)
        let weekday = weekdays[((components.weekday ?? 1) - 1 + 7) % 7]
        let dayText = "\(components.month ?? 0)月\(components.day ?? 0)日 \(weekday)"
        if components.year != currentYear, let year = components.year {
            return "\(year)年\(dayText)"
        }
        return dayText
    }

    /// 相对日期标签：今天 / 昨天，其它日期返回 nil。
    static func relativeDayLabel(for date: Date, now: Date = .now) -> String? {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDate(date, inSameDayAs: now) {
            return "今天"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天"
        }
        return nil
    }

    static func startOfDay(for date: Date) -> Date {
        Calendar.autoupdatingCurrent.startOfDay(for: date)
    }

    static func parseClock(_ value: String, relativeTo original: Date) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":")
        guard parts.count == 3 else { return nil }
        guard
            let hour = Int(parts[0]),
            let minute = Int(parts[1]),
            let second = Int(parts[2]),
            (0..<24).contains(hour),
            (0..<60).contains(minute),
            (0..<60).contains(second)
        else {
            return nil
        }

        var calendar = Calendar.current
        calendar.timeZone = .current

        let dayStart = calendar.startOfDay(for: original)
        let candidateOffsets = [-1, 0, 1]

        let candidates = candidateOffsets.compactMap { offset -> Date? in
            guard let shiftedDay = calendar.date(byAdding: .day, value: offset, to: dayStart) else {
                return nil
            }
            let dateComponents = calendar.dateComponents([.year, .month, .day], from: shiftedDay)
            var merged = DateComponents()
            merged.year = dateComponents.year
            merged.month = dateComponents.month
            merged.day = dateComponents.day
            merged.hour = hour
            merged.minute = minute
            merged.second = second
            return calendar.date(from: merged)
        }

        return candidates.min { lhs, rhs in
            abs(lhs.timeIntervalSince(original)) < abs(rhs.timeIntervalSince(original))
        }
    }
}

/// 按自然日分组的场记。
struct LogDayGroup: Identifiable, Equatable {
    let day: Date
    let entries: [LogEntry]

    var id: Date { day }
}

extension Array where Element == LogEntry {
    /// 按记录时间所在的自然日分组；`newestFirst` 为 true 时日期和组内条目都倒序。
    func groupedByDay(newestFirst: Bool) -> [LogDayGroup] {
        var groups: [LogDayGroup] = []
        var currentDay: Date?
        var bucket: [LogEntry] = []
        let ordered = newestFirst
            ? sorted { $0.recordedAt > $1.recordedAt || ($0.recordedAt == $1.recordedAt && $0.createdAt > $1.createdAt) }
            : sorted { $0.recordedAt < $1.recordedAt || ($0.recordedAt == $1.recordedAt && $0.createdAt < $1.createdAt) }

        for entry in ordered {
            let day = TimeFormats.startOfDay(for: entry.recordedAt)
            if day != currentDay {
                if let currentDay, bucket.isEmpty == false {
                    groups.append(LogDayGroup(day: currentDay, entries: bucket))
                }
                currentDay = day
                bucket = []
            }
            bucket.append(entry)
        }
        if let currentDay, bucket.isEmpty == false {
            groups.append(LogDayGroup(day: currentDay, entries: bucket))
        }
        return groups
    }

    var spansMultipleDays: Bool {
        guard let first else { return false }
        let firstDay = TimeFormats.startOfDay(for: first.recordedAt)
        return contains { TimeFormats.startOfDay(for: $0.recordedAt) != firstDay }
    }
}
