import Foundation
import Combine
import UserNotifications
import ServiceManagement

struct Course: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var teacher: String
    var location: String
    /// 周一为 1，周日为 7。
    var weekday: Int
    var startPeriod: Int
    var endPeriod: Int
    var weeks: [Int]
    /// 保留原文，便于识别结果不确定时核对。
    var rawText: String

    init(id: UUID = UUID(), name: String = "", teacher: String = "", location: String = "", weekday: Int = 1, startPeriod: Int = 1, endPeriod: Int = 1, weeks: [Int] = [], rawText: String = "") {
        self.id = id
        self.name = name
        self.teacher = teacher
        self.location = location
        self.weekday = weekday
        self.startPeriod = startPeriod
        self.endPeriod = endPeriod
        self.weeks = weeks
        self.rawText = rawText
    }
}

struct PeriodTime: Codable, Hashable, Identifiable {
    var id: Int
    /// 当天零时起的分钟数。
    var startMinutes: Int
    var endMinutes: Int

    init(id: Int, startMinutes: Int, endMinutes: Int) {
        self.id = id
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }
}

struct AppSettings: Codable, Hashable {
    var firstWeekDate: Date = Date()
    /// 西北工业大学 2026–2027 学年长安校区作息，可在设置中调整。
    static let changAnPeriods: [PeriodTime] = [
        (8, 30, 9, 15), (9, 25, 10, 10), (10, 30, 11, 15),
        (11, 25, 12, 10), (12, 20, 13, 5), (13, 5, 13, 50),
        (14, 0, 14, 45), (14, 55, 15, 40), (16, 0, 16, 45),
        (16, 55, 17, 40), (19, 0, 19, 45), (19, 55, 20, 40),
        (20, 40, 21, 25)
    ].enumerated().map { index, value in
        PeriodTime(id: index + 1, startMinutes: value.0 * 60 + value.1, endMinutes: value.2 * 60 + value.3)
    }
    var periods: [PeriodTime] = AppSettings.changAnPeriods
    var remindersEnabled: Bool = false
    var reminderMinutes: Int = 10
}

struct TimetableRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var courses: [Course]
    var settings: AppSettings
}

private struct StoredTimetable: Codable {
    var courses: [Course]
    var settings: AppSettings
}

private struct StoredTimetables: Codable {
    var version: Int = 2
    var timetables: [TimetableRecord]
    var ownTimetableID: UUID
    var selectedTimetableID: UUID
}

@MainActor
final class AppStore: ObservableObject {
    @Published var courses: [Course] = []
    @Published var settings = AppSettings()
    @Published private(set) var timetables: [TimetableRecord] = []
    @Published private(set) var ownTimetableID = UUID()
    @Published private(set) var selectedTimetableID = UUID()
    @Published var statusMessage: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var canSave = true

    private let fileURL: URL
    private let enableSystemIntegration: Bool
    private let writeData: (Data, URL) throws -> Void
    private let notificationPrefix = "timetable.course."
    private var notificationTask: Task<Void, Never>?
    private var refreshTimer: AnyCancellable?

