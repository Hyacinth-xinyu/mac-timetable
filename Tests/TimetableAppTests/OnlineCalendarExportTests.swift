import XCTest
@testable import TimetableApp

final class OnlineCalendarExportTests: XCTestCase {
    func testCalendarDistinguishesOnlineAndInPersonOccurrences() throws {
        var settings = AppSettings()
        settings.remindersEnabled = true
        settings.reminderMinutes = 10
        let sharedRawText = "示例课同时有教室和线上授课"
        let classroom = Course(name: "示例课", teacher: "示例教师", location: "网络实验室101", weeks: [1], rawText: sharedRawText)
        let online = Course(name: "示例课", teacher: "示例教师", location: "线上授课", weeks: [2], rawText: sharedRawText)

        let data = try CalendarExporter.export(courses: [classroom, online], settings: settings, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n ", with: "")
        let events = text.components(separatedBy: "BEGIN:VEVENT").dropFirst()
        XCTAssertEqual(events.count, 2)
        let onsite = try XCTUnwrap(events.first { $0.contains("UID:\(classroom.id.uuidString.lowercased())-w1@timetable.local") })
        let remote = try XCTUnwrap(events.first { $0.contains("UID:\(online.id.uuidString.lowercased())-w2@timetable.local") })
        XCTAssertTrue(onsite.contains("SUMMARY:示例课\r\n"))
        XCTAssertFalse(onsite.contains("SUMMARY:[线上]"))
        XCTAssertTrue(onsite.contains("LOCATION:网络实验室101\r\n"))
        XCTAssertTrue(remote.contains("SUMMARY:[线上] 示例课\r\n"))
        XCTAssertTrue(remote.contains("LOCATION:线上授课\r\n"))
        for event in [onsite, remote] {
            XCTAssertTrue(event.contains("DESCRIPTION:教师：示例教师\r\n"))
            XCTAssertTrue(event.contains("BEGIN:VALARM\r\n"))
            XCTAssertTrue(event.contains("DESCRIPTION:示例课\r\n"))
            XCTAssertTrue(event.contains("TRIGGER:-PT10M\r\n"))
        }
    }
}
