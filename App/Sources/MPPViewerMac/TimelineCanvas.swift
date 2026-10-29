import SwiftUI

/// Thin outer wrapper: hosts the heavy drawing (CanvasContent, below) plus a cheap selection
/// highlight overlay and the row-tap gesture. Selecting a row is the single most frequent
/// interaction in this app, so it must not force a full redraw — see CanvasContent's doc comment.
struct TimelineCanvas: View, Equatable {
    let tasks: [GanttTask]
    /// Bumped by AppModel on every assignment to `tasks` — see its doc comment. Used here instead
    /// of a deep `tasks == tasks` comparison, which was real, repeated cost on every single click
    /// just to confirm a pure selection change hadn't touched the data.
    let tasksVersion: Int
    let range: ClosedRange<Date>
    let pixelsPerDay: CGFloat
    let selectedTaskId: Int?
    let onSelect: (Int) -> Void
    let showCriticalPath: Bool

    // Ignores `onSelect` (closures aren't Equatable) — lets SyncedScrollHost skip redrawing this
    // Canvas on every pixel of an unrelated divider drag, which is what was causing the jank.
    nonisolated static func == (lhs: TimelineCanvas, rhs: TimelineCanvas) -> Bool {
        lhs.tasksVersion == rhs.tasksVersion && lhs.range == rhs.range
            && lhs.pixelsPerDay == rhs.pixelsPerDay && lhs.selectedTaskId == rhs.selectedTaskId
            && lhs.showCriticalPath == rhs.showCriticalPath
    }

    private var rowIndexByTaskId: [Int: Int] {
        Dictionary(uniqueKeysWithValues: tasks.enumerated().map { ($1.id, $0) })
    }

    private var contentWidth: CGFloat { ganttContentWidth(range: range, pixelsPerDay: pixelsPerDay) }
    private var contentHeight: CGFloat { ganttContentHeight(taskCount: tasks.count) }

    var body: some View {
        let rowIndex = rowIndexByTaskId
        ZStack(alignment: .topLeading) {
            CanvasContent(
                tasks: tasks, tasksVersion: tasksVersion, range: range, pixelsPerDay: pixelsPerDay,
                rowIndex: rowIndex, showCriticalPath: showCriticalPath)
                .equatable()
            if let selectedTaskId, let index = rowIndex[selectedTaskId] {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.25))
                    .frame(width: contentWidth, height: ganttRowHeight)
                    .offset(y: CGFloat(index) * ganttRowHeight + ganttHeaderHeight)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
        .gesture(
            SpatialTapGesture().onEnded { value in
                let index = Int((value.location.y - ganttHeaderHeight) / ganttRowHeight)
                if tasks.indices.contains(index) {
                    onSelect(tasks[index].id)
                }
            }
        )
    }
}

/// The actual drawing — header, weekend shading, row grid, today line, dependency links, task
/// bars — as one Canvas. A SwiftUI Canvas is immediate-mode: there's no sub-view diffing inside
/// it, so ANY redraw repaints 100% of its content, however many tasks there are. Selection used to
/// be drawn inside this same Canvas, which meant clicking a row redrew every bar/link/grid line
/// from scratch — fine at 73 tasks, but an O(task count) cost on literally every click, which would
/// only get worse on a larger project. Equatable here deliberately excludes selection (handled by
/// the cheap overlay in TimelineCanvas instead), so `.equatable()` at the call site lets SwiftUI
/// skip re-running this entirely when only the selection changed.
private struct CanvasContent: View, Equatable {
    let tasks: [GanttTask]
    let tasksVersion: Int
    let range: ClosedRange<Date>
    let pixelsPerDay: CGFloat
    let rowIndex: [Int: Int]
    let showCriticalPath: Bool

    nonisolated static func == (lhs: CanvasContent, rhs: CanvasContent) -> Bool {
        lhs.tasksVersion == rhs.tasksVersion && lhs.range == rhs.range && lhs.pixelsPerDay == rhs.pixelsPerDay
            && lhs.showCriticalPath == rhs.showCriticalPath
    }

    private var totalDays: Int { ganttTotalDays(range: range) }
    private var contentWidth: CGFloat { ganttContentWidth(range: range, pixelsPerDay: pixelsPerDay) }
    private var contentHeight: CGFloat { ganttContentHeight(taskCount: tasks.count) }

