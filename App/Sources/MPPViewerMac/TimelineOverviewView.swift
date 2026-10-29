import SwiftUI

/// A condensed, single-glance overview of the project — Microsoft Project's own "Timeline" view:
/// every top-level task as a bar (or a diamond, for milestones) along one shared date axis, stacked
/// into as few rows as needed to avoid overlapping. Always shows the whole project span scaled to
/// fit the pane (see ViewMode.supportsZoom) — it exists to be glanced at, not drilled into.
///
/// Styled as a card floating over the window background — gradient-filled bars with a soft shadow,
/// a hover lift, a glowing ring on selection, and a today marker — rather than flat rectangles, so
/// this reads as a deliberately designed summary view, not a debug overlay.
///
/// No ToolbarContentDivider of its own — see ResourceSheetView's doc comment for why.
struct TimelineOverviewView: View {
    let tasks: [GanttTask]
    let range: ClosedRange<Date>
    let showCriticalPath: Bool
    let selectedTaskId: Int?
    let onSelect: (Int) -> Void
    /// Double-click, or right-click → "Jump to WBS" — same convention as every other view's bars
    /// (Calendar, Network, Team mode).
    let onJumpToWBS: (Int) -> Void
    /// Right-click → "Delete Task" — routes through AppModel.pendingTaskAction like every other
    /// delete entry point, so it gets the same WBS-renumbering confirmation dialog.
    let onDeleteRequest: (Int) -> Void
    /// Right-click → "Notes…" — opens the same NotesEditor popover every other view's bars use.
    let onEditNotes: (Int, String) -> Void

    @State private var hoveredTaskId: Int?
    /// Which task's Notes popover is open, if any — same single-piece-of-state pattern CalendarView
    /// uses, since only one can be open at a time.
    @State private var notesEditorTaskId: Int?

    private static let laneHeight: CGFloat = 42
    private static let axisHeight: CGFloat = 56
    private static let barHeight: CGFloat = 27

    /// Only top-level tasks — a timeline meant to be taken in at a glance gets noisy fast if every
    /// nested subtask is also plotted; Microsoft Project's own Timeline is normally a hand-picked
    /// subset for the same reason. Top-level is the closest unsupervised approximation of "the key
    /// items," and reuses data already in memory with no further Helper/DTO work.
    private var items: [GanttTask] {
        tasks
            .filter { $0.outlineLevel == 1 && $0.start != nil }
            .sorted { $0.start! < $1.start! }
    }

    private var lanes: [[GanttTask]] {
        IntervalPacking.lanes(items, start: { $0.start ?? .distantPast }, end: { $0.finish ?? .distantFuture })
    }

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView(
                "No Top-Level Tasks",
                systemImage: "calendar",
                description: Text("Timeline shows each top-level task as a bar along the project's date range.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                let pixelsPerDay = ganttFitPixelsPerDay(range: range, paneWidth: geo.size.width - 48)
                let contentHeight = Self.axisHeight + CGFloat(lanes.count) * Self.laneHeight + 12

                ZStack(alignment: .topLeading) {
                    laneStripes(count: lanes.count, pixelsPerDay: pixelsPerDay)
                    monthWalls(pixelsPerDay: pixelsPerDay, height: contentHeight)
                    todayLine(pixelsPerDay: pixelsPerDay, height: contentHeight)
                    axis(pixelsPerDay: pixelsPerDay)
                    ForEach(Array(lanes.enumerated()), id: \.offset) { laneIndex, laneTasks in
                        ForEach(laneTasks) { task in
                            bar(for: task, laneIndex: laneIndex, pixelsPerDay: pixelsPerDay)
                        }
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.background)
                        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
                )
                .padding(16)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    // ---- scaffolding --------------------------------------------------------------------------------

    private func laneStripes(count: Int, pixelsPerDay: CGFloat) -> some View {
        let width = CGFloat(ganttTotalDays(range: range)) * pixelsPerDay
        return VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                (i.isMultiple(of: 2) ? Color.primary.opacity(0.025) : Color.clear)
                    .frame(height: Self.laneHeight)
            }
        }
        .frame(width: max(width, 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .offset(y: Self.axisHeight)
    }

    /// A faint vertical "wall" at every month boundary, running from a small pip at the axis baseline
    /// down through the full lane area — makes it possible to see at a glance which month a bar falls
    /// in without having to trace up to the axis label every time. Drawn for *every* month boundary,
    /// unfiltered by the crowding/today exclusions `axisTicks`' labels use — a thin line never
    /// collides the way overlapping text would, so there's no reason to drop any of them.
    private func monthWalls(pixelsPerDay: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(monthBoundaryDates(), id: \.self) { date in
                let x = xOffset(for: date, pixelsPerDay: pixelsPerDay)
                Rectangle()
                    .fill(Color.secondary.opacity(0.14))
                    .frame(width: 1, height: height - Self.axisHeight)
                    .offset(x: x, y: Self.axisHeight)
                Circle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 5, height: 5)
                    .offset(x: x - 2, y: Self.axisHeight - 2.5)
            }
        }
    }

