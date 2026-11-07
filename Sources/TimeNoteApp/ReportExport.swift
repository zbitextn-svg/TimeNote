import AppKit
import Foundation

/// 导出「场记单」所需的数据快照（与界面状态无关，便于测试）
struct ProjectReport {
    struct TextSection {
        let title: String
        let body: String
    }

    struct RecordingSection {
        let recording: Recording
        let segments: [TranscriptSegment]
    }

    let projectTitle: String
    let exportedAt: Date
    /// 主场记，按时间正序
    let entries: [LogEntry]
    let textSections: [TextSection]
    let recordings: [RecordingSection]

    /// 某条场记在哪段录音里、位置是多少，例如「录音 1 · 03:12」；不在任何录音区间内时为空
    func recordingLabel(for entry: LogEntry) -> String {
        for section in recordings {
            if let offset = section.recording.offset(of: entry.recordedAt) {
                return "\(section.recording.title) · \(DurationFormats.string(from: offset))"
            }
        }
        return ""
    }

    var hasRecordingColumn: Bool {
        entries.contains { recordingLabel(for: $0).isEmpty == false }
    }

    /// 例如「2026-11-04 至 2026-11-05」；只有一天时只显示那一天
    var dateRangeText: String {
        guard let first = entries.first?.recordedAt, let last = entries.last?.recordedAt else { return "" }
        let firstText = TimeFormats.shortDateString(from: first)
        let lastText = TimeFormats.shortDateString(from: last)
        return firstText == lastText ? firstText : "\(firstText) 至 \(lastText)"
    }
}

// MARK: - Excel

/// 生成 .xlsx（Office Open XML）。不依赖第三方库：工作表 XML + 不压缩的 ZIP 容器。
enum XLSXReportWriter {
    struct Sheet {
        let name: String
        let columnWidths: [Double]
        let rows: [[String]]
    }

    static func sheets(for report: ProjectReport) -> [Sheet] {
        var sheets: [Sheet] = []

        let showsRecording = report.hasRecordingColumn
        var logRows: [[String]] = [showsRecording ? ["日期", "时间", "内容", "录音位置"] : ["日期", "时间", "内容"]]
        for entry in report.entries {
            var row = [
                TimeFormats.shortDateString(from: entry.recordedAt),
                TimeFormats.clockString(from: entry.recordedAt),
                entry.noteText,
            ]
            if showsRecording {
                row.append(report.recordingLabel(for: entry))
            }
            logRows.append(row)
        }
        sheets.append(Sheet(name: "场记", columnWidths: showsRecording ? [12, 10, 70, 20] : [12, 10, 80], rows: logRows))

        let textRows = report.textSections.flatMap { section -> [[String]] in
            let lines = section.body
                .components(separatedBy: .newlines)
                .filter { $0.trimmingCharacters(in: .whitespaces).isEmpty == false }
            return lines.isEmpty ? [[section.title, ""]] : lines.map { [section.title, $0] }
        }
        if textRows.isEmpty == false {
            sheets.append(Sheet(name: "文本标签", columnWidths: [18, 90], rows: [["标签", "内容"]] + textRows))
        }

        let transcriptRows = report.recordings.flatMap { section -> [[String]] in
            section.segments.map { segment in
                [
                    section.recording.title,
                    TimeFormats.clockString(from: section.recording.startedAt.addingTimeInterval(segment.start)),
                    DurationFormats.string(from: segment.start),
                    segment.text,
                ]
            }
        }
        if transcriptRows.isEmpty == false {
            sheets.append(Sheet(name: "录音文字", columnWidths: [16, 10, 10, 80], rows: [["录音", "时间", "位置", "文字"]] + transcriptRows))
        }
        return sheets
    }

    static func data(for report: ProjectReport) -> Data {
        data(sheets: sheets(for: report), title: report.projectTitle)
    }

    static func data(sheets: [Sheet], title: String) -> Data {
        var archive = StoredZipArchive()
        archive.add("[Content_Types].xml", contentTypes(sheetCount: sheets.count))
        archive.add("_rels/.rels", rootRelationships)
        archive.add("docProps/core.xml", coreProperties(title: title))
        archive.add("xl/workbook.xml", workbook(sheetNames: uniqueSheetNames(sheets.map(\.name))))
        archive.add("xl/_rels/workbook.xml.rels", workbookRelationships(sheetCount: sheets.count))
        archive.add("xl/styles.xml", styles)
        for (index, sheet) in sheets.enumerated() {
            archive.add("xl/worksheets/sheet\(index + 1).xml", worksheet(sheet))
        }
        return archive.finish()
    }

