import Foundation

/// Pure cost math — no SwiftUI here, same split as every other *Layout file in this app.
///
/// This app has no working-time calendars (see Scheduler's own doc comment) — every cost figure
/// here is built on the same already-established 8-hour-day simplification Helper's `DaysFor` uses
/// for duration, not real timephased work. A resource's rate (entered in any of Hours/Days/Weeks/
/// Months/Years, see ResourceSheetView's RateCell) is first normalized to an hourly-equivalent using
/// that same convention before being multiplied against a task's duration.
enum BudgetCalculator {
    struct ResourceCost: Identifiable {
        let resourceId: Int
        let plannedCost: Double
        let earnedCost: Double
        /// Total hours this resource is scheduled for across every assignment, regardless of
        /// completion — "billable hours" in the sense of hours they're booked/chargeable for.
        let scheduledHours: Double
        /// `scheduledHours` weighted by each task's own % Complete — hours of work actually done so
        /// far, i.e. "time used."
        let completedHours: Double
        var id: Int { resourceId }
    }

    struct Summary {
        /// Full cost of everything scheduled, regardless of how much is actually done — "what this
        /// project will cost if everything assigned gets carried out as planned."
        let plannedCost: Double
        /// `plannedCost` weighted by each task's own % Complete — "what's actually been incurred so
        /// far, at a rough progress-weighted estimate." This is what the budget warning compares
        /// against, per the project-wide-budget, progress-weighted design this app uses.
        let earnedCost: Double
        let perResource: [ResourceCost]
    }

    enum Status {
        case noBudget
        case onTrack
        case nearing
        case overBudget

        /// 85% is the usual "heads up" threshold this kind of progress-vs-budget warning uses —
        /// comfortably before 100%, close enough to be worth a look, not so early it cries wolf on
        /// every project that's merely begun spending.
        static let nearingThreshold = 0.85
    }

    static func summary(tasks: [GanttTask], resourcesById: [Int: ResourceDto]) -> Summary {
        var planned = 0.0
        var earned = 0.0
        var perResourcePlanned: [Int: Double] = [:]
        var perResourceEarned: [Int: Double] = [:]
        var perResourceScheduledHours: [Int: Double] = [:]
        var perResourceCompletedHours: [Int: Double] = [:]

        for task in tasks {
            let progress = max(0, min(1, task.percent / 100))
            for assignment in task.assignments {
                guard let resource = resourcesById[assignment.resourceId] else { continue }
                let hourlyRate = hourlyEquivalent(amount: resource.standardRateAmount, unit: resource.standardRateUnit)
                let workHours = task.durationDays * 8 * (assignment.units / 100)
                let cost = workHours * hourlyRate + resource.costPerUse
                planned += cost
                earned += cost * progress
                perResourcePlanned[resource.uniqueId, default: 0] += cost
                perResourceEarned[resource.uniqueId, default: 0] += cost * progress
                perResourceScheduledHours[resource.uniqueId, default: 0] += workHours
                perResourceCompletedHours[resource.uniqueId, default: 0] += workHours * progress
            }
        }

        let perResource = perResourcePlanned.keys.map { id in
            ResourceCost(
                resourceId: id, plannedCost: perResourcePlanned[id] ?? 0, earnedCost: perResourceEarned[id] ?? 0,
                scheduledHours: perResourceScheduledHours[id] ?? 0, completedHours: perResourceCompletedHours[id] ?? 0)
        }
        return Summary(plannedCost: planned, earnedCost: earned, perResource: perResource)
    }

    /// Same per-assignment math as `summary(tasks:resourcesById:)`, scoped to one resource — used by
    /// the Resource Detail panel, which doesn't need every other resource's numbers too.
    static func resourceCost(for resourceId: Int, tasks: [GanttTask], resourcesById: [Int: ResourceDto]) -> ResourceCost {
        summary(tasks: tasks, resourcesById: resourcesById).perResource.first { $0.resourceId == resourceId }
            ?? ResourceCost(resourceId: resourceId, plannedCost: 0, earnedCost: 0, scheduledHours: 0, completedHours: 0)
    }

    static func status(earnedCost: Double, budget: Double) -> Status {
        guard budget > 0 else { return .noBudget }
        let fraction = earnedCost / budget
        if fraction >= 1 { return .overBudget }
        if fraction >= Status.nearingThreshold { return .nearing }
        return .onTrack
    }

    /// Converts a rate given in any unit to its $/hour equivalent, using the same 8-hour-day,
    /// 5-day-week (so ~20 workdays/month, ~250 workdays/year) convention the rest of this app's
    /// calendar-day arithmetic already relies on.
    static func hourlyEquivalent(amount: Double, unit: String) -> Double {
        switch unit {
        case "Hours": amount
        case "Days": amount / 8
        case "Weeks": amount / 40
        case "Months": amount / 160
        case "Years": amount / 2000
        default: amount
        }
    }
}
