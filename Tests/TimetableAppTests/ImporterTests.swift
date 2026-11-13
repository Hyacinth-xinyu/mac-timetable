import XCTest
@testable import TimetableApp

final class ImporterTests: XCTestCase {
    private func document(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("word"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)</w:body></w:document>
        """
        try xml.write(to: directory.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        let output = directory.appendingPathComponent("test.docx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = directory
        zip.arguments = ["-q", output.path, "word/document.xml"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return output
    }

    private var header: String {
        "<w:tr><w:tc><w:tcPr><w:gridSpan w:val=\"2\"/></w:tcPr><w:p/></w:tc>" +
        ["一", "二", "三", "四", "五", "六", "日"].map { "<w:tc><w:p><w:r><w:t>星期\($0)</w:t></w:r></w:p></w:tc>" }.joined() + "</w:tr>"
    }

    func testMergedCellsMultipleSchedulesAndUnscheduledNotes() throws {
        let body = """
        <w:tbl>\(header)
        <w:tr><w:tc><w:p/></w:tc><w:tc><w:p><w:r><w:t>1</w:t></w:r></w:p></w:tc>
        <w:tc><w:tcPr><w:vMerge w:val="restart"/></w:tcPr><w:p><w:r><w:t>课程甲 01(1~3周) (1-2节)&#160;楼101&#160;张三(4~8(双)周) (1-2节)&#160;楼102&#160;李四14院</w:t></w:r></w:p><w:p><w:r><w:t>课程乙 02(1~5(单)周) (1-2节)&#160;楼103&#160;王五</w:t></w:r></w:p></w:tc>
        </w:tr><w:tr><w:tc><w:p/></w:tc><w:tc><w:p><w:r><w:t>2</w:t></w:r></w:p></w:tc><w:tc><w:tcPr><w:vMerge/></w:tcPr><w:p><w:r><w:t>不应重复导入</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        <w:p><w:r><w:t>备注:&#160;1.未安排课程 A01 (1~8)&#160;&#160;2.另一课程 A02 (2~4)</w:t></w:r></w:p>
        """
        let result = try DocxImporter.parse(url: document(body))
        XCTAssertEqual(result.courses.count, 3)
        XCTAssertEqual(result.courses.map(\.weeks), [[1, 2, 3], [4, 6, 8], [1, 3, 5]])
        XCTAssertEqual(result.courses.map(\.weekday), [1, 1, 1])
        XCTAssertEqual(result.courses.map(\.teacher), ["张三", "李四", "王五"])
        XCTAssertEqual(result.courses.map(\.location), ["楼101", "楼102", "楼103"])
        XCTAssertEqual(result.skipped.count, 2)
    }

    func testUnrecognizedOrPartiallyRecognizedContentIsReported() throws {
        let body = """
        <w:tbl>\(header)<w:tr><w:tc/><w:tc/><w:tc><w:p><w:r><w:t>课程甲 01(1~3周) (1-2节)&#160;楼101&#160;张三(4~8周) 时间待定</w:t></w:r></w:p><w:p><w:r><w:t>无法识别课程</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """
        let result = try DocxImporter.parse(url: document(body))
        XCTAssertEqual(result.courses.count, 1)
        XCTAssertTrue(result.warnings.contains { $0.contains("部分课程安排无法识别") })
        XCTAssertEqual(result.skipped, ["无法识别课程"])
    }

    func testInvalidAndUnsupportedFilesThrow() throws {
        let unsupported = try document("<w:p><w:r><w:t>普通文档</w:t></w:r></w:p>")
        XCTAssertThrowsError(try DocxImporter.parse(url: unsupported))
        XCTAssertThrowsError(try DocxImporter.parse(url: unsupported.deletingPathExtension().appendingPathExtension("txt")))
        let empty = try document("<w:tbl>\(header)</w:tbl>")
        XCTAssertThrowsError(try DocxImporter.parse(url: empty))
    }
}