    /// Every real month-start date strictly inside the project range (excluding the range's own
    /// start/finish, which already have their own bold endpoint treatment) — shared by `monthWalls`
    /// here and effectively mirrored (filtered for label room) by `axisTicks`' own month pass.
    private func monthBoundaryDates() -> [Date] {
        let cal = Calendar.ganttUTC
        guard let first = cal.date(from: cal.dateComponents([.year, .month], from: range.lowerBound)) else { return [] }
        var dates: [Date] = []
        var date = first
        while date <= range.upperBound {
            if date > range.lowerBound {
                dates.append(date)
            }
            guard let next = cal.date(byAdding: .month, value: 1, to: date) else { break }
            date = next
        }
        return dates
    }

    private func todayLine(pixelsPerDay: CGFloat, height: CGFloat) -> some View {
        Group {
            if range.contains(Date()) {
                let x = xOffset(for: Date(), pixelsPerDay: pixelsPerDay)
                VStack(spacing: 2) {
                    Text("Today")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.red.gradient))
                    Rectangle()
                        .fill(LinearGradient(colors: [.red.opacity(0.5), .red.opacity(0.1)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 1.5)
                }
                .offset(x: x - 14, y: Self.axisHeight - 18)
                .frame(height: height - Self.axisHeight + 18, alignment: .top)
            }
        }
    }

