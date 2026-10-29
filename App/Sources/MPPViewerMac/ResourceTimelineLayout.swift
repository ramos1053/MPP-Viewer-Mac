import Foundation

/// Pure date/allocation math for the Calendar view's "Team" mode (ResourceTimelineView) — no
/// drawing here, same split as CalendarLayout/NetworkLayout/GanttLayout.
enum ResourceTimelineLayout {
    /// One bar to draw: a task assigned to the resource whose row it's drawn in, plus that specific
    /// assignment (for its Units% and as the thing "Remove from <Resource>" edits).
    struct Bar: Identifiable {
        let task: GanttTask
        let assignment: TaskAssignment
        var id: String { "\(task.id)-\(assignment.resourceId)" }
    }

    /// Always Monday-aligned regardless of `Calendar.ganttUTC.firstWeekday` — a resource-scheduling
    /// week reads as a work week (Mon–Fri performed, Sat/Sun shaded), independent of whatever the
    /// Month mode's grid uses for its first-weekday convention.
    static func mondayAligned(_ date: Date) -> Date {
        let cal = Calendar.ganttUTC
        let weekday = cal.component(.weekday, from: date) // 1 = Sunday ... 7 = Saturday
        let daysSinceMonday = (weekday + 5) % 7 // Monday -> 0, Tuesday -> 1, ..., Sunday -> 6
        return cal.date(byAdding: .day, value: -daysSinceMonday, to: cal.startOfDay(for: date)) ?? date
    }

    static func days(from weekStart: Date, count: Int) -> [Date] {
        let cal = Calendar.ganttUTC
        return (0..<count).map { cal.date(byAdding: .day, value: $0, to: weekStart) ?? weekStart }
    }

    static func addingWeeks(_ count: Int, to date: Date) -> Date {
        Calendar.ganttUTC.date(byAdding: .day, value: count * 7, to: date) ?? date
    }

    /// Every task assigned (at all) to `resourceId`, paired with that one assignment — a task
    /// assigned to several resources appears once per resource's row, each time with just its own
    /// assignment, not the others.
    static func bars(for resourceId: Int, in tasks: [GanttTask]) -> [Bar] {
        tasks.compactMap { task in
            guard let assignment = task.assignments.first(where: { $0.resourceId == resourceId }) else { return nil }
            return Bar(task: task, assignment: assignment)
        }
    }

    /// Sum of Units% from every assignment whose task spans `day`, for the over-allocation strip —
    /// a resource double-booked at 50%+60% on the same day reads as 110%, same convention Resource
    /// Sheet's Max Units bar already uses for "over 100%."
    static func allocatedUnits(for resourceId: Int, on day: Date, in tasks: [GanttTask]) -> Double {
        let dayEnd = Calendar.ganttUTC.date(byAdding: .day, value: 1, to: day) ?? day
        return tasks.reduce(0) { total, task in
            guard let assignment = task.assignments.first(where: { $0.resourceId == resourceId }),
                  let start = task.start, let finish = task.finish,
                  start < dayEnd, finish >= day
            else { return total }
            return total + assignment.units
        }
    }
}
