import XCTest
@testable import TimetableApp

final class MultiTimetableTests: XCTestCase {
    private struct Legacy: Codable {
        var courses: [Course]
        var settings: AppSettings
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MultiTimetableTests-\(UUID().uuidString)").appendingPathComponent("data.json")
    }

    private func localDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testLegacyMigrationPreservesDataAndSelectedAcrossRestart() async throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let course = Course(name: "我的课程", weekday: 1, startPeriod: 1, endPeriod: 2, weeks: [1, 3])
        var settings = AppSettings()
        settings.firstWeekDate = localDate(2026, 8, 31)
        settings.remindersEnabled = true
        let legacyData = try JSONEncoder().encode(Legacy(courses: [course], settings: settings))
        let expectedSettings = settings
        try legacyData.write(to: file)

        await MainActor.run {
            let store = AppStore(fileURL: file, enableSystemIntegration: false)
            XCTAssertTrue(store.canSave)
            XCTAssertEqual(store.courses, [course])
            XCTAssertEqual(store.settings, expectedSettings)
            XCTAssertEqual(store.selectedTimetableID, store.ownTimetableID)
            let otherID = store.addTimetable(name: "小明")!
            XCTAssertEqual(store.settings.firstWeekDate, expectedSettings.firstWeekDate)
            XCTAssertEqual(store.settings.periods, expectedSettings.periods)
            XCTAssertFalse(store.settings.remindersEnabled)
            XCTAssertTrue(store.courses.isEmpty)
            let other = Course(name: "其他课程", weekday: 2, startPeriod: 3, endPeriod: 4, weeks: [2])
            XCTAssertTrue(store.updateCourses([other], forID: otherID))
            let restored = AppStore(fileURL: file, enableSystemIntegration: false)
            XCTAssertEqual(restored.selectedTimetableID, otherID)
            XCTAssertEqual(restored.courses, [other])
            XCTAssertEqual(restored.timetable(id: restored.ownTimetableID)?.courses, [course])
            XCTAssertEqual(restored.timetable(id: restored.ownTimetableID)?.settings, expectedSettings)
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual(object?["version"] as? Int, 2)
    }

