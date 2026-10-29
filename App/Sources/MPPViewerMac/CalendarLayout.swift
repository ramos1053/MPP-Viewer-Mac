import Foundation

/// Pure date math for the Calendar view's month grid — no drawing here, see CalendarView. Kept
/// separate for the same reason NetworkLayout/GanttLayout are: layout math reasoned about on its
/// own, without any SwiftUI involved.
enum CalendarLayout {
    /// Always 6 weeks (42 days) regardless of which month — the fixed worst case for any month's
    /// length/weekday-alignment combination, so the grid never resizes between months and every
    /// month gets the same cell height.
    static func weeks(containing month: Date) -> [[Date]] {
        let cal = Calendar.ganttUTC
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        let weekday = cal.component(.weekday, from: startOfMonth) // 1 = Sunday ... 7 = Saturday
        let daysBack = (weekday - cal.firstWeekday + 7) % 7
        let gridStart = cal.date(byAdding: .day, value: -daysBack, to: startOfMonth) ?? startOfMonth

        var weeks: [[Date]] = []
        var day = gridStart
        for _ in 0..<6 {
            var week: [Date] = []
            for _ in 0..<7 {
                week.append(day)
                day = cal.date(byAdding: .day, value: 1, to: day) ?? day
            }
            weeks.append(week)
        }
        return weeks
    }

    static func isSameMonth(_ a: Date, _ b: Date) -> Bool {
        let cal = Calendar.ganttUTC
        let c1 = cal.dateComponents([.year, .month], from: a)
        let c2 = cal.dateComponents([.year, .month], from: b)
        return c1.year == c2.year && c1.month == c2.month
    }

    static func addingMonths(_ count: Int, to date: Date) -> Date {
        Calendar.ganttUTC.date(byAdding: .month, value: count, to: date) ?? date
    }

    static func startOfDay(_ date: Date) -> Date {
        Calendar.ganttUTC.startOfDay(for: date)
    }

    static func daysBetween(_ from: Date, _ to: Date) -> Int {
        Calendar.ganttUTC.dateComponents([.day], from: from, to: to).day ?? 0
    }
}