    /// Every 7th day at normal zoom, every day once zoomed in, every ~month once zoomed out.
    private var tickStepDays: Int {
        if pixelsPerDay >= 18 { return 1 }
        if pixelsPerDay >= 5 { return 7 }
        return 30
    }

    var body: some View {
        Canvas { context, size in
            drawWeekendShading(context: context, size: size)
            drawRowGrid(context: context, size: size)
            drawHeader(context: context, size: size)
            drawLinks(context: context, rowIndex: rowIndex)
            drawBars(context: context)
            drawTodayLine(context: context, size: size)
        }
        .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
    }

    private func x(for date: Date) -> CGFloat {
        let days = Calendar.ganttUTC.dateComponents([.day], from: range.lowerBound, to: date).day ?? 0
        return CGFloat(days) * pixelsPerDay
    }

    private func rowY(_ index: Int) -> CGFloat { ganttHeaderHeight + CGFloat(index) * ganttRowHeight }

    private func drawWeekendShading(context: GraphicsContext, size: CGSize) {
        var day = 0
        while day <= totalDays {
            let date = Calendar.ganttUTC.date(byAdding: .day, value: day, to: range.lowerBound) ?? range.lowerBound
            let weekday = Calendar.ganttUTC.component(.weekday, from: date) // 1 = Sunday, 7 = Saturday
            if weekday == 1 || weekday == 7 {
                let rect = CGRect(x: x(for: date), y: ganttHeaderHeight, width: pixelsPerDay, height: size.height - ganttHeaderHeight)
                context.fill(Path(rect), with: .color(.gray.opacity(0.08)))
            }
            day += 1
        }
    }

