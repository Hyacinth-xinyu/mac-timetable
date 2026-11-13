import XCTest
@testable import TimetableApp

final class MenuScheduleTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @MainActor private func makeStore() -> AppStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MenuScheduleTests-\(UUID().uuidString).json")
        return AppStore(fileURL: file, enableSystemIntegration: false)
    }

    func testCrossMidnightAndWeekBoundaries() async {
        await MainActor.run {
            let store = makeStore()
            store.settings.firstWeekDate = date(2026, 8, 31)
            let sunday = Course(name: "周日课", weekday: 7, startPeriod: 1, endPeriod: 2, weeks: [1])
            let monday = Course(name: "周一课", weekday: 1, startPeriod: 1, endPeriod: 2, weeks: [2])
            store.courses = [monday, sunday]

            let beforeMidnight = MenuSchedule.snapshot(store: store, now: date(2026, 9, 6, 23, 59))
            XCTAssertEqual(beforeMidnight.week, 1)
            XCTAssertEqual(beforeMidnight.today.map(\.id), [sunday.id])
            XCTAssertEqual(beforeMidnight.next?.course.id, monday.id)
            XCTAssertEqual(beforeMidnight.next?.date, date(2026, 9, 7, 8, 30))

            let afterMidnight = MenuSchedule.snapshot(store: store, now: date(2026, 9, 7, 0, 1))
            XCTAssertEqual(afterMidnight.week, 2)
            XCTAssertEqual(afterMidnight.today.map(\.id), [monday.id])
            XCTAssertEqual(afterMidnight.next?.course.id, monday.id)
        }
    }

    func testNextCourseChangesAtStartAndSkipsMissingPeriod() async {
        await MainActor.run {
            let store = makeStore()
            store.settings.firstWeekDate = date(2026, 8, 31)
            let first = Course(name: "第一门", weekday: 1, startPeriod: 1, endPeriod: 1, weeks: [1])
            let second = Course(name: "第二门", weekday: 1, startPeriod: 2, endPeriod: 2, weeks: [1])
            let noTime = Course(name: "无作息", weekday: 1, startPeriod: 20, endPeriod: 20, weeks: [1])
            store.courses = [second, noTime, first]
            let before = MenuSchedule.snapshot(store: store, now: date(2026, 8, 31, 8, 29))
            XCTAssertEqual(before.today.map(\.id), [first.id, second.id, noTime.id])
            XCTAssertEqual(before.next?.course.id, first.id)
            let atStart = MenuSchedule.snapshot(store: store, now: date(2026, 8, 31, 8, 30))
            XCTAssertEqual(atStart.next?.course.id, second.id)
            let afterAll = MenuSchedule.snapshot(store: store, now: date(2026, 8, 31, 23, 0))
            XCTAssertNil(afterAll.next)
        }
    }

    func testEmptyAndOutsideSemester() async {
        await MainActor.run {
            let store = makeStore()
            store.settings.firstWeekDate = date(2026, 8, 31)
            let empty = MenuSchedule.snapshot(store: store, now: date(2026, 8, 30, 12))
            XCTAssertTrue(empty.today.isEmpty)
            XCTAssertNil(empty.next)
            let course = Course(name: "开学后", weekday: 1, startPeriod: 1, endPeriod: 2, weeks: [1])
            store.courses = [course]
            let beforeSemester = MenuSchedule.snapshot(store: store, now: date(2026, 8, 30, 12))
            XCTAssertTrue(beforeSemester.today.isEmpty)
            XCTAssertEqual(beforeSemester.next?.course.id, course.id)
        }
    }
}
