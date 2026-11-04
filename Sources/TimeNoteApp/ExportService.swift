import AppKit
import Foundation

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

    func makeCurrentTabCopyContent(tab: TabItem, entries: [LogEntry]) -> String {
        switch tab.kind {
        case .mainLog:
            return entries
                .map { "\(TimeFormats.clockString(from: $0.recordedAt)) \($0.noteText)" }
                .joined(separator: "\n")
        case .text:
            return tab.body
        }
    }

    func makeProjectExportContent(project: Project, tabs: [TabItem], entriesByTab: [String: [LogEntry]]) -> String {
        var lines: [String] = []
        lines.append("项目标题：\(project.title)")
        lines.append("导出日期：\(TimeFormats.shortDateString(from: .now))")
        lines.append("")

        for tab in tabs {
            lines.append("========== [\(tab.title)] ==========")
            switch tab.kind {
            case .mainLog:
                let rows = entriesByTab[tab.id, default: []]
                    .map { "\(TimeFormats.clockString(from: $0.recordedAt)) \($0.noteText)" }
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

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func sanitizeFileName(_ fileName: String) -> String {
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