    // MARK: 部件

    private static func contentTypes(sheetCount: Int) -> String {
        let sheetOverrides = (1...max(sheetCount, 1)).map {
            #"<Override PartName="/xl/worksheets/sheet\#($0).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
        }.joined()
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
            + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
            + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
            + #"<Default Extension="xml" ContentType="application/xml"/>"#
            + #"<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>"#
            + #"<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>"#
            + #"<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>"#
            + sheetOverrides
            + "</Types>"
    }

    private static let rootRelationships = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>"#
        + #"<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>"#
        + "</Relationships>"

    private static func coreProperties(title: String) -> String {
        let created = TimeFormats.iso8601String(from: .now).replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
            + #"<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">"#
            + "<dc:title>\(escape(title))</dc:title><dc:creator>TimeNote</dc:creator>"
            + #"<dcterms:created xsi:type="dcterms:W3CDTF">\#(created)</dcterms:created>"#
            + "</cp:coreProperties>"
    }

    private static func workbook(sheetNames: [String]) -> String {
        let sheets = sheetNames.enumerated().map { index, name in
            #"<sheet name="\#(escape(name))" sheetId="\#(index + 1)" r:id="rId\#(index + 1)"/>"#
        }.joined()
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
            + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
            + "<sheets>\(sheets)</sheets></workbook>"
    }

    private static func workbookRelationships(sheetCount: Int) -> String {
        var relationships = (1...max(sheetCount, 1)).map {
            #"<Relationship Id="rId\#($0)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#($0).xml"/>"#
        }
        relationships.append(#"<Relationship Id="rId\#(sheetCount + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#)
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
            + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + relationships.joined()
            + "</Relationships>"
    }

    /// 样式 0：普通（顶端对齐、自动换行）；样式 1：表头（加粗、浅底色）
    private static let styles = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        + #"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
        + #"<fonts count="2"><font><sz val="11"/><name val="PingFang SC"/></font><font><b/><sz val="11"/><name val="PingFang SC"/></font></fonts>"#
        + #"<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>"#
        + #"<fill><patternFill patternType="solid"><fgColor rgb="FFF1EDE6"/><bgColor indexed="64"/></patternFill></fill></fills>"#
        + #"<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"#
        + #"<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>"#
        + #"<cellXfs count="2">"#
        + #"<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>"#
        + #"<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="center"/></xf>"#
        + "</cellXfs>"
        + #"<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>"#
        + "</styleSheet>"

    private static func worksheet(_ sheet: Sheet) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
            + #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
        // 冻结首行表头
        xml += #"<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"#
        if sheet.columnWidths.isEmpty == false {
            xml += "<cols>"
            for (index, width) in sheet.columnWidths.enumerated() {
                xml += #"<col min="\#(index + 1)" max="\#(index + 1)" width="\#(width)" customWidth="1"/>"#
            }
            xml += "</cols>"
        }
        xml += "<sheetData>"
        for (rowIndex, row) in sheet.rows.enumerated() {
            let style = rowIndex == 0 ? 1 : 0
            xml += #"<row r="\#(rowIndex + 1)">"#
            for (columnIndex, value) in row.enumerated() {
                let reference = columnName(columnIndex) + String(rowIndex + 1)
                // Excel 单元格最多 32767 个字符
                let text = String(value.prefix(32_000))
                xml += #"<c r="\#(reference)" s="\#(style)" t="inlineStr"><is><t xml:space="preserve">\#(escape(text))</t></is></c>"#
            }
            xml += "</row>"
        }
        xml += "</sheetData></worksheet>"
        return xml
    }

