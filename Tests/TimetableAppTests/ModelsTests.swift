import XCTest
@testable import TimetableApp

final class ModelsTests: XCTestCase {
    func testChangAnPeriodTimesMatchPublishedSchedule() {
        let periods = AppSettings().periods
        XCTAssertEqual(periods.map(\.id), Array(1...13))
        XCTAssertEqual(periods.map(\.startMinutes), [510, 565, 630, 685, 740, 785, 840, 895, 960, 1015, 1140, 1195, 1240])
        XCTAssertEqual(periods.map(\.endMinutes), [555, 610, 675, 730, 785, 830, 885, 940, 1005, 1060, 1185, 1240, 1285])
    }

    func testApplyingChangAnTimesPreservesOtherSavedData() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        await MainActor.run {
            let store = AppStore(fileURL: file, enableSystemIntegration: false)
            let course = Course(name: "课程 A", weekday: 1, startPeriod: 1, endPeriod: 2, weeks: [1, 3])
            store.courses = [course]
            store.settings.firstWeekDate = date(2026, 8, 31)
            store.settings.remindersEnabled = true
            store.settings.reminderMinutes = 15
            store.settings.periods[0] = PeriodTime(id: 1, startMinutes: 480, endMinutes: 525)
            store.save()

            let existing = AppStore(fileURL: file, enableSystemIntegration: false)
            existing.settings.periods = AppSettings.changAnPeriods
            existing.save()
            let restored = AppStore(fileURL: file, enableSystemIntegration: false)
            XCTAssertEqual(restored.courses, [course])
            XCTAssertEqual(restored.settings.firstWeekDate, date(2026, 8, 31))
            XCTAssertTrue(restored.settings.remindersEnabled)
            XCTAssertEqual(restored.settings.reminderMinutes, 15)
            XCTAssertEqual(restored.settings.periods, AppSettings.changAnPeriods)
        }
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TimetableTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("data.json")
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testTeachingWeeksAreMondayBasedAndCrossYear() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        await MainActor.run {
            let store = AppStore(fileURL: file, enableSystemIntegration: false)
            // 周日仍属于从 12 月 29 日开始的第一周。
            store.settings.firstWeekDate = date(2026, 1, 4)
            XCTAssertEqual(store.weekNumber(for: date(2025, 12, 29)), 1)
            XCTAssertEqual(store.weekNumber(for: date(2026, 1, 4)), 1)
            XCTAssertEqual(store.weekNumber(for: date(2026, 1, 5)), 2)
            XCTAssertEqual(store.weekNumber(for: date(2025, 12, 28)), 0)
            let sunday = store.date(forWeek: 2, weekday: 7)!
            XCTAssertTrue(Calendar.current.isDate(sunday, inSameDayAs: date(2026, 1, 11)))
            XCTAssertNil(store.date(forWeek: 0, weekday: 1))
            XCTAssertNil(store.date(forWeek: 1, weekday: 8))
        }
    }

    func testPersistenceRoundTripAndWeekFiltering() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        await MainActor.run {
            let store = AppStore(fileURL: file, enableSystemIntegration: false)
            let first = Course(name: "课程 A", teacher: "老师", location: "教室", weekday: 2, startPeriod: 3, endPeriod: 4, weeks: [1, 3], rawText: "原文")
            let second = Course(name: "课程 B", weekday: 1, startPeriod: 1, endPeriod: 2, weeks: [3])
            store.courses = [first, second]
            store.settings.firstWeekDate = date(2026, 3, 2)
            store.settings.periods[0] = PeriodTime(id: 1, startMinutes: 490, endMinutes: 535)
            store.settings.remindersEnabled = true
            store.settings.reminderMinutes = 15
            store.save()
            XCTAssertTrue(store.canSave)
            let restored = AppStore(fileURL: file, enableSystemIntegration: false)
            XCTAssertEqual(restored.courses, [first, second])
            XCTAssertEqual(restored.settings, store.settings)
            XCTAssertEqual(restored.courses(forWeek: 1).map(\.id), [first.id])
            XCTAssertEqual(restored.courses(forWeek: 3).map(\.id), [second.id, first.id])
            XCTAssertTrue(restored.courses(forWeek: 2).isEmpty)
        }
    }

    func testCorruptDataIsNeverOverwrittenBySave() async throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let original = Data("invalid local data".utf8)
        try original.write(to: file)
        await MainActor.run {
            let store = AppStore(fileURL: file, enableSystemIntegration: false)
            XCTAssertFalse(store.canSave)
            XCTAssertNotNil(store.statusMessage)
            store.courses = [Course(name: "不会覆盖原始文件")]
            store.save()
            XCTAssertFalse(store.canSave)
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
