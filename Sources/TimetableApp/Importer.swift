import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct ImportResult {
    var courses: [Course]
    var warnings: [String]
    var skipped: [String]
}

enum DocxImportError: LocalizedError {
    case invalidFile, invalidDocument, unsupportedFormat, noCourses
    var errorDescription: String? {
        switch self {
        case .invalidFile: return "无法读取这个 Word 文件，请选择有效的 .docx 文件。"
        case .invalidDocument: return "无法读取 Word 文档内容。"
        case .unsupportedFormat: return "未找到支持的课表表格，请使用与样例格式相同的文件。"
        case .noCourses: return "表格中没有识别出可导入的课程，请检查文件格式。"
        }
    }
}

/// 读取样例中的 Word 表格；只提取文档内容，不访问网络或执行文档中的宏。
enum DocxImporter {
    static func parse(url: URL) throws -> ImportResult {
        guard url.pathExtension.lowercased() == "docx" else { throw DocxImportError.invalidFile }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "word/document.xml"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw DocxImportError.invalidFile }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty, data.count < 20_000_000 else { throw DocxImportError.invalidDocument }
        let reader = WordTableReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { throw DocxImportError.invalidDocument }
        guard let table = reader.tables.first(where: { table in
            table.contains { row in row.contains { $0.paragraphs.joined().contains("星期一") } }
        }) else { throw DocxImportError.unsupportedFormat }
        return try convert(table: table, notes: reader.outsideParagraphs)
    }

    private static func convert(table: [[WordCell]], notes: [String]) throws -> ImportResult {
        var columns: [Int: Int] = [:]
        let dayNames = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
        for row in table {
            var col = 0
            for cell in row {
                let text = cell.paragraphs.joined()
                for (idx, name) in dayNames.enumerated() where text.contains(name) { columns[col] = idx + 1 }
                col += cell.span
            }
            if !columns.isEmpty { break }
        }
        guard columns.count == 7 else { throw DocxImportError.unsupportedFormat }
        var result = ImportResult(courses: [], warnings: [], skipped: [])
        for row in table {
            var col = 0
            for cell in row {
                defer { col += cell.span }
                guard let day = columns[col], !cell.continuation else { continue }
                for paragraph in cell.paragraphs {
                    let line = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty, !dayNames.contains(where: { line.contains($0) }) else { continue }
                    let courses = parseParagraph(line, weekday: day)
                    if courses.isEmpty { result.skipped.append(line) }
                    else {
                        result.courses.append(contentsOf: courses)
                        let weekMarkers = try! NSRegularExpression(pattern: #"\(\d+(?:\s*[~～\-—]\s*\d+)?(?:\s*\([单双]\))?\s*周\)"#)
                        let count = weekMarkers.numberOfMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
                        if count > courses.count {
                            result.warnings.append("部分课程安排无法识别，请按原文手动补充：\(line)")
                        }
                    }
                }
            }
        }
        for note in notes where note.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("备注") {
            let cleaned = note.replacingOccurrences(of: "\u{00a0}", with: " ")
            let regex = try! NSRegularExpression(pattern: "(?:^备注[：:]?\\s*|\\s+)(?:\\d+[.、]\\s*)")
            let ns = cleaned as NSString
            let matches = regex.matches(in: cleaned, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty { result.skipped.append(cleaned) }
            else {
                for (index, match) in matches.enumerated() {
                    let start = NSMaxRange(match.range)
                    let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
                    let value = ns.substring(with: NSRange(location: start, length: max(0, end - start))).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { result.skipped.append(value) }
                }
            }
        }
        guard !result.courses.isEmpty else { throw DocxImportError.noCourses }
        result.warnings.append("请逐条核对教师、地点和周次；原始内容可在编辑课程时查看。")
        if !result.skipped.isEmpty { result.warnings.append("部分内容缺少明确上课时间或无法识别，已列在跳过项目中。") }
        return result
    }

    private static func parseParagraph(_ line: String, weekday: Int) -> [Course] {
        // 一行可能依次包含多个独立周次与教室、教师组合。
        let pattern = #"\((\d+(?:\s*[~～\-—]\s*\d+)?(?:\s*\([单双]\))?\s*周)\)\s*\((\d+)(?:\s*[-~～]\s*(\d+))?\s*节\)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard let first = matches.first else { return [] }
        var name = ns.substring(to: first.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: #"\s+\d{1,3}$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        var courses: [Course] = []
        for (index, match) in matches.enumerated() {
            let weekText = ns.substring(with: match.range(at: 1))
            let numbers = (try! NSRegularExpression(pattern: #"\d+"#)).matches(in: weekText, range: NSRange(location: 0, length: (weekText as NSString).length)).compactMap { Int((weekText as NSString).substring(with: $0.range)) }
            guard let startWeek = numbers.first, startWeek > 0 else { continue }
            let endWeek = numbers.count > 1 ? numbers[1] : startWeek
            guard endWeek >= startWeek, endWeek <= 60 else { continue }
            var weeks = Array(startWeek...endWeek)
            if weekText.contains("单") { weeks = weeks.filter { $0 % 2 == 1 } }
            if weekText.contains("双") { weeks = weeks.filter { $0 % 2 == 0 } }
            guard !weeks.isEmpty, let startPeriod = Int(ns.substring(with: match.range(at: 2))) else { continue }
            let endPeriod = match.range(at: 3).location == NSNotFound ? startPeriod : (Int(ns.substring(with: match.range(at: 3))) ?? startPeriod)
            guard startPeriod > 0, endPeriod >= startPeriod, endPeriod <= 30 else { continue }
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let details = ns.substring(with: NSRange(location: start, length: max(0, end - start))).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = details.components(separatedBy: "\u{00a0}").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let location = parts.first ?? ""
            let teacherAndClass = parts.dropFirst().first ?? ""
            // 教师后常直接拼接学院或班级信息，按样例中的边界截取，供用户校对。
            let teacher = teacherAndClass.components(separatedBy: try! NSRegularExpression(pattern: #"(?=\d|全校|[A-Za-z])"#)).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            courses.append(Course(id: UUID(), name: name, teacher: teacher, location: location, weekday: weekday, startPeriod: startPeriod, endPeriod: endPeriod, weeks: weeks, rawText: line))
        }
        return courses
    }
}

private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        let source = self as NSString
        let matches = regex.matches(in: self, range: NSRange(location: 0, length: source.length))
        var result: [String] = []
        var previous = 0
        for match in matches {
            result.append(source.substring(with: NSRange(location: previous, length: match.range.location - previous)))
            previous = NSMaxRange(match.range)
        }
        result.append(source.substring(from: previous))
        return result
    }
}

private struct WordCell {
    var paragraphs: [String] = []
    var span = 1
    var continuation = false
}

private final class WordTableReader: NSObject, XMLParserDelegate {
    var tables: [[[WordCell]]] = []
    var outsideParagraphs: [String] = []
    private var tableDepth = 0
    private var row: [WordCell] = []
    private var cell = WordCell()
    private var paragraph = ""
    private var inText = false
    private var inCell = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let tag = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch tag {
        case "tbl":
            tableDepth += 1
            if tableDepth == 1 { tables.append([]) }
        case "tr" where tableDepth == 1: row = []
        case "tc" where tableDepth == 1: cell = WordCell(); inCell = true
        case "gridSpan" where inCell:
            if let val = attributes.first(where: { $0.key == "val" || $0.key.hasSuffix(":val") })?.value, let span = Int(val), span > 0 { cell.span = span }
        case "vMerge" where inCell:
            let val = attributes.first(where: { $0.key == "val" || $0.key.hasSuffix(":val") })?.value
            cell.continuation = val != "restart"
        case "p": paragraph = ""
        case "t": inText = true
        case "tab" where inCell: paragraph += " "
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { paragraph += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let tag = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch tag {
        case "t": inText = false
        case "p":
            if inCell && tableDepth == 1 { cell.paragraphs.append(paragraph) }
            else if tableDepth == 0 { outsideParagraphs.append(paragraph) }
        case "tc" where tableDepth == 1: row.append(cell); inCell = false
        case "tr" where tableDepth == 1: if !tables.isEmpty { tables[tables.count - 1].append(row) }
        case "tbl": tableDepth -= 1
        default: break
        }
    }
}
