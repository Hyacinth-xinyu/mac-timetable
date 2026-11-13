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

private struct StoredTimetable: Codable {
    var courses: [Course]
    var settings: AppSettings
}

@MainActor
final class AppStore: ObservableObject {
    @Published var courses: [Course] = []
    @Published var settings = AppSettings()
    @Published var statusMessage: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var canSave = true

    private let fileURL: URL
    private let enableSystemIntegration: Bool
    private let notificationPrefix = "timetable.course."
    private var notificationTask: Task<Void, Never>?
    private var refreshTimer: AnyCancellable?

    init(fileURL: URL? = nil, enableSystemIntegration: Bool = true) {
        self.enableSystemIntegration = enableSystemIntegration
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = base.appendingPathComponent("TimetableApp", isDirectory: true).appendingPathComponent("timetable.json")
        }
        do {
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                let data = try Data(contentsOf: self.fileURL)
                let saved = try JSONDecoder().decode(StoredTimetable.self, from: data)
                courses = saved.courses
                settings = saved.settings
            }
        } catch {
            canSave = false
            statusMessage = "读取本地课表失败，已暂停保存以保护原有数据，请检查本地数据文件。"
        }
        if enableSystemIntegration {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            refreshNotifications()
            refreshTimer = Timer.publish(every: 900, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                self?.refreshNotifications()
            }
        }
    }

    /// 写入本机并更新后续通知；写入失败时保留内存数据供用户重试。
    func save() {
        guard canSave else {
            statusMessage = "读取本地课表失败，已暂停保存以保护原有数据，请检查本地数据文件。"
            return
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(StoredTimetable(courses: courses, settings: settings))
            try data.write(to: fileURL, options: .atomic)
            refreshNotifications(requestPermission: settings.remindersEnabled)
        } catch {
            statusMessage = "保存失败，请检查本机存储空间和文件权限。"
        }
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

    /// 系统可安排的待发送通知数量有限，只保留最近的 60 条，并在应用运行时更新。
    func refreshNotifications(requestPermission: Bool = false) {
        guard enableSystemIntegration else { return }
        let previousTask = notificationTask
        previousTask?.cancel()
        let snapshot = courses
        let config = settings
        let prefix = notificationPrefix
        let center = UNUserNotificationCenter.current()
        let candidateDates: [(Course, Date)] = snapshot.flatMap { course -> [(Course, Date)] in
            guard let period = config.periods.first(where: { $0.id == course.startPeriod }),
                  (0..<1440).contains(period.startMinutes) else { return [] }
            return course.weeks.compactMap { week in
                guard let day = date(forWeek: week, weekday: course.weekday),
                      let start = calendar.date(byAdding: .minute, value: period.startMinutes, to: day),
                      let fire = calendar.date(byAdding: .minute, value: -max(0, config.reminderMinutes), to: start),
                      fire > Date() else { return nil }
                return (course, fire)
            }
        }.sorted { $0.1 < $1.1 }
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