    init(fileURL: URL? = nil, enableSystemIntegration: Bool = true, writeData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.enableSystemIntegration = enableSystemIntegration
        self.writeData = writeData
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = base.appendingPathComponent("TimetableApp", isDirectory: true).appendingPathComponent("timetable.json")
        }
        let ownID = UUID()
        ownTimetableID = ownID
        selectedTimetableID = ownID
        timetables = [TimetableRecord(id: ownID, name: "我的课表", courses: [], settings: settings)]
        do {
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                let data = try Data(contentsOf: self.fileURL)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                if object["version"] != nil || object["timetables"] != nil {
                    let saved = try JSONDecoder().decode(StoredTimetables.self, from: data)
                    let ids = saved.timetables.map(\.id)
                    guard saved.version == 2, !ids.isEmpty, Set(ids).count == ids.count,
                          ids.contains(saved.ownTimetableID), ids.contains(saved.selectedTimetableID) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    timetables = saved.timetables
                    ownTimetableID = saved.ownTimetableID
                    selectedTimetableID = saved.selectedTimetableID
                    loadSelected()
                } else {
                    let saved = try JSONDecoder().decode(StoredTimetable.self, from: data)
                    let migrated = TimetableRecord(id: ownID, name: "我的课表", courses: saved.courses, settings: saved.settings)
                    timetables = [migrated]
                    courses = saved.courses
                    settings = saved.settings
                    // 先完整解码再原子写入，迁移失败不覆盖旧文件。
                    let output = StoredTimetables(timetables: timetables, ownTimetableID: ownID, selectedTimetableID: ownID)
                    try self.writeData(JSONEncoder().encode(output), self.fileURL)
                }
            }
        } catch {
            canSave = false
            statusMessage = "读取本地课表失败，已暂停保存以保护原有数据，请检查本地数据文件。"
        }
        if enableSystemIntegration {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if canSave { refreshNotifications() }
            refreshTimer = Timer.publish(every: 900, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                self?.refreshNotifications()
            }
        }
    }

    /// 写入本机并更新后续通知；写入失败时保留内存数据供用户重试。
    @discardableResult
    func save(refreshOwnNotifications: Bool = true) -> Bool {
        guard canSave else {
            statusMessage = "读取本地课表失败，已暂停保存以保护原有数据，请检查本地数据文件。"
            return false
        }
        do {
            syncSelected()
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(StoredTimetables(timetables: timetables, ownTimetableID: ownTimetableID, selectedTimetableID: selectedTimetableID))
            try writeData(data, fileURL)
            if let message = statusMessage, ["请输入课表名称。", "已有同名课表，请使用不同的名称。", "保存失败，请检查本机存储空间和文件权限。", "目标课表不存在或无法保存，请重新选择课表。"].contains(message) {
                statusMessage = nil
            }
            if refreshOwnNotifications {
                let own = timetable(id: ownTimetableID)
                refreshNotifications(requestPermission: own?.settings.remindersEnabled == true)
            }
            return true
        } catch {
            statusMessage = "保存失败，请检查本机存储空间和文件权限。"
            return false
        }
    }

    private func syncSelected() {
        guard let index = timetables.firstIndex(where: { $0.id == selectedTimetableID }) else { return }
        timetables[index].courses = courses
        timetables[index].settings = settings
    }

    private func loadSelected() {
        guard let selected = timetables.first(where: { $0.id == selectedTimetableID }) else { return }
        courses = selected.courses
        settings = selected.settings
    }

    private struct StateBackup {
        var timetables: [TimetableRecord]
        var selected: UUID
        var courses: [Course]
        var settings: AppSettings
    }

    private func stateBackup() -> StateBackup {
        StateBackup(timetables: timetables, selected: selectedTimetableID, courses: courses, settings: settings)
    }

    private func restore(_ backup: StateBackup) {
        timetables = backup.timetables
        selectedTimetableID = backup.selected
        courses = backup.courses
        settings = backup.settings
    }

    private func ownHasUncommittedChanges() -> Bool {
        guard selectedTimetableID == ownTimetableID,
              let stored = timetables.first(where: { $0.id == ownTimetableID }) else { return false }
        return stored.courses != courses || stored.settings != settings
    }

    var selectedTimetable: TimetableRecord? { timetable(id: selectedTimetableID) }

    func timetable(id: UUID) -> TimetableRecord? {
        guard var item = timetables.first(where: { $0.id == id }) else { return nil }
        if id == selectedTimetableID { item.courses = courses; item.settings = settings }
        return item
    }

    /// 他人的日历导出不携带提醒，以免为他人安排自己的通知。
    func exportSnapshot(id: UUID) -> TimetableRecord? {
        guard var item = timetable(id: id) else { return nil }
        if id != ownTimetableID { item.settings.remindersEnabled = false }
        return item
    }

    private func validName(_ name: String, excluding id: UUID? = nil) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { statusMessage = "请输入课表名称。"; return nil }
        guard !timetables.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(value) == .orderedSame }) else {
            statusMessage = "已有同名课表，请使用不同的名称。"; return nil
        }
        return value
    }

    @discardableResult
    func addTimetable(name: String) -> UUID? {
        guard canSave, let name = validName(name), let own = timetable(id: ownTimetableID) else { return nil }
        let backup = stateBackup()
        let refresh = ownHasUncommittedChanges()
        syncSelected()
        var initialSettings = own.settings
        initialSettings.remindersEnabled = false
        let item = TimetableRecord(id: UUID(), name: name, courses: [], settings: initialSettings)
        timetables.append(item)
        selectedTimetableID = item.id
        loadSelected()
        guard save(refreshOwnNotifications: refresh) else { restore(backup); return nil }
        return item.id
    }

    @discardableResult
    func selectTimetable(id: UUID) -> Bool {
        guard canSave, timetables.contains(where: { $0.id == id }) else { return false }
        if id == selectedTimetableID { return true }
        let backup = stateBackup()
        let refresh = ownHasUncommittedChanges()
        syncSelected()
        selectedTimetableID = id
        loadSelected()
        guard save(refreshOwnNotifications: refresh) else { restore(backup); return false }
        return true
    }

    @discardableResult
    func renameTimetable(id: UUID, name: String) -> Bool {
        guard canSave, let index = timetables.firstIndex(where: { $0.id == id }),
              let name = validName(name, excluding: id) else { return false }
        let backup = stateBackup()
        let refresh = ownHasUncommittedChanges()
        timetables[index].name = name
        guard save(refreshOwnNotifications: refresh) else { restore(backup); return false }
        return true
    }

    @discardableResult
    func deleteTimetable(id: UUID) -> Bool {
        guard canSave, id != ownTimetableID, timetables.contains(where: { $0.id == id }) else { return false }
        let backup = stateBackup()
        let refresh = ownHasUncommittedChanges()
        syncSelected()
        timetables.removeAll { $0.id == id }
        if selectedTimetableID == id { selectedTimetableID = ownTimetableID; loadSelected() }
        guard save(refreshOwnNotifications: refresh) else { restore(backup); return false }
        return true
    }

    @discardableResult
    func updateCourses(_ value: [Course], forID id: UUID) -> Bool {
        guard canSave, let index = timetables.firstIndex(where: { $0.id == id }) else {
            statusMessage = "目标课表不存在或无法保存，请重新选择课表。"; return false
        }
        let backup = stateBackup()
        let refresh = id == ownTimetableID || ownHasUncommittedChanges()
        if id == selectedTimetableID { courses = value } else { timetables[index].courses = value }
        guard save(refreshOwnNotifications: refresh) else { restore(backup); return false }
        return true
    }

    @discardableResult
    func updateSettings(_ value: AppSettings, forID id: UUID) -> Bool {
        guard canSave, let index = timetables.firstIndex(where: { $0.id == id }) else {
            statusMessage = "目标课表不存在或无法保存，请重新选择课表。"; return false
        }
        let backup = stateBackup()
        let refresh = id == ownTimetableID || ownHasUncommittedChanges()
        var updated = value
        if id != ownTimetableID { updated.remindersEnabled = false }
        if id == selectedTimetableID { settings = updated } else { timetables[index].settings = updated }
        guard save(refreshOwnNotifications: refresh) else { restore(backup); return false }
        return true
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private func monday(containing date: Date) -> Date {
        let start = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: start)
        let daysFromMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysFromMonday, to: start) ?? start
    }

    func weekNumber(for date: Date = Date()) -> Int {
        let days = calendar.dateComponents([.day], from: monday(containing: settings.firstWeekDate), to: monday(containing: date)).day ?? 0
        return days / 7 + 1
    }

    func date(forWeek week: Int, weekday: Int) -> Date? {
        date(forWeek: week, weekday: weekday, settings: settings)
    }

    private func date(forWeek week: Int, weekday: Int, settings: AppSettings) -> Date? {
        guard week > 0, (1...7).contains(weekday) else { return nil }
        return calendar.date(byAdding: .day, value: (week - 1) * 7 + weekday - 1, to: monday(containing: settings.firstWeekDate))
    }

    func courses(forWeek week: Int) -> [Course] {
        courses.filter { $0.weeks.contains(week) }.sorted {
            if $0.weekday != $1.weekday { return $0.weekday < $1.weekday }
            if $0.startPeriod != $1.startPeriod { return $0.startPeriod < $1.startPeriod }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && !launchAtLogin {
                statusMessage = "请在系统设置的登录项中允许课表开机启动。"
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            statusMessage = "无法更改开机启动设置，请检查系统设置中的登录项。"
        }
    }

    /// 仅根据自己的课表计算提醒，切换查看其他人不影响日期和课程。
    func ownNotificationCandidates(now: Date = Date()) -> [(Course, Date)] {
        guard canSave, let own = timetable(id: ownTimetableID), own.settings.remindersEnabled else { return [] }
        let config = own.settings
        return own.courses.flatMap { course -> [(Course, Date)] in
            guard let period = config.periods.first(where: { $0.id == course.startPeriod }),
                  (0..<1440).contains(period.startMinutes) else { return [] }
            return course.weeks.compactMap { week in
                guard let day = date(forWeek: week, weekday: course.weekday, settings: config),
                      let start = calendar.date(byAdding: .minute, value: period.startMinutes, to: day),
                      let fire = calendar.date(byAdding: .minute, value: -max(0, config.reminderMinutes), to: start),
                      fire > now else { return nil }
                return (course, fire)
            }
        }.sorted { $0.1 < $1.1 }
    }

    /// 系统可安排的待发送通知数量有限，只保留最近的 60 条，并在应用运行时更新。
    func refreshNotifications(requestPermission: Bool = false) {
        guard enableSystemIntegration, canSave, let own = timetable(id: ownTimetableID) else { return }
        let previousTask = notificationTask
        previousTask?.cancel()
        let config = own.settings
        let prefix = notificationPrefix
        let center = UNUserNotificationCenter.current()
        let candidateDates = ownNotificationCandidates()
        notificationTask = Task {
            await previousTask?.value
            guard !Task.isCancelled else { return }
            let pending = await center.pendingNotificationRequests()
            guard !Task.isCancelled else { return }
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
            guard config.remindersEnabled else { return }
            var permission = await center.notificationSettings().authorizationStatus
            if permission == .notDetermined && requestPermission {
                do {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                    permission = await center.notificationSettings().authorizationStatus
                } catch {
                    statusMessage = "无法请求通知权限，请在系统设置中检查通知权限。"
                    return
                }
            }
            guard permission == .authorized || permission == .provisional else {
                if permission == .denied { statusMessage = "通知权限已关闭，请在系统设置中允许课表通知。" }
                return
            }
            for (course, fireDate) in candidateDates.prefix(60) {
                guard !Task.isCancelled else { return }
                let content = UNMutableNotificationContent()
                content.title = "即将上课：\(course.name)"
                content.body = course.location.isEmpty ? "课程即将开始" : "地点：\(course.location)"
                content.sound = .default
                let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let request = UNNotificationRequest(identifier: "\(prefix)\(course.id.uuidString).\(Int(fireDate.timeIntervalSince1970))", content: content, trigger: trigger)
                do { try await center.add(request) }
                catch { statusMessage = "部分提醒未能安排，请检查系统通知设置。"; return }
            }
        }
    }
}
