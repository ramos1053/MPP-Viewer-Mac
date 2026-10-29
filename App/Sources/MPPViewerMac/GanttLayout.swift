import SwiftUI

let ganttRowHeight: CGFloat = 22
let ganttHeaderHeight: CGFloat = 34

func ganttContentHeight(taskCount: Int) -> CGFloat {
    ganttHeaderHeight + CGFloat(taskCount) * ganttRowHeight
}

func ganttTotalDays(range: ClosedRange<Date>) -> Int {
    max(1, Calendar.ganttUTC.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day ?? 1)
}

func ganttContentWidth(range: ClosedRange<Date>, pixelsPerDay: CGFloat) -> CGFloat {
    CGFloat(ganttTotalDays(range: range)) * pixelsPerDay + 80
}

/// Inverts ganttContentWidth for "Fit to Window": the pixelsPerDay that makes the full date range
/// span exactly `paneWidth`. Deliberately not clamped to the 1...60 steps the manual zoom buttons
/// use — Fit needs to reach whatever value actually fits, however small (a long project) or large
/// (a short one) that is.
func ganttFitPixelsPerDay(range: ClosedRange<Date>, paneWidth: CGFloat) -> CGFloat {
    max(0.05, (paneWidth - 80) / CGFloat(ganttTotalDays(range: range)))
}
