import Foundation

struct MenuScheduleSnapshot {
    let week: Int
    let today: [Course]
    let next: (course: Course, date: Date)?
}

@MainActor
enum MenuSchedule {
    static func snapshot(store: AppStore, now: Date) -> MenuScheduleSnapshot {
        let calendar = Calendar.current
        let week = store.weekNumber(for: now)
        let weekday = (calendar.component(.weekday, from: now) + 5) % 7 + 1
        let today = store.courses(forWeek: week).filter { $0.weekday == weekday }
        let next = store.courses.flatMap { course -> [(course: Course, date: Date)] in
            guard let period = store.settings.periods.first(where: { $0.id == course.startPeriod }),
                  (0..<1440).contains(period.startMinutes) else { return [] }
            return course.weeks.compactMap { week in
                guard let day = store.date(forWeek: week, weekday: course.weekday),
                      let start = calendar.date(byAdding: .minute, value: period.startMinutes, to: day),
                      start > now else { return nil }
                return (course, start)
            }
        }.min { $0.date < $1.date }
        return MenuScheduleSnapshot(week: week, today: today, next: next)
    }
}
