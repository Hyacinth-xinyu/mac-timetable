import Foundation

enum CalendarExportError: LocalizedError {
    case emptyTimetable
    case invalidCourse(String)
    case invalidReminder
    case invalidText(String)

    var errorDescription: String? {
        switch self {
        case .emptyTimetable:
            return "课表为空，请先导入或添加课程。"
        case .invalidCourse(let name):
            return "课程“\(name)”的周次、星期或作息时间不完整或无效，请检查后重试。"
        case .invalidReminder:
            return "提醒时间无效，请检查课前提醒设置。"
        case .invalidText(let name):
            return "课程“\(name)”包含无法导出的控制字符，请修改后重试。"
        }
    }
}

/// 生成整个学期的独立日程，所有课程通过校验后才返回文件内容。
enum CalendarExporter {
    static func export(courses: [Course], settings: AppSettings, timeZone: TimeZone = .current, now: Date = Date()) throws -> Data {
        guard !courses.isEmpty else { throw CalendarExportError.emptyTimetable }
        guard !settings.remindersEnabled || (0...120).contains(settings.reminderMinutes) else {
            throw CalendarExportError.invalidReminder
        }
        guard settings.firstWeekDate.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite else {
            throw CalendarExportError.invalidCourse("学期日期")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        let day = calendar.startOfDay(for: settings.firstWeekDate)
        let daysSinceMonday = (calendar.component(.weekday, from: day) + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: day) else {
            throw CalendarExportError.invalidCourse("学期日期")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"

        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TimetableApp//Calendar Export//ZH-CN", "CALSCALE:GREGORIAN", "METHOD:PUBLISH"]
        var usedIDs = Set<String>()
        for course in courses {
            let label = course.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let errorName = label.isEmpty ? "未命名课程" : label
            guard !label.isEmpty, (1...7).contains(course.weekday),
                  (1...60).contains(course.startPeriod), course.endPeriod >= course.startPeriod,
                  course.endPeriod <= 60, !course.weeks.isEmpty,
                  course.weeks.allSatisfy({ (1...60).contains($0) }),
                  Set(course.weeks).count == course.weeks.count else {
                throw CalendarExportError.invalidCourse(errorName)
            }
            let originalSummary = try escapedText(course.name, course: errorName)
            // 日历月视图常只显示标题，线上课程因此在标题中明确标示。
            let summary = course.isOnline ? "[线上] \(originalSummary)" : originalSummary
            let location = try escapedText(course.location, course: errorName)
            let teacher = try escapedText(course.teacher, course: errorName)
            var periods: [PeriodTime] = []
            for number in course.startPeriod...course.endPeriod {
                let matches = settings.periods.filter { $0.id == number }
                guard matches.count == 1, let period = matches.first,
                      (0..<1440).contains(period.startMinutes), (1...1440).contains(period.endMinutes),
                      period.startMinutes < period.endMinutes,
                      periods.last.map({ $0.endMinutes <= period.startMinutes }) ?? true else {
                    throw CalendarExportError.invalidCourse(errorName)
                }
                periods.append(period)
            }
            guard let startPeriod = periods.first, let endPeriod = periods.last else {
                throw CalendarExportError.invalidCourse(errorName)
            }
            for week in course.weeks.sorted() {
                let uid = "\(course.id.uuidString.lowercased())-w\(week)@timetable.local"
                guard usedIDs.insert(uid).inserted,
                      let date = calendar.date(byAdding: .day, value: (week - 1) * 7 + course.weekday - 1, to: monday),
                      let start = wallTime(on: date, minutes: startPeriod.startMinutes, calendar: calendar),
                      let end = wallTime(on: date, minutes: endPeriod.endMinutes, calendar: calendar),
                      end > start else {
                    throw CalendarExportError.invalidCourse(errorName)
                }
                lines += ["BEGIN:VEVENT", "UID:\(uid)", "DTSTAMP:\(formatter.string(from: now))",
                          "DTSTART:\(formatter.string(from: start))", "DTEND:\(formatter.string(from: end))",
                          "SUMMARY:\(summary)"]
                if !course.location.isEmpty { lines.append("LOCATION:\(location)") }
                if !course.teacher.isEmpty { lines.append("DESCRIPTION:教师：\(teacher)") }
                if settings.remindersEnabled {
                    lines += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:\(originalSummary)",
                              "TRIGGER:-PT\(settings.reminderMinutes)M", "END:VALARM"]
                }
                lines.append("END:VEVENT")
            }
        }
        lines.append("END:VCALENDAR")
        let text = lines.map(fold).joined(separator: "\r\n") + "\r\n"
        return Data(text.utf8)
    }

    private static func wallTime(on day: Date, minutes: Int, calendar: Calendar) -> Date? {
        // 24:00 对应次日零时；其余时间在本地时区按墙上时钟解释。
        let dayOffset = minutes / 1440
        guard let targetDay = calendar.date(byAdding: .day, value: dayOffset, to: day) else { return nil }
        let hour = (minutes % 1440) / 60
        let minute = minutes % 60
        guard let value = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: targetDay),
              calendar.isDate(value, inSameDayAs: targetDay),
              calendar.component(.hour, from: value) == hour,
              calendar.component(.minute, from: value) == minute else { return nil }
        return value
    }

    private static func escapedText(_ text: String, course: String) throws -> String {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D) || value == 0x7F {
                throw CalendarExportError.invalidText(course)
            }
        }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
    }

    /// 每个物理行最多 75 个 UTF-8 字节；续行前缀空格也计入字节数。
    private static func fold(_ line: String) -> String {
        var result = ""
        var count = 0
        for scalar in line.unicodeScalars {
            let value = String(scalar)
            let size = value.utf8.count
            if count + size > 75 { result += "\r\n "; count = 1 }
            result += value
            count += size
        }
        return result
    }
}