    static func columnName(_ index: Int) -> String {
        var number = index + 1
        var name = ""
        while number > 0 {
            let remainder = (number - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            number = (number - 1) / 26
        }
        return name
    }

    /// 工作表名：最长 31 个字符，不能含 []:*?/\，且不能重复
    static func uniqueSheetNames(_ names: [String]) -> [String] {
        var used = Set<String>()
        return names.map { raw in
            let illegal = CharacterSet(charactersIn: "[]:*?/\\")
            var base = raw.components(separatedBy: illegal).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if base.isEmpty { base = "Sheet" }
            base = String(base.prefix(31))
            var candidate = base
            var counter = 2
            while used.contains(candidate.lowercased()) {
                let suffix = " (\(counter))"
                candidate = String(base.prefix(31 - suffix.count)) + suffix
                counter += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }

    /// XML 转义，并去掉 XML 1.0 不允许的控制字符
    static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\t", "\n", "\r":
                result.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x20 || (0xFFFE...0xFFFF).contains(scalar.value) {
                    continue
                }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

/// 只存储（不压缩）的 ZIP 写入器，足够生成 .xlsx。
struct StoredZipArchive {
    private var body = Data()
    private var centralDirectory = Data()
    private var entryCount: UInt16 = 0

    mutating func add(_ path: String, _ text: String) {
        add(path, data: Data(text.utf8))
    }

    mutating func add(_ path: String, data: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        let offset = UInt32(body.count)
        // 固定时间戳 1980-01-01 00:00，保证同样的内容生成同样的文件
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = (0 << 9) | (1 << 5) | 1
        let flags: UInt16 = 0x0800 // 文件名为 UTF-8

        var local = Data()
        local.appendLE(UInt32(0x0403_4B50))
        local.appendLE(UInt16(20))
        local.appendLE(flags)
        local.appendLE(UInt16(0)) // stored
        local.appendLE(dosTime)
        local.appendLE(dosDate)
        local.appendLE(crc)
        local.appendLE(UInt32(data.count))
        local.appendLE(UInt32(data.count))
        local.appendLE(UInt16(name.count))
        local.appendLE(UInt16(0))
        local.append(name)
        body.append(local)
        body.append(data)

        var central = Data()
        central.appendLE(UInt32(0x0201_4B50))
        central.appendLE(UInt16(20))
        central.appendLE(UInt16(20))
        central.appendLE(flags)
        central.appendLE(UInt16(0))
        central.appendLE(dosTime)
        central.appendLE(dosDate)
        central.appendLE(crc)
        central.appendLE(UInt32(data.count))
        central.appendLE(UInt32(data.count))
        central.appendLE(UInt16(name.count))
        central.appendLE(UInt16(0)) // extra
        central.appendLE(UInt16(0)) // comment
        central.appendLE(UInt16(0)) // disk
        central.appendLE(UInt16(0)) // internal attrs
        central.appendLE(UInt32(0)) // external attrs
        central.appendLE(offset)
        central.append(name)
        centralDirectory.append(central)
        entryCount += 1
    }

    func finish() -> Data {
        var output = body
        let centralOffset = UInt32(output.count)
        output.append(centralDirectory)
        output.appendLE(UInt32(0x0605_4B50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(entryCount)
        output.appendLE(entryCount)
        output.appendLE(UInt32(centralDirectory.count))
        output.appendLE(centralOffset)
        output.appendLE(UInt16(0))
        return output
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        finish(update(start, data))
    }

    static let start: UInt32 = 0xFFFF_FFFF

    static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        var crc = crc
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc
    }

    static func finish(_ crc: UInt32) -> UInt32 {
        crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func appendLE(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

// MARK: - PDF

/// 生成 A4 竖版 PDF 场记单：标题、概况、按日期分组的场记表，之后是文本标签内容。
@MainActor
enum PDFReportWriter {
    private static let pageSize = CGSize(width: 595.28, height: 841.89)
    private static let margin: CGFloat = 44
    private static let footerHeight: CGFloat = 24

    private static let ink = NSColor(srgbRed: 0.14, green: 0.13, blue: 0.11, alpha: 1)
    private static let secondaryInk = NSColor(srgbRed: 0.45, green: 0.42, blue: 0.38, alpha: 1)
    private static let accentInk = NSColor(srgbRed: 0.66, green: 0.34, blue: 0.04, alpha: 1)
    private static let rule = NSColor(srgbRed: 0.88, green: 0.85, blue: 0.80, alpha: 1)
    private static let band = NSColor(srgbRed: 0.95, green: 0.93, blue: 0.90, alpha: 1)

    static func data(for report: ProjectReport) -> Data {
        let output = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard
            let consumer = CGDataConsumer(data: output as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, [
                kCGPDFContextTitle as String: report.projectTitle,
                kCGPDFContextCreator as String: "TimeNote",
            ] as CFDictionary)
        else {
            return Data()
        }

        var renderer = PageRenderer(context: context, report: report)
        renderer.render()
        context.closePDF()
        return output as Data
    }

    @MainActor
    private struct PageRenderer {
        let context: CGContext
        let report: ProjectReport
        var pageNumber = 0
        var cursorY: CGFloat = 0
        var pageOpen = false

        /// 是否显示「录音位置」列（只要有一条场记落在录音区间内）
        let showsRecording: Bool

        init(context: CGContext, report: ProjectReport) {
            self.context = context
            self.report = report
            self.showsRecording = report.hasRecordingColumn
        }

        private var contentWidth: CGFloat { PDFReportWriter.pageSize.width - PDFReportWriter.margin * 2 }
        private var bottomLimit: CGFloat { PDFReportWriter.pageSize.height - PDFReportWriter.margin - PDFReportWriter.footerHeight }

        // 列宽：时间 | 内容 | 录音位置（可选）
        private var timeColumnWidth: CGFloat { 62 }
        private var recordingColumnWidth: CGFloat { showsRecording ? 92 : 0 }

        mutating func render() {
            beginPage()
            drawTitleBlock()

            let groups = report.entries.groupedByDay(newestFirst: false)
            if groups.isEmpty {
                drawParagraph("还没有场记。", font: .systemFont(ofSize: 11), color: PDFReportWriter.secondaryInk)
            }
            for group in groups {
                drawDayHeader(group)
                for entry in group.entries {
                    drawEntryRow(entry)
                }
                cursorY += 8
            }

            for section in report.textSections {
                let body = section.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard body.isEmpty == false else { continue }
                drawSectionHeading(section.title)
                for paragraph in paragraphs(of: body) {
                    drawParagraph(paragraph, font: .systemFont(ofSize: 10.5), color: PDFReportWriter.ink)
                }
                cursorY += 6
            }

            // 录音文字：每段录音一节，每句带说话时刻和在录音中的位置
            for section in report.recordings where section.segments.isEmpty == false {
                let recording = section.recording
                drawSectionHeading("录音文字 · \(recording.title)")
                drawParagraph(
                    "开始 \(TimeFormats.shortDateString(from: recording.startedAt)) \(TimeFormats.clockString(from: recording.startedAt))  ·  时长 \(DurationFormats.string(from: recording.duration))  ·  \(section.segments.count) 句",
                    font: .systemFont(ofSize: 9),
                    color: PDFReportWriter.secondaryInk
                )
                for segment in section.segments {
                    drawTimedRow(
                        time: TimeFormats.clockString(from: recording.startedAt.addingTimeInterval(segment.start)),
                        text: segment.text,
                        trailing: "录音位置 \(DurationFormats.string(from: segment.start))",
                        trailingWidth: 92
                    )
                }
                cursorY += 6
            }
            endPage()
        }

        // MARK: 页面

        private mutating func beginPage() {
            context.beginPDFPage(nil)
            context.saveGState()
            // 翻转为左上角原点，方便自上而下排版
            context.translateBy(x: 0, y: PDFReportWriter.pageSize.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            pageNumber += 1
            pageOpen = true
            cursorY = PDFReportWriter.margin
        }

        private mutating func endPage() {
            guard pageOpen else { return }
            drawFooter()
            NSGraphicsContext.current = nil
            context.restoreGState()
            context.endPDFPage()
            pageOpen = false
        }

        private mutating func ensureSpace(_ height: CGFloat) {
            if cursorY + height > bottomLimit {
                endPage()
                beginPage()
            }
        }

        private func drawFooter() {
            let text = "\(report.projectTitle) · 第 \(pageNumber) 页"
            let attributed = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: PDFReportWriter.secondaryInk,
            ])
            let size = attributed.size()
            attributed.draw(at: CGPoint(x: (PDFReportWriter.pageSize.width - size.width) / 2, y: PDFReportWriter.pageSize.height - PDFReportWriter.margin + 4))
        }

        // MARK: 内容块

        private mutating func drawTitleBlock() {
            let title = NSAttributedString(string: report.projectTitle, attributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: PDFReportWriter.ink,
            ])
            let titleHeight = height(of: title, width: contentWidth)
            title.draw(with: CGRect(x: PDFReportWriter.margin, y: cursorY, width: contentWidth, height: titleHeight), options: [.usesLineFragmentOrigin])
            cursorY += titleHeight + 4

            var meta = ["场记单", "\(report.entries.count) 条场记"]
            if report.dateRangeText.isEmpty == false {
                meta.append(report.dateRangeText)
            }
            meta.append("导出于 \(TimeFormats.shortDateString(from: report.exportedAt)) \(TimeFormats.clockString(from: report.exportedAt))")
            let metaText = NSAttributedString(string: meta.joined(separator: "  ·  "), attributes: [
                .font: NSFont.systemFont(ofSize: 9.5),
                .foregroundColor: PDFReportWriter.secondaryInk,
            ])
            let metaHeight = height(of: metaText, width: contentWidth)
            metaText.draw(with: CGRect(x: PDFReportWriter.margin, y: cursorY, width: contentWidth, height: metaHeight), options: [.usesLineFragmentOrigin])
            cursorY += metaHeight + 10

            fill(PDFReportWriter.rule, CGRect(x: PDFReportWriter.margin, y: cursorY, width: contentWidth, height: 1.2))
            cursorY += 12
        }

        private mutating func drawDayHeader(_ group: LogDayGroup) {
            ensureSpace(48) // 日期标题后至少能放一行
            let rect = CGRect(x: PDFReportWriter.margin, y: cursorY, width: contentWidth, height: 20)
            fill(PDFReportWriter.band, rect)
            let text = NSAttributedString(
                string: "\(TimeFormats.dayHeaderString(from: group.day))   \(group.entries.count) 条",
                attributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: PDFReportWriter.ink]
            )
            text.draw(with: rect.insetBy(dx: 8, dy: 4), options: [.usesLineFragmentOrigin])
            cursorY += 24
        }

        private mutating func drawEntryRow(_ entry: LogEntry) {
            drawTimedRow(
                time: TimeFormats.clockString(from: entry.recordedAt),
                text: entry.noteText,
                trailing: showsRecording ? report.recordingLabel(for: entry) : nil,
                trailingWidth: recordingColumnWidth
            )
        }

        /// 一行「时间 | 内容 | 右侧小字」，用于场记与录音文字
        private mutating func drawTimedRow(time: String, text: String, trailing: String?, trailingWidth: CGFloat) {
            let textWidth = contentWidth - timeColumnWidth - trailingWidth - 12
            let note = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: PDFReportWriter.ink,
                .paragraphStyle: paragraphStyle(lineSpacing: 2),
            ])
            let noteHeight = height(of: note, width: textWidth)
            let rowHeight = max(noteHeight, 14) + 8
            ensureSpace(rowHeight)

            let timeText = NSAttributedString(string: time, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: PDFReportWriter.accentInk,
            ])
            timeText.draw(at: CGPoint(x: PDFReportWriter.margin + 4, y: cursorY + 4))
            let noteX = PDFReportWriter.margin + timeColumnWidth
            note.draw(
                with: CGRect(x: noteX, y: cursorY + 3, width: textWidth, height: noteHeight + 2),
                options: [.usesLineFragmentOrigin]
            )
            if let trailing, trailing.isEmpty == false, trailingWidth > 0 {
                let label = NSAttributedString(string: trailing, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular),
                    .foregroundColor: PDFReportWriter.secondaryInk,
                ])
                label.draw(
                    with: CGRect(x: PDFReportWriter.margin + contentWidth - trailingWidth, y: cursorY + 5, width: trailingWidth, height: 24),
                    options: [.usesLineFragmentOrigin]
                )
            }
            cursorY += rowHeight
            fill(PDFReportWriter.rule.withAlphaComponent(0.6), CGRect(x: noteX, y: cursorY - 0.5, width: contentWidth - timeColumnWidth, height: 0.5))
        }

        private mutating func drawSectionHeading(_ title: String) {
            ensureSpace(52)
            cursorY += 8
            let heading = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: PDFReportWriter.ink,
            ])
            let headingHeight = height(of: heading, width: contentWidth)
            heading.draw(with: CGRect(x: PDFReportWriter.margin, y: cursorY, width: contentWidth, height: headingHeight), options: [.usesLineFragmentOrigin])
            cursorY += headingHeight + 4
            fill(PDFReportWriter.rule, CGRect(x: PDFReportWriter.margin, y: cursorY, width: contentWidth, height: 0.8))
            cursorY += 8
        }

        private mutating func drawParagraph(_ text: String, font: NSFont, color: NSColor) {
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle(lineSpacing: 3),
            ])
            let paragraphHeight = height(of: attributed, width: contentWidth)
            ensureSpace(paragraphHeight + 6)
            attributed.draw(
                with: CGRect(x: PDFReportWriter.margin, y: cursorY, width: contentWidth, height: paragraphHeight + 2),
                options: [.usesLineFragmentOrigin]
            )
            cursorY += paragraphHeight + 6
        }

        // MARK: 工具

        /// 按行拆分；超长的段落再切成小块，保证每块都能放进一页
        private func paragraphs(of body: String) -> [String] {
            body.components(separatedBy: .newlines).flatMap { line -> [String] in
                guard line.isEmpty == false else { return [] }
                var chunks: [String] = []
                var remaining = Substring(line)
                while remaining.count > 900 {
                    chunks.append(String(remaining.prefix(900)))
                    remaining = remaining.dropFirst(900)
                }
                chunks.append(String(remaining))
                return chunks
            }
        }

        private func paragraphStyle(lineSpacing: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            style.lineBreakMode = .byWordWrapping
            return style
        }

        private func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
            ceil(text.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height)
        }

        private func fill(_ color: NSColor, _ rect: CGRect) {
            context.setFillColor(color.cgColor)
            context.fill(rect)
        }
    }
}

