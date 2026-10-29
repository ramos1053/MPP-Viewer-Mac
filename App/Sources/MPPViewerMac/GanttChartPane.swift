import SwiftUI

/// The chart side of the split, hosted in a real NSScrollView (both axes) kept vertically synced
/// to the task list via GanttScrollSync. See SyncedScrollHost for why this isn't a plain SwiftUI
/// ScrollView.
struct GanttChartPane: View {
    let tasks: [GanttTask]
    let tasksVersion: Int
    let range: ClosedRange<Date>
    let pixelsPerDay: CGFloat
    let selectedTaskId: Int?
    let onSelect: (Int) -> Void
    let sync: GanttScrollSync
    let showCriticalPath: Bool

    var body: some View {
        SyncedScrollHost(
            content: TimelineCanvas(
                tasks: tasks, tasksVersion: tasksVersion, range: range, pixelsPerDay: pixelsPerDay,
                selectedTaskId: selectedTaskId, onSelect: onSelect, showCriticalPath: showCriticalPath),
            contentSize: CGSize(
                width: ganttContentWidth(range: range, pixelsPerDay: pixelsPerDay),
                height: ganttContentHeight(taskCount: tasks.count)),
            allowsHorizontalScroll: true,
            sync: sync,
            role: .right
        )
    }
}
