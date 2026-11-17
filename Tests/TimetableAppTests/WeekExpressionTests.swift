import XCTest
@testable import TimetableApp

final class WeekExpressionTests: XCTestCase {
    /// 在临时目录构造最小 Word 表格，不使用真实课程数据。
    private func parse(_ cells: [[String]]) throws -> ImportResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let word = directory.appendingPathComponent("word", isDirectory: true)
        try FileManager.default.createDirectory(at: word, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let headings = ["一", "二", "三", "四", "五", "六", "日"]
            .map { "<w:tc><w:p><w:r><w:t>星期\($0)</w:t></w:r></w:p></w:tc>" }.joined()
        let cellXML = cells.map { lines in
            "<w:tc>" + lines.map { line in
                let escaped = line.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                return "<w:p><w:r><w:t xml:space=\"preserve\">\(escaped)</w:t></w:r></w:p>"
            }.joined() + "</w:tc>"
        }.joined()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:tbl>
        <w:tr><w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr><w:p/></w:tc>\(headings)</w:tr>
        <w:tr><w:tc/><w:tc/>\(cellXML)</w:tr></w:tbl></w:body></w:document>
        """
        try xml.write(to: word.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
        let url = directory.appendingPathComponent("test.docx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = directory
        zip.arguments = ["-q", url.path, "word/document.xml"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return try DocxImporter.parse(url: url)
    }

    func testScreenshotPatternsExpandWeeksAndKeepSeparateLocations() throws {
        let nbsp = "\u{00a0}"
        let result = try parse([
            ["课程甲 90(2~10,12~14,16~17周) (7-8节)\(nbsp)教学楼401\(nbsp)甲老师(11,15周) (7-8节)\(nbsp)线上授课\(nbsp)甲老师"],
            ["课程乙 02(2~5,7~8周) (7-8节)\(nbsp)教学楼301\(nbsp)乙老师"],
            ["课程丙 02(3~5,7~11周) (7-8节)\(nbsp)实验楼107\(nbsp)丙老师"],
            ["课程丁 02(2~6(双),7~9周) (7-8节)\(nbsp)教学楼301\(nbsp)丁老师"]
        ])

        XCTAssertEqual(result.courses.count, 5)
        let a = result.courses.filter { $0.name == "课程甲" }
        XCTAssertEqual(a.count, 2)
        if a.count == 2 {
            XCTAssertEqual(a[0].weeks, Array(2...10) + Array(12...14) + [16, 17])
            XCTAssertEqual(a[0].location, "教学楼401")
            XCTAssertEqual(a[1].weeks, [11, 15])
            XCTAssertEqual(a[1].location, "线上授课")
            XCTAssertEqual(a.map(\.teacher), ["甲老师", "甲老师"])
        }
        XCTAssertEqual(result.courses.first(where: { $0.name == "课程乙" })?.weeks, [2, 3, 4, 5, 7, 8])
        XCTAssertEqual(result.courses.first(where: { $0.name == "课程丙" })?.weeks, [3, 4, 5, 7, 8, 9, 10, 11])
        let d = result.courses.first(where: { $0.name == "课程丁" })
        XCTAssertEqual(d?.weeks, [2, 4, 6, 7, 8, 9])
        XCTAssertEqual(d?.weekday, 4)
        XCTAssertTrue(result.courses.allSatisfy { $0.startPeriod == 7 && $0.endPeriod == 8 })
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testFirstCombinedGroupDoesNotPolluteNameOrHideLaterGroups() throws {
        let nbsp = "\u{00a0}"
        let line = "课程甲 01(2~5,7~8周) (1-2节)\(nbsp)楼101\(nbsp)甲老师(6周) (1-2节)\(nbsp)楼102\(nbsp)甲老师(9~15周) (1-2节)\(nbsp)楼103\(nbsp)乙老师"
        let result = try parse([[line]])
        XCTAssertEqual(result.courses.count, 3)
        XCTAssertEqual(result.courses.map(\.name), ["课程甲", "课程甲", "课程甲"])
        XCTAssertEqual(result.courses.map(\.weeks), [[2, 3, 4, 5, 7, 8], [6], Array(9...15)])
        XCTAssertEqual(result.courses.map(\.location), ["楼101", "楼102", "楼103"])
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testUnknownFirstGroupIsReportedEvenWhenLaterGroupParses() throws {
        let nbsp = "\u{00a0}"
        let bad = "待核课程 01(2~5,待定周) (1-2节)\(nbsp)楼101\(nbsp)甲老师(6周) (1-2节)\(nbsp)楼102\(nbsp)甲老师"
        let valid = "正常课程 02(1~3周) (1-2节)\(nbsp)楼103\(nbsp)乙老师"
        let result = try parse([[bad, valid]])
        XCTAssertTrue(result.warnings.contains { $0.contains(bad) } || result.skipped.contains { $0.contains(bad) })
        let parsed = result.courses.filter { $0.rawText == bad }
        XCTAssertTrue(parsed.allSatisfy { $0.name == "待核课程" })
        XCTAssertTrue(parsed.allSatisfy { $0.weeks == [6] })
        XCTAssertNotNil(result.courses.first(where: { $0.name == "正常课程" }))
    }

    func testEntireUnrecognizedCourseIsSkippedWithOriginalText() throws {
        let nbsp = "\u{00a0}"
        let bad = "待核课程 01(2~5,待定周) (1-2节)\(nbsp)楼101\(nbsp)甲老师"
        let anchor = "正常课程 02(1~3周) (1-2节)\(nbsp)楼102\(nbsp)乙老师"
        let result = try parse([[bad, anchor]])
        XCTAssertTrue(result.skipped.contains { $0.contains(bad) })
        XCTAssertFalse(result.courses.contains { $0.rawText == bad })
        XCTAssertNotNil(result.courses.first(where: { $0.name == "正常课程" }))
    }

    func testAllUnrecognizedStillReturnsPreviewWithOriginalText() throws {
        let bad = "待核课程 01(2~5,待定周) (1-2节)\u{00a0}楼101\u{00a0}甲老师"
        let result = try parse([[bad]])
        XCTAssertTrue(result.courses.isEmpty)
        XCTAssertEqual(result.skipped, [bad])
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testMalformedLaterGroupCannotBeSilentlyDropped() throws {
        let nbsp = "\u{00a0}"
        let malformed = "课程甲 01(1~2周) (1-2节)\(nbsp)楼101\(nbsp)甲老师(2~5,,7周) (1-2节)\(nbsp)楼102\(nbsp)甲老师"
        let reversed = "课程乙 02(1周) (3-4节)\(nbsp)楼201\(nbsp)乙老师(5~3,7周) (3-4节)\(nbsp)楼202\(nbsp)乙老师"
        let result = try parse([[malformed, reversed]])
        for line in [malformed, reversed] {
            XCTAssertTrue(result.warnings.contains { $0.contains(line) } || result.skipped.contains { $0.contains(line) })
        }
        XCTAssertTrue(result.courses.filter { $0.rawText == malformed }.allSatisfy { $0.name == "课程甲" && $0.weeks == [1, 2] })
        XCTAssertTrue(result.courses.filter { $0.rawText == reversed }.allSatisfy { $0.name == "课程乙" && $0.weeks == [1] })
    }

    func testSingleDoubleSegmentsUseTheirOwnParityAndPreserveLegacy() throws {
        let nbsp = "\u{00a0}"
        let result = try parse([[
            "组合课 01(1~7(单),2~6(双),9周) (3-4节)\(nbsp)楼101\(nbsp)甲老师",
            "传统课 02(2~8(双)周) (5-6节)\(nbsp)楼102\(nbsp)乙老师",
            "单周课 03(11周) (7-8节)\(nbsp)楼103\(nbsp)丙老师"
        ]])
        XCTAssertEqual(result.courses.first(where: { $0.name == "组合课" })?.weeks, [1, 2, 3, 4, 5, 6, 7, 9])
        XCTAssertEqual(result.courses.first(where: { $0.name == "传统课" })?.weeks, [2, 4, 6, 8])
        XCTAssertEqual(result.courses.first(where: { $0.name == "单周课" })?.weeks, [11])
    }

    func testChinesePunctuationAndOverlappingRanges() throws {
        let line = "组合课 01（1～3，3～5、7（单）周）（1-2节）\u{00a0}楼101\u{00a0}甲老师"
        let result = try parse([[line]])
        XCTAssertEqual(result.courses.count, 1)
        XCTAssertEqual(result.courses.first?.weeks, [1, 2, 3, 4, 5, 7])
        XCTAssertTrue(result.skipped.isEmpty)
    }
}
