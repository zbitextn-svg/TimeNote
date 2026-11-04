import AppKit
import Foundation
import UniformTypeIdentifiers

enum AttachmentServiceError: LocalizedError {
    case unsupportedFileType(String)
    case fileOperationFailed(String)
    case resolveFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let fileName):
            return "不支持的附件类型：\(fileName)。仅支持图片、音频、视频。"
        case .fileOperationFailed(let message):
            return "附件文件处理失败：\(message)"
        case .resolveFailed(let message):
            return "附件打开失败：\(message)"
        }
    }
}

struct StoredAttachmentFile {
    let fileName: String
    let relativePath: String
    let kind: AttachmentKind
    let fileSize: Int64
}

@MainActor
struct AttachmentService {
    private let rootURL: URL?

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL
    }

    func chooseImportURLs() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .audio, .movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK else {
            return []
        }
        return panel.urls
    }

    func importFile(at sourceURL: URL, projectID: String) throws -> StoredAttachmentFile {
        let kind = try attachmentKind(for: sourceURL)
        let fileName = sourceURL.lastPathComponent
        return try copyFile(from: sourceURL, originalFileName: fileName, kind: kind, projectID: projectID)
    }

    func duplicateAttachment(
        relativePath: String,
        originalFileName: String,
        targetProjectID: String
    ) throws -> StoredAttachmentFile {
        let sourceURL = try attachmentURL(relativePath: relativePath)
        let kind = try attachmentKind(for: sourceURL)
        return try copyFile(
            from: sourceURL,
            originalFileName: originalFileName,
            kind: kind,
            projectID: targetProjectID
        )
    }

    func deleteAttachment(relativePath: String) throws {
        let url = try attachmentURL(relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw AttachmentServiceError.fileOperationFailed(error.localizedDescription)
        }
    }

    func deleteProjectAttachmentDirectory(projectID: String) throws {
        let directoryURL = try appSupportRootURL()
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)

        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: directoryURL)
        } catch {
            throw AttachmentServiceError.fileOperationFailed(error.localizedDescription)
        }
    }

    private func copyFile(
        from sourceURL: URL,
        originalFileName: String,
        kind: AttachmentKind,
        projectID: String
    ) throws -> StoredAttachmentFile {
        let attachmentID = UUID().uuidString
        let sanitizedName = sanitizeFileName(originalFileName)
        let relativePath = "attachments/\(projectID)/\(attachmentID)-\(sanitizedName)"
        let destinationURL = try appSupportRootURL().appendingPathComponent(relativePath)

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw AttachmentServiceError.fileOperationFailed(error.localizedDescription)
        }

        let values = try destinationURL.resourceValues(forKeys: [.fileSizeKey])
        return StoredAttachmentFile(
            fileName: originalFileName,
            relativePath: relativePath,
            kind: kind,
            fileSize: Int64(values.fileSize ?? 0)
        )
    }

    func openAttachment(relativePath: String) throws {
        let url = try appSupportRootURL().appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AttachmentServiceError.resolveFailed("找不到附件文件。")
        }
        guard NSWorkspace.shared.open(url) else {
            throw AttachmentServiceError.resolveFailed("系统未能打开该附件。")
        }
    }

    func attachmentURL(relativePath: String) throws -> URL {
        try appSupportRootURL().appendingPathComponent(relativePath)
    }

    func attachmentKind(for sourceURL: URL) throws -> AttachmentKind {
        if let type = UTType(filenameExtension: sourceURL.pathExtension.lowercased()) {
            if type.conforms(to: .image) {
                return .image
            }
            if type.conforms(to: .audio) {
                return .audio
            }
            if type.conforms(to: .movie) || type.conforms(to: .video) {
                return .video
            }
        }
        throw AttachmentServiceError.unsupportedFileType(sourceURL.lastPathComponent)
    }

    private func appSupportRootURL() throws -> URL {
        if let rootURL {
            return rootURL
        }
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root.appendingPathComponent("TimeNote", isDirectory: true)
    }

    private func sanitizeFileName(_ fileName: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = fileName
            .components(separatedBy: illegal)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "attachment" : cleaned
    }
}