    /// The project start/finish alone used to be the *only* date information shown along the whole
    /// axis — fine for a short project, but a span of many months or years left a long bare stretch
    /// with nothing to orient by in between. This adds lighter month (or, for a long enough span,
    /// year) tick marks between the two bold endpoints, same "finer unit, coarser fallback" idea
    /// TimelineCanvas's own header already uses for the real Gantt view, just simplified for a plain
    /// SwiftUI layout instead of a Canvas.
    private func axis(pixelsPerDay: CGFloat) -> some View {
        let width = CGFloat(ganttTotalDays(range: range)) * pixelsPerDay
        let ticks = axisTicks(pixelsPerDay: pixelsPerDay, totalWidth: width)

        let endpoints = HStack {
            Label(Self.dateText(range.lowerBound), systemImage: "calendar")
            Spacer()
            Label(Self.dateText(range.upperBound), systemImage: "flag.checkered")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)

        let tickMarks = ZStack(alignment: .topLeading) {
            ForEach(ticks) { tick in
                Text(tick.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .fixedSize()
                    .offset(x: xOffset(for: tick.date, pixelsPerDay: pixelsPerDay) + 3, y: 0)
            }
        }
        .frame(height: 12, alignment: .topLeading)

        // A finer tier under the month/year ticks — only when there's actually room for a 1-2 digit
        // week number without the ticks crowding into each other (see weekTicks' own spacing guard);
        // silently empty otherwise, same "don't draw what can't be read" rule the month→year fallback
        // above already follows.
        let weekTickMarks = ZStack(alignment: .topLeading) {
            ForEach(weekTicks(pixelsPerDay: pixelsPerDay, totalWidth: width)) { tick in
                VStack(spacing: 1) {
                    Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1, height: 4)
                    Text("\(tick.weekOfYear)")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .fixedSize()
                .offset(x: xOffset(for: tick.date, pixelsPerDay: pixelsPerDay) - 4, y: 0)
            }
        }
        .frame(height: 14, alignment: .topLeading)

        let baseline = LinearGradient(
            colors: [Color.secondary.opacity(0.05), Color.secondary.opacity(0.4), Color.secondary.opacity(0.05)],
            startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)

        return VStack(alignment: .leading, spacing: 3) {
            endpoints
            tickMarks
            weekTickMarks
            baseline
        }
        .frame(width: max(width, 1), height: Self.axisHeight, alignment: .bottom)
    }

    private struct AxisTick: Identifiable {
        let date: Date
        let label: String
        var id: Date { date }
    }

    private struct WeekTick: Identifiable {
        let date: Date
        let weekOfYear: Int
        var id: Date { date }
    }

    /// Month-boundary ticks, unless the project spans long enough that month labels would crowd each
    /// other (judged by the average spacing a full month-tick pass would produce), in which case this
    /// falls back to year-boundary ticks instead. Either way, ticks within `edgeMargin` of either end
    /// are dropped so they never collide with the bold start/finish labels there.
    private func axisTicks(pixelsPerDay: CGFloat, totalWidth: CGFloat) -> [AxisTick] {
        let cal = Calendar.ganttUTC
        let edgeMargin: CGFloat = 50

        func ticks(component: Calendar.Component, startingFrom comps: Set<Calendar.Component>, label: (Date) -> String) -> [AxisTick] {
            guard let first = cal.date(from: cal.dateComponents(comps, from: range.lowerBound)) else { return [] }
            var result: [AxisTick] = []
            var date = first
            while date <= range.upperBound {
                if date > range.lowerBound {
                    result.append(AxisTick(date: date, label: label(date)))
                }
                guard let next = cal.date(byAdding: component, value: 1, to: date) else { break }
                date = next
            }
            return result
        }

        let monthTicks = ticks(component: .month, startingFrom: [.year, .month]) { Self.monthYearFormatter.string(from: $0) }
        let avgMonthSpacing = totalWidth / CGFloat(monthTicks.count + 1)
        let chosen = avgMonthSpacing >= 44
            ? monthTicks
            : ticks(component: .year, startingFrom: [.year]) { Self.yearFormatter.string(from: $0) }

        // Also drop a tick that would land right under the "Today" badge, when today falls inside
        // the project range — same collision this edge-margin exclusion already prevents against the
        // start/finish labels, just against a third label that can land anywhere in between.
        let todayX = range.contains(Date()) ? xOffset(for: Date(), pixelsPerDay: pixelsPerDay) : nil

        return chosen.filter { tick in
            let x = xOffset(for: tick.date, pixelsPerDay: pixelsPerDay)
            guard x > edgeMargin, x < totalWidth - edgeMargin else { return false }
            if let todayX, abs(x - todayX) < edgeMargin { return false }
            return true
        }
    }

    /// One tick per week boundary (the calendar's own `firstWeekday`, same convention Month mode's
    /// week grid already uses), labeled with `weekOfYear` (1–52, occasionally 53, same as any
    /// standard "week number" — not a custom scheme). Only drawn once there's genuinely room for a
    /// short tick plus a 1–2 digit number without consecutive weeks crowding into each other.
    private func weekTicks(pixelsPerDay: CGFloat, totalWidth: CGFloat) -> [WeekTick] {
        let cal = Calendar.ganttUTC
        let weekSpacing = 7 * pixelsPerDay
        guard weekSpacing >= 16 else { return [] }

        var date = cal.startOfDay(for: range.lowerBound)
        let weekday = cal.component(.weekday, from: date)
        let daysToNextWeekStart = (cal.firstWeekday - weekday + 7) % 7
        if daysToNextWeekStart > 0, let aligned = cal.date(byAdding: .day, value: daysToNextWeekStart, to: date) {
            date = aligned
        }

        var ticks: [WeekTick] = []
        while date <= range.upperBound {
            if date > range.lowerBound {
                ticks.append(WeekTick(date: date, weekOfYear: cal.component(.weekOfYear, from: date)))
            }
            guard let next = cal.date(byAdding: .day, value: 7, to: date) else { break }
            date = next
        }

        let edgeMargin: CGFloat = 20
        let todayX = range.contains(Date()) ? xOffset(for: Date(), pixelsPerDay: pixelsPerDay) : nil
        return ticks.filter { tick in
            let x = xOffset(for: tick.date, pixelsPerDay: pixelsPerDay)
            guard x > edgeMargin, x < totalWidth - edgeMargin else { return false }
            if let todayX, abs(x - todayX) < edgeMargin { return false }
            return true
        }
    }

    // ---- bars -----------------------------------------------------------------------------------

    private func bar(for task: GanttTask, laneIndex: Int, pixelsPerDay: CGFloat) -> some View {
        let x = xOffset(for: task.start ?? range.lowerBound, pixelsPerDay: pixelsPerDay)
        let y = Self.axisHeight + CGFloat(laneIndex) * Self.laneHeight + (Self.laneHeight - Self.barHeight) / 2
        let isSelected = task.id == selectedTaskId
        let isHovered = task.id == hoveredTaskId
        let tint: Color = (showCriticalPath && task.isCritical) ? .red : .accentColor

        return Group {
            if task.isMilestone {
                milestone(task: task, tint: tint, isSelected: isSelected, isHovered: isHovered)
                    .offset(x: x - 7, y: y + (Self.barHeight - 14) / 2)
            } else {
                let width = max(20, CGFloat(task.durationDays) * pixelsPerDay)
                let label = Text(task.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 0.5)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 0.75))
                    .overlay(label, alignment: .leading)
                    .frame(width: width, height: Self.barHeight)
                let outlined = shape
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.accentColor, lineWidth: isSelected ? 2.5 : 0))
                    .shadow(color: tint.opacity(isSelected ? 0.5 : isHovered ? 0.35 : 0.2), radius: isSelected ? 6 : isHovered ? 4 : 2, x: 0, y: 2)
                    .scaleEffect(isHovered && !isSelected ? 1.03 : 1, anchor: .leading)
                outlined
                    .offset(x: x, y: y)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onJumpToWBS(task.id) }
                    .selectImmediatelyOnClick { onSelect(task.id) }
                    .onHover { hoveredTaskId = $0 ? task.id : (hoveredTaskId == task.id ? nil : hoveredTaskId) }
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
                    .contextMenu { contextMenuItems(for: task) }
                    .popover(isPresented: notesBinding(for: task.id)) { notesEditor(for: task) }
                    .help(task.name)
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(for task: GanttTask) -> some View {
        Button("Jump to WBS") { onJumpToWBS(task.id) }
        Button("Notes…") { notesEditorTaskId = task.id }
        Divider()
        Button("Delete Task", role: .destructive) { onDeleteRequest(task.id) }
    }

    private func notesBinding(for taskId: Int) -> Binding<Bool> {
        Binding(
            get: { notesEditorTaskId == taskId },
            set: { if !$0 { notesEditorTaskId = nil } })
    }

    private func notesEditor(for task: GanttTask) -> some View {
        NotesEditor(
            initialNotes: task.notes,
            onApply: { onEditNotes(task.id, $0); notesEditorTaskId = nil },
            onCancel: { notesEditorTaskId = nil })
    }

    private func milestone(task: GanttTask, tint: Color, isSelected: Bool, isHovered: Bool) -> some View {
        let fill = LinearGradient(colors: [tint, tint.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        let selectionRingWidth: CGFloat = isSelected ? 2 : 0
        let selectionRing = MilestoneDiamond().stroke(Color.accentColor, lineWidth: selectionRingWidth).scaleEffect(1.6)
        let filled = MilestoneDiamond().fill(fill)
        let outlined = filled.overlay(MilestoneDiamond().stroke(Color.white.opacity(0.3), lineWidth: 0.75))
        let base = outlined.frame(width: 14, height: 14)
        let ringed = base.overlay(selectionRing)
        let shadowColor = tint.opacity(isSelected ? 0.6 : 0.3)
        let shadowRadius: CGFloat = isSelected ? 5 : 2
        let shadowed = ringed.shadow(color: shadowColor, radius: shadowRadius, x: 0, y: 1)
        let diamond = shadowed.scaleEffect(isHovered ? 1.15 : 1)
        let label = Text(task.name)
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(1).fixedSize()
            .offset(x: 18)
        let withLabel = diamond.overlay(alignment: .trailing) { label }
        return withLabel
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onJumpToWBS(task.id) }
            .selectImmediatelyOnClick { onSelect(task.id) }
            .onHover { hoveredTaskId = $0 ? task.id : (hoveredTaskId == task.id ? nil : hoveredTaskId) }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
            .contextMenu { contextMenuItems(for: task) }
            .popover(isPresented: notesBinding(for: task.id)) { notesEditor(for: task) }
            .help(task.name)
    }

    private func xOffset(for date: Date, pixelsPerDay: CGFloat) -> CGFloat {
        let days = Calendar.ganttUTC.dateComponents([.day], from: range.lowerBound, to: date).day ?? 0
        return CGFloat(days) * pixelsPerDay
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private static let monthYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// A simple diamond — Microsoft Project's own milestone marker shape, used here on the Timeline
/// (TimelineCanvas draws milestones differently, directly in its Canvas, so this is kept local
/// rather than shared).
private struct MilestoneDiamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}
