import Foundation

/// Pure timephased-work math for the Task Usage view — no drawing here, same split as every other
/// *Layout file in this app. Week/day helpers (mondayAligned/days/addingWeeks) are deliberately not
/// duplicated here: ResourceTimelineLayout's are generic date-grid math with nothing resource-specific
/// about them, so Task Usage reuses those directly.
enum TaskUsageLayout {
    /// A task's work, spread evenly across its own duration — the same "no working-time calendars,
    /// just calendar-day arithmetic" simplification already established by Scheduler/Helper's
    /// DaysFor and BudgetCalculator's cost math. A day either falls in [start, finish) and gets a
    /// flat 8h × Units% for that one assignment, or it doesn't and gets zero — no front/back-loading,
    /// no partial first/last day.
    static func dailyHours(assignment: TaskAssignment, task: GanttTask, on day: Date) -> Double {
        guard let start = task.start, let finish = task.finish, start != finish, day >= start, day < finish else { return 0 }
        return 8 * (assignment.units / 100)
    }

    /// Sum of every assignment's `dailyHours` for `task` on `day` — what the task's own row shows.
    static func totalDailyHours(task: GanttTask, on day: Date) -> Double {
        task.assignments.reduce(0) { $0 + dailyHours(assignment: $1, task: task, on: day) }
    }

    /// A task's total scheduled work across its whole duration — same `durationDays × 8 ×
    /// Units%` convention BudgetCalculator.summary already uses for cost, here just for hours.
    static func totalWork(task: GanttTask) -> Double {
        task.assignments.reduce(0) { $0 + task.durationDays * 8 * ($1.units / 100) }
    }

    /// True if `task` has any work at all inside the visible day range — used to decide whether a
    /// row's resource sub-rows are worth showing at all for a window where the task is entirely
    /// outside the visible weeks (still shown, since Task Usage is one row per task regardless of
    /// the current page, same as the day grid itself always shows every task).
    static func hasWork(task: GanttTask, in days: [Date]) -> Bool {
        days.contains { totalDailyHours(task: task, on: $0) > 0 }
    }
}
