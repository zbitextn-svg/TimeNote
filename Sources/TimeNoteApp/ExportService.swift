import AppKit
import Foundation
import UniformTypeIdentifiers

/// 导出格式
enum ExportFormat: String, CaseIterable, Identifiable {
    case text
    case excel
    case pdf
    case package

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "文本"
        case .excel: return "Excel 场记单"
        case .pdf: return "PDF 场记单"
        case .package: return "完整资料包"
        }
    }

    var detail: String {
        switch self {
        case .text: return ".txt，方便粘贴到任何地方"
        case .excel: return ".xlsx，按日期、时间、内容分列"
        case .pdf: return ".pdf，排版好的场记单，可直接打印"
        case .package: return ".zip，场记单 + 录音文字 + 原始录音"
        }
    }

    var systemImageName: String {
        switch self {
        case .text: return "doc.plaintext"
        case .excel: return "tablecells"
        case .pdf: return "doc.richtext"
        case .package: return "shippingbox"
        }
    }

    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .excel: return "xlsx"
        case .pdf: return "pdf"
        case .package: return "zip"
        }
    }

    var contentType: UTType {
        switch self {
        case .text: return .plainText
        case .excel: return UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data
        case .pdf: return .pdf
        case .package: return .zip
        }
    }
}

struct ExportService {
    @MainActor
    func copyToPasteboard(_ content: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
    }

    @MainActor
    func export(content: String, suggestedFileName: String) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = sanitizeFileName(suggestedFileName) + ".txt"

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    /// 弹出保存面板，返回用户选择的位置；取消时返回 nil
    @MainActor
    func chooseDestination(format: ExportFormat, suggestedFileName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = sanitizeFileName(suggestedFileName) + "." + format.fileExtension
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// 一段录音的文字稿，每行「时:分:秒 文字」
    func transcriptText(for section: ProjectReport.RecordingSection) -> String {
        let recording = section.recording
        var lines = [
            "\(recording.title)",
            "开始：\(TimeFormats.shortDateString(from: recording.startedAt)) \(TimeFormats.clockString(from: recording.startedAt)) · 时长 \(DurationFormats.string(from: recording.duration))",
            "",
        ]
        if section.segments.isEmpty {
            lines.append("（没有转写文字）")
        } else {
            lines.append(contentsOf: section.segments.map { segment in
                "\(TimeFormats.clockString(from: recording.startedAt.addingTimeInterval(segment.start))) \(segment.text)"
            })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 弹出保存面板并写入数据；用户取消时返回 nil
    @MainActor
    func export(data: Data, format: ExportFormat, suggestedFileName: String) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = sanitizeFileName(suggestedFileName) + "." + format.fileExtension

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    func makeCurrentTabCopyContent(tab: TabItem, entries: [LogEntry]) -> String {
        switch tab.kind {
        case .mainLog:
            return logLines(for: entries).joined(separator: "\n")
        case .text:
            return tab.body
        }
    }

    /// 场记行。跨多天时在每天前插入日期分隔行，单日时保持原有 "HH:mm:ss 内容" 格式。
    func logLines(for entries: [LogEntry]) -> [String] {
        let groups = entries.groupedByDay(newestFirst: false)
        let showsDayHeaders = groups.count > 1
        var lines: [String] = []
        for (index, group) in groups.enumerated() {
            if showsDayHeaders {
                if index > 0 {
                    lines.append("")
                }
                lines.append("—— \(TimeFormats.shortDateString(from: group.day)) ——")
            }
            lines.append(contentsOf: group.entries.map { "\(TimeFormats.clockString(from: $0.recordedAt)) \($0.noteText)" })
        }
        return lines
    }

    func makeProjectExportContent(
        project: Project,
        tabs: [TabItem],
        entriesByTab: [String: [LogEntry]],
        recordings: [ProjectReport.RecordingSection] = []
    ) -> String {
        var lines: [String] = []
        lines.append("项目标题：\(project.title)")
        lines.append("导出日期：\(TimeFormats.shortDateString(from: .now))")
        lines.append("")

        for tab in tabs {
            lines.append("========== [\(tab.title)] ==========")
            switch tab.kind {
            case .mainLog:
                let rows = logLines(for: entriesByTab[tab.id, default: []])
                if rows.isEmpty {
                    lines.append("")
                } else {
                    lines.append(contentsOf: rows)
                }
            case .text:
                if tab.body.isEmpty {
                    lines.append("")
                } else {
                    lines.append(tab.body)
                }
            }
            lines.append("")
        }

        if recordings.isEmpty == false {
            lines.append("========== [录音文字] ==========")
            for section in recordings {
                lines.append(transcriptText(for: section))
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    func sanitizeFileName(_ fileName: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = fileName
            .components(separatedBy: illegal)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "TimeNote导出" : cleaned
    }
}

enum ExportError: LocalizedError {
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let message):
            return "导出失败：\(message)"
        }
    }
}
