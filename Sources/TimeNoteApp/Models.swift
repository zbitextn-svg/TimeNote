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

enum SearchResultKind: String, Equatable {
    case project
    case tabTitle = "tab_title"
    case tabBody = "tab_body"
    case logEntry = "log_entry"
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
        case .attachment:
            return "附件"
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
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }

    private static func makeShortDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
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