    private func drawRowGrid(context: GraphicsContext, size: CGSize) {
        for index in 0..<tasks.count {
            let y = rowY(index)
            if index.isMultiple(of: 2) {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: ganttRowHeight)), with: .color(.gray.opacity(0.04)))
            }
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y + ganttRowHeight))
            line.addLine(to: CGPoint(x: size.width, y: y + ganttRowHeight))
            context.stroke(line, with: .color(.gray.opacity(0.2)), lineWidth: 0.5)
        }
    }

    private func drawHeader(context: GraphicsContext, size: CGSize) {
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: ganttHeaderHeight)),
                      with: .color(Color(nsColor: .controlBackgroundColor)))

        var day = 0
        var currentMonth = -1
        while day <= totalDays {
            let date = Calendar.ganttUTC.date(byAdding: .day, value: day, to: range.lowerBound) ?? range.lowerBound
            let comps = Calendar.ganttUTC.dateComponents([.month, .day], from: date)
            let xPos = CGFloat(day) * pixelsPerDay

            if comps.month != currentMonth {
                currentMonth = comps.month ?? currentMonth
                var tick = Path()
                tick.move(to: CGPoint(x: xPos, y: 0))
                tick.addLine(to: CGPoint(x: xPos, y: ganttHeaderHeight))
                context.stroke(tick, with: .color(.secondary.opacity(0.5)))
                context.draw(
                    Text(Self.monthFormatter.string(from: date)).font(.caption).bold(),
                    at: CGPoint(x: xPos + 4, y: 9), anchor: .leading)
            }

            if day % tickStepDays == 0 {
                var tick = Path()
                tick.move(to: CGPoint(x: xPos, y: ganttHeaderHeight / 2))
                tick.addLine(to: CGPoint(x: xPos, y: ganttHeaderHeight))
                context.stroke(tick, with: .color(.secondary.opacity(0.3)))
                context.draw(
                    Text("\(comps.day ?? 0)").font(.caption2),
                    at: CGPoint(x: xPos + 2, y: ganttHeaderHeight - 9), anchor: .leading)
            }
            day += 1
        }

        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: ganttHeaderHeight - 0.5))
        baseline.addLine(to: CGPoint(x: size.width, y: ganttHeaderHeight - 0.5))
        context.stroke(baseline, with: .color(.secondary))
    }

    private func drawTodayLine(context: GraphicsContext, size: CGSize) {
        let today = Date()
        guard range.contains(today) else { return }
        let xPos = x(for: today)
        var line = Path()
        line.move(to: CGPoint(x: xPos, y: 0))
        line.addLine(to: CGPoint(x: xPos, y: size.height))
        context.stroke(line, with: .color(.red.opacity(0.6)), lineWidth: 1)
    }

    private func drawBars(context: GraphicsContext) {
        for (index, task) in tasks.enumerated() {
            guard let start = task.start, let finish = task.finish, finish >= start else { continue }
            let midY = rowY(index) + ganttRowHeight / 2
            let x0 = x(for: start)
            let x1 = x(for: finish)

            if task.isMilestone {
                let half: CGFloat = 5
                var diamond = Path()
                diamond.move(to: CGPoint(x: x0, y: midY - half))
                diamond.addLine(to: CGPoint(x: x0 + half, y: midY))
                diamond.addLine(to: CGPoint(x: x0, y: midY + half))
                diamond.addLine(to: CGPoint(x: x0 - half, y: midY))
                diamond.closeSubpath()
                context.fill(diamond, with: .color(.orange))
                drawLabel(context: context, task: task, after: x0 + half, midY: midY)
            } else if task.isSummary {
                let width = max(2, x1 - x0)
                var bracket = Path()
                bracket.addRect(CGRect(x: x0, y: midY - 4, width: width, height: 4))
                bracket.addRect(CGRect(x: x0, y: midY - 4, width: 3, height: 9))
                bracket.addRect(CGRect(x: x1 - 3, y: midY - 4, width: 3, height: 9))
                context.fill(bracket, with: .color(.primary))
                drawLabel(context: context, task: task, after: x1, midY: midY, bold: true)
            } else {
                let width = max(3, x1 - x0)
                let rect = CGRect(x: x0, y: midY - 7, width: width, height: 14)
                let color: Color = (showCriticalPath && task.isCritical) ? .red : .accentColor
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color.opacity(0.85)))

                if task.percent > 0 {
                    let fillWidth = width * CGFloat(min(100, task.percent) / 100)
                    let overlay = CGRect(x: x0, y: midY - 2, width: fillWidth, height: 4)
                    context.fill(Path(roundedRect: overlay, cornerRadius: 2), with: .color(.black.opacity(0.35)))
                }

                drawLabel(context: context, task: task, after: x1, midY: midY)
            }
        }
    }

    /// Trailing label after a bar/milestone/summary shape — the task name, same text shown in the
    /// task list's Task Name column, plus resource names for ordinary tasks (matching what used to
    /// be the only label drawn here).
    private func drawLabel(context: GraphicsContext, task: GanttTask, after x: CGFloat, midY: CGFloat, bold: Bool = false) {
        var label = task.name
        if !task.resourceNames.isEmpty {
            label += "  [\(task.resourceNames)]"
        }
        var text = Text(label).font(.caption2)
        if bold { text = text.bold() }
        context.draw(text, at: CGPoint(x: x + 4, y: midY), anchor: .leading)
    }

    private func drawLinks(context: GraphicsContext, rowIndex: [Int: Int]) {
        for (successorIndex, task) in tasks.enumerated() {
            for link in task.links {
                guard
                    let predecessorIndex = rowIndex[link.predecessorId],
                    let predecessor = tasks[safe: predecessorIndex],
                    let predStart = predecessor.start, let predFinish = predecessor.finish,
                    let succStart = task.start, let succFinish = task.finish
                else { continue }

                let fromX = x(for: link.type == "SS" || link.type == "SF" ? predStart : predFinish)
                let toX = x(for: link.type == "FF" || link.type == "SF" ? succFinish : succStart)
                let fromY = rowY(predecessorIndex) + ganttRowHeight / 2
                let toY = rowY(successorIndex) + ganttRowHeight / 2
                let color: Color = (showCriticalPath && predecessor.isCritical && task.isCritical) ? .red : .secondary

                var path = Path()
                let midX = fromX + 8
                path.move(to: CGPoint(x: fromX, y: fromY))
                path.addLine(to: CGPoint(x: midX, y: fromY))
                path.addLine(to: CGPoint(x: midX, y: toY))
                path.addLine(to: CGPoint(x: toX, y: toY))
                context.stroke(path, with: .color(color.opacity(0.7)), lineWidth: 1)

                var arrow = Path()
                arrow.move(to: CGPoint(x: toX - 4, y: toY - 3))
                arrow.addLine(to: CGPoint(x: toX, y: toY))
                arrow.addLine(to: CGPoint(x: toX - 4, y: toY + 3))
                context.stroke(arrow, with: .color(color.opacity(0.7)), lineWidth: 1)
            }
        }
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
