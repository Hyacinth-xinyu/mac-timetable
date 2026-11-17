import XCTest
@testable import TimetableApp

final class CalendarExporterTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    private func localDate(_ year: Int, _ month: Int, _ day: Int, zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func unfolded(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n ", with: "")
    }

    func testDatesAcrossYearAndDiscontinuousWeeks() throws {
        var settings = AppSettings()
        settings.firstWeekDate = localDate(2026, 1, 4, zone: shanghai)
        let course = Course(name: "课程", weekday: 1, startPeriod: 1, endPeriod: 2, weeks: [1, 3, 5])
        let data = try CalendarExporter.export(courses: [course], settings: settings, timeZone: shanghai)
        let text = unfolded(data)
        XCTAssertEqual(text.components(separatedBy: "BEGIN:VEVENT").count - 1, 3)
        for date in ["20251229", "20260112", "20260126"] {
            XCTAssertTrue(text.contains("DTSTART:\(date)T003000Z"))
            XCTAssertTrue(text.contains("DTEND:\(date)T021000Z"))
        }
        XCTAssertFalse(text.contains("20260105T003000Z"))
        XCTAssertFalse(text.contains("BEGIN:VALARM"))
    }

    func testTimeZoneAndDaylightSavingAreAppliedPerOccurrence() throws {
        let newYork = TimeZone(identifier: "America/New_York")!
        var settings = AppSettings()
        settings.firstWeekDate = localDate(2026, 3, 2, zone: newYork)
        let course = Course(name: "课程", weekday: 1, startPeriod: 1, endPeriod: 1, weeks: [1, 2])
        let text = unfolded(try CalendarExporter.export(courses: [course], settings: settings, timeZone: newYork))
        XCTAssertTrue(text.contains("DTSTART:20260302T133000Z"))
        XCTAssertTrue(text.contains("DTSTART:20260309T123000Z"))
        settings.periods[0] = PeriodTime(id: 1, startMinutes: 150, endMinutes: 210)
        let missingHour = Course(name: "缺失时间", weekday: 7, weeks: [1])
        XCTAssertThrowsError(try CalendarExporter.export(courses: [missingHour], settings: settings, timeZone: newYork))
    }

    func testEscapingLineFoldingReminderAndStableUID() throws {
        var settings = AppSettings()
        settings.firstWeekDate = localDate(2026, 8, 31, zone: shanghai)
        settings.remindersEnabled = true
        settings.reminderMinutes = 15
        let name = String(repeating: "中文课程", count: 12) + ",分号;斜线\\\n换行"
        let course = Course(name: name, teacher: "教师；甲", location: "教室,一号", weeks: [2, 4])
        let data = try CalendarExporter.export(courses: [course], settings: settings, timeZone: shanghai, now: Date(timeIntervalSince1970: 0))
        let physical = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        XCTAssertTrue(physical.allSatisfy { $0.utf8.count <= 75 })
        let text = unfolded(data)
        XCTAssertTrue(text.contains("SUMMARY:" + String(repeating: "中文课程", count: 12) + "\\,分号\\;斜线\\\\\\n换行"))
        XCTAssertTrue(text.contains("LOCATION:教室\\,一号"))
        XCTAssertTrue(text.contains("DESCRIPTION:教师：教师；甲"))
        XCTAssertTrue(text.contains("TRIGGER:-PT15M"))
        XCTAssertEqual(text.components(separatedBy: "BEGIN:VALARM").count - 1, 2)
        XCTAssertTrue(text.contains("UID:\(course.id.uuidString.lowercased())-w2@timetable.local"))
        let second = unfolded(try CalendarExporter.export(courses: [course], settings: settings, timeZone: shanghai))
        XCTAssertTrue(second.contains("UID:\(course.id.uuidString.lowercased())-w2@timetable.local"))
    }

    func testInvalidInputsNeverProducePartialExport() throws {
        let valid = Course(name: "课程", weeks: [1])
        var settings = AppSettings()
        XCTAssertThrowsError(try CalendarExporter.export(courses: [], settings: settings))
        XCTAssertThrowsError(try CalendarExporter.export(courses: [valid, Course(name: "无周次")], settings: settings))
        XCTAssertThrowsError(try CalendarExporter.export(courses: [Course(name: "缺少节次", startPeriod: 13, endPeriod: 14, weeks: [1])], settings: settings))
        XCTAssertThrowsError(try CalendarExporter.export(courses: [Course(name: "控制\u{0001}字符", weeks: [1])], settings: settings))
        XCTAssertThrowsError(try CalendarExporter.export(courses: [valid, valid], settings: settings))
        settings.remindersEnabled = true
        settings.reminderMinutes = -1
        XCTAssertThrowsError(try CalendarExporter.export(courses: [valid], settings: settings))
    }

    func testOptionalAnonymousFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["TIMETABLE_ICS_FIXTURE"] else { return }
        var settings = AppSettings()
        settings.firstWeekDate = localDate(2026, 8, 31, zone: shanghai)
        settings.remindersEnabled = true
        settings.reminderMinutes = 10
        let course = Course(name: "示例课程", teacher: "示例教师", location: "示例教室", weekday: 2, startPeriod: 1, endPeriod: 2, weeks: [1, 3])
        try CalendarExporter.export(courses: [course], settings: settings, timeZone: shanghai).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