// MARK: - 完整资料包（.zip）

/// 把场记单、录音文字和原始录音整理成一个文件夹并压缩成 .zip，方便发给别人。
///
/// 结构：
///   项目名 场记资料/
///     场记单.pdf
///     场记单.xlsx
///     场记.txt
///     录音/录音 1（11月5日 19.26）.m4a
///     录音文字/录音 1（11月5日 19.26）.txt
enum ProjectPackageBuilder {
    struct AudioFile: Sendable {
        let source: URL
        let fileName: String
    }

    struct TextFile: Sendable {
        let fileName: String
        let text: String
    }

    struct Contents: Sendable {
        let folderName: String
        let pdf: Data
        let xlsx: Data
        let text: String
        let transcripts: [TextFile]
        let audio: [AudioFile]
    }

    /// 生成 zip 到 `destination`（会覆盖已有文件）。耗时操作，请在后台调用。
    static func build(_ contents: Contents, at destination: URL) throws {
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("TimeNoteExport-\(UUID().uuidString)", isDirectory: true)
        let folder = workDirectory.appendingPathComponent(contents.folderName, isDirectory: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try contents.pdf.write(to: folder.appendingPathComponent("场记单.pdf"))
        try contents.xlsx.write(to: folder.appendingPathComponent("场记单.xlsx"))
        try Data(contents.text.utf8).write(to: folder.appendingPathComponent("场记.txt"))

        if contents.transcripts.isEmpty == false {
            let transcriptFolder = folder.appendingPathComponent("录音文字", isDirectory: true)
            try fileManager.createDirectory(at: transcriptFolder, withIntermediateDirectories: true)
            for file in contents.transcripts {
                try Data(file.text.utf8).write(to: transcriptFolder.appendingPathComponent(file.fileName))
            }
        }
        if contents.audio.isEmpty == false {
            let audioFolder = folder.appendingPathComponent("录音", isDirectory: true)
            try fileManager.createDirectory(at: audioFolder, withIntermediateDirectories: true)
            for file in contents.audio {
                try fileManager.copyItem(at: file.source, to: audioFolder.appendingPathComponent(file.fileName))
            }
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        // 自己写 zip（不压缩，录音本身已是压缩格式）：文件名标记为 UTF-8，
        // Windows 和手机上解压中文文件名也不会乱码；文件内容分块读写，录音再大也不占满内存
        let writer = try StoredZipFileWriter(url: destination)
        do {
            let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
            var files: [URL] = []
            while let url = enumerator?.nextObject() as? URL {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                files.append(url)
            }
            let basePath = workDirectory.resolvingSymlinksInPath().path + "/"
            for url in files.sorted(by: { $0.path < $1.path }) {
                let relative = String(url.resolvingSymlinksInPath().path.dropFirst(basePath.count))
                try writer.addFile(at: url, as: relative)
            }
            try writer.finish()
        } catch {
            try? writer.close()
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    /// 录音在资料包里的文件名（不含扩展名），例如「录音 1（11月5日 19.26）」；重名时加序号
    static func baseNames(for recordings: [Recording], sanitize: (String) -> String) -> [String: String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH.mm"
        var used = Set<String>()
        var result: [String: String] = [:]
        for recording in recordings {
            let base = sanitize("\(recording.title)（\(formatter.string(from: recording.startedAt))）")
            var candidate = base
            var counter = 2
            while used.contains(candidate.lowercased()) {
                candidate = "\(base) \(counter)"
                counter += 1
            }
            used.insert(candidate.lowercased())
            result[recording.id] = candidate
        }
        return result
    }
}

/// 流式写入的「只存储」ZIP（文件名 UTF-8）。单个文件和整个压缩包都不能超过 4 GB。
final class StoredZipFileWriter {
    private let handle: FileHandle
    private var centralDirectory = Data()
    private var entryCount: UInt16 = 0
    private var offset: UInt64 = 0
    private var isClosed = false

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func addFile(at source: URL, as path: String) throws {
        // 第一遍：计算大小与 CRC
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        var crc = CRC32.start
        var size: UInt64 = 0
        while let chunk = try reader.read(upToCount: 1 << 20), chunk.isEmpty == false {
            crc = CRC32.update(crc, chunk)
            size += UInt64(chunk.count)
        }
        guard size < UInt64(UInt32.max), offset < UInt64(UInt32.max) else {
            throw ExportError.writeFailed("资料包超过 4 GB，请分开导出")
        }
        let checksum = CRC32.finish(crc)
        let name = Data(path.utf8)
        let header = self.header(signature: 0x0403_4B50, central: false, crc: checksum, size: UInt32(size), name: name, offset: 0)
        try handle.write(contentsOf: header)

        // 第二遍：写入内容
        try reader.seek(toOffset: 0)
        while let chunk = try reader.read(upToCount: 1 << 20), chunk.isEmpty == false {
            try handle.write(contentsOf: chunk)
        }

        centralDirectory.append(self.header(signature: 0x0201_4B50, central: true, crc: checksum, size: UInt32(size), name: name, offset: UInt32(offset)))
        offset += UInt64(header.count) + size
        entryCount += 1
    }

    func finish() throws {
        var end = Data()
        end.appendLE(UInt32(0x0605_4B50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(entryCount)
        end.appendLE(entryCount)
        end.appendLE(UInt32(centralDirectory.count))
        end.appendLE(UInt32(offset))
        end.appendLE(UInt16(0))
        try handle.write(contentsOf: centralDirectory)
        try handle.write(contentsOf: end)
        try close()
    }

    func close() throws {
        guard isClosed == false else { return }
        isClosed = true
        try handle.close()
    }

    /// 压缩包内文件的修改时间（DOS 格式），用导出时刻
    private let dosStamp: (time: UInt16, date: UInt16) = {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: .now)
        let year = max((parts.year ?? 1980) - 1980, 0)
        let date = UInt16(year << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        return (time, date)
    }()

    private func header(signature: UInt32, central: Bool, crc: UInt32, size: UInt32, name: Data, offset: UInt32) -> Data {
        var data = Data()
        data.appendLE(signature)
        if central {
            data.appendLE(UInt16(20)) // made by
        }
        data.appendLE(UInt16(20)) // version needed
        data.appendLE(UInt16(0x0800)) // 文件名为 UTF-8
        data.appendLE(UInt16(0)) // stored
        data.appendLE(dosStamp.time)
        data.appendLE(dosStamp.date)
        data.appendLE(crc)
        data.appendLE(size)
        data.appendLE(size)
        data.appendLE(UInt16(name.count))
        data.appendLE(UInt16(0)) // extra
        if central {
            data.appendLE(UInt16(0)) // comment
            data.appendLE(UInt16(0)) // disk
            data.appendLE(UInt16(0)) // internal attrs
            data.appendLE(UInt32(0)) // external attrs
            data.appendLE(offset)
        }
        data.append(name)
        return data
    }
}