    func testBoundUpdatesIndependentSettingsAndExportSnapshot() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        await MainActor.run {
            let store = AppStore(fileURL: file, enableSystemIntegration: false)
            let own = store.ownTimetableID
            let ownCourse = Course(name: "本人的课", weekday: 1, startPeriod: 1, endPeriod: 2, weeks: [1])
            XCTAssertTrue(store.updateCourses([ownCourse], forID: own))
            var ownSettings = store.settings
            ownSettings.firstWeekDate = localDate(2026, 8, 31)
            ownSettings.remindersEnabled = true
            XCTAssertTrue(store.updateSettings(ownSettings, forID: own))
            let other = store.addTimetable(name: "朋友")!
            var otherSettings = store.settings
            otherSettings.firstWeekDate = localDate(2027, 2, 22)
            otherSettings.periods[0].startMinutes = 500
            otherSettings.remindersEnabled = true
            XCTAssertTrue(store.updateSettings(otherSettings, forID: other))
            let otherCourse = Course(name: "朋友的课", weekday: 3, startPeriod: 1, endPeriod: 2, weeks: [2])
            XCTAssertTrue(store.updateCourses([otherCourse], forID: other))
            XCTAssertTrue(store.selectTimetable(id: own))
            let replacement = Course(name: "后台编辑朋友的课", weekday: 2, startPeriod: 1, endPeriod: 1, weeks: [2])
            XCTAssertTrue(store.updateCourses([replacement], forID: other))
            XCTAssertEqual(store.courses, [ownCourse])
            XCTAssertEqual(store.settings, ownSettings)
            XCTAssertEqual(store.timetable(id: other)?.courses, [replacement])
            XCTAssertEqual(store.timetable(id: other)?.settings.firstWeekDate, otherSettings.firstWeekDate)
            let ownExport = store.exportSnapshot(id: own)!
            let otherExport = store.exportSnapshot(id: other)!
            XCTAssertTrue(ownExport.settings.remindersEnabled)
            XCTAssertFalse(otherExport.settings.remindersEnabled)
            let text = String(data: try! CalendarExporter.export(courses: otherExport.courses, settings: otherExport.settings), encoding: .utf8)!
            XCTAssertTrue(text.contains("后台编辑朋友的课"))
            XCTAssertFalse(text.contains("本人的课"))
            XCTAssertFalse(text.contains("BEGIN:VALARM"))
            XCTAssertTrue(store.renameTimetable(id: other, name: "同学"))
            XCTAssertFalse(store.deleteTimetable(id: own))
            XCTAssertTrue(store.deleteTimetable(id: other))
            XCTAssertNil(store.timetable(id: other))
            XCTAssertFalse(store.updateCourses([replacement], forID: other))
            XCTAssertEqual(store.courses, [ownCourse])
        }
    }

    func testOwnNotificationsUseOwnDateWhileViewingSomeoneElse() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        await MainActor.run {
            let store = AppStore(fileURL: file, enableSystemIntegration: false)
            let own = store.ownTimetableID
            var config = store.settings
            config.firstWeekDate = localDate(2026, 8, 31)
            config.remindersEnabled = true
            config.reminderMinutes = 10
            let ownCourse = Course(name: "自己的课", weekday: 1, startPeriod: 1, endPeriod: 1, weeks: [2])
            XCTAssertTrue(store.updateSettings(config, forID: own))
            XCTAssertTrue(store.updateCourses([ownCourse], forID: own))
            let other = store.addTimetable(name: "朋友")!
            var otherConfig = store.settings
            otherConfig.firstWeekDate = localDate(2027, 2, 22)
            otherConfig.periods[0].startMinutes = 700
            XCTAssertTrue(store.updateSettings(otherConfig, forID: other))
            XCTAssertTrue(store.updateCourses([Course(name: "朋友的课", weekday: 1, startPeriod: 1, endPeriod: 1, weeks: [2])], forID: other))
            let candidates = store.ownNotificationCandidates(now: localDate(2026, 1, 1))
            XCTAssertEqual(candidates.map { $0.0.name }, ["自己的课"])
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: candidates[0].1)
            XCTAssertEqual(parts.year, 2026); XCTAssertEqual(parts.month, 9); XCTAssertEqual(parts.day, 7)
            XCTAssertEqual(parts.hour, 8); XCTAssertEqual(parts.minute, 20)
        }
    }

    func testMigrationFailureProtectsLegacyAndDisablesNotificationCandidates() async throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var settings = AppSettings()
        settings.remindersEnabled = true
        let original = try JSONEncoder().encode(Legacy(courses: [Course(name: "课", weeks: [1])], settings: settings))
        try original.write(to: file)
        await MainActor.run {
            let store = AppStore(fileURL: file, enableSystemIntegration: false, writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
            XCTAssertFalse(store.canSave)
            XCTAssertFalse(store.save())
            XCTAssertTrue(store.ownNotificationCandidates(now: .distantPast).isEmpty)
            XCTAssertNotNil(store.statusMessage)
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testFailedWritesRollBackMutationsAndPreserveFile() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        final class FailureFlag { var fail = false }
        let flag = FailureFlag()
        try await MainActor.run {
            let store = AppStore(fileURL: file, enableSystemIntegration: false, writeData: { data, url in
                if flag.fail { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            })
            let own = store.ownTimetableID
            let other = store.addTimetable(name: "朋友")!
            XCTAssertTrue(store.selectTimetable(id: own))
            let original = try Data(contentsOf: file)
            let before = store.timetables
            flag.fail = true
            XCTAssertNil(store.addTimetable(name: "新朋友"))
            XCTAssertEqual(store.timetables, before)
            XCTAssertEqual(store.selectedTimetableID, own)
            XCTAssertFalse(store.selectTimetable(id: other))
            XCTAssertEqual(store.selectedTimetableID, own)
            XCTAssertFalse(store.renameTimetable(id: other, name: "改名"))
            XCTAssertEqual(store.timetables, before)
            XCTAssertFalse(store.deleteTimetable(id: other))
            XCTAssertEqual(store.timetables, before)
            XCTAssertFalse(store.updateCourses([Course(name: "课程")], forID: other))
            XCTAssertEqual(store.timetables, before)
            var changed = store.settings
            changed.remindersEnabled.toggle()
            XCTAssertFalse(store.updateSettings(changed, forID: own))
            XCTAssertNotEqual(store.settings, changed)
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }
}
