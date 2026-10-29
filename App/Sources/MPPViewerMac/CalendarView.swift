import SwiftUI

/// Microsoft Project's classic "Calendar" view: a month grid (always 6 weeks, see CalendarLayout)
/// with every task drawn as a bar across the days it's scheduled, wrapping onto the next row when it
/// spans a week boundary — same as a day-planner app showing multi-day events. Distinct from
/// "Calendars" (the working-time calendar *definitions* — holidays, exceptions — which this app
/// doesn't expose, since Scheduler is calendar-day-only and doesn't use them either).
///
/// Styled as a floating card (same language as Timeline/Network): gradient bars with a hover lift and
/// a glowing selection ring, a glowing "today" marker, weekend shading, and a pill-shaped month
/// navigator — rather than the plain grid-lines-and-flat-bars first cut.
///
/// No zoom (see ViewMode.supportsZoom) — a month grid doesn't have a date-axis scale to zoom, it has
/// a month to page through, which the header below does instead.
///
/// No ToolbarContentDivider of its own — see ResourceSheetView's doc comment for why.
struct CalendarView: View {
    let tasks: [GanttTask]
    let resources: [ResourceDto]
    let showCriticalPath: Bool
    let selectedTaskId: Int?
    let onSelect: (Int) -> Void
    /// The outline color around the clicked bar — a user preference (see Settings), not hardcoded,
    /// since a plain accent-color outline didn't read as a deliberate "this is selected" signal here.
    let highlightColor: Color
    /// Double-click, or right-click → "Jump to WBS" — switches to the Gantt view with this task
    /// selected (and, via that view's own onAppear, scrolled into view).
    let onJumpToWBS: (Int) -> Void
    /// Right-click → "Delete Task" — routes through AppModel.pendingTaskAction like every other
    /// delete entry point, so it gets the same WBS-renumbering confirmation dialog, not a separate
    /// Calendar-specific one.
    let onDeleteRequest: (Int) -> Void
    /// Right-click → "Notes…" — opens the same NotesEditor popover the WBS table's Notes cell uses.
    let onEditNotes: (Int, String) -> Void
    /// Team mode's "Edit Assignment…" / "Remove from <Resource>" context menu actions.
    let onEditAssignments: (Int, [TaskAssignment]) -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case month = "Month"
        case team = "Team"
        case taskUsage = "Task Usage"
        var id: Self { self }
    }

    /// Persisted (not per-session @State) so the choice sticks across relaunches — same pattern as
    /// predecessorTypeFullNames/calendarSelectionColor.
    @AppStorage("calendarMode") private var modeRawValue = Mode.month.rawValue
    private var mode: Mode { Mode(rawValue: modeRawValue) ?? .month }

    @State private var displayedMonth = CalendarLayout.startOfDay(Date())
    /// Which task's Notes popover is open, if any — a single piece of state here (not per-bar)
    /// since only one can be open at a time; each bar's popover binding just checks "is it me."
    @State private var notesEditorTaskId: Int?
    @State private var hoveredTaskId: Int?
    /// Purely a hover-feedback affordance (empty cells aren't clickable) — makes the grid read as
    /// alive/interactive rather than a static printout, same motivation as the bar hover-lift below.
    @State private var hoveredDay: Date?

    /// Each week row only has room for a few stacked bars before it gets unreadable — any task
    /// beyond that is folded into a "+N more" count instead of shrinking bars indefinitely. A
    /// deliberate simplification, same spirit as Timeline's top-level-only scoping: this view is for
    /// seeing what's scheduled on a given day at a glance, not a complete day-by-day worklist.
    private static let maxVisibleLanesPerWeek = 3
    private static let barHeight: CGFloat = 17
    private static let barGap: CGFloat = 3
    private static let dayNumberHeight: CGFloat = 26

    /// Every task was the same uniform blue (unless critical), making it hard to tell at a glance
    /// which bars on different rows/weeks belong to the same effort. Colored by WBS top-level
    /// section instead — tasks under the same whole number (e.g. everything under "5") share a
    /// color — rather than a unique color per task, which with 70+ tasks would mostly just produce
    /// visual noise with no two adjacent bars reliably distinguishable anyway. Reds/oranges are
    /// skipped so section color never gets confused with the critical-path red or the today marker.
    private static let sectionPalette: [Color] = [.blue, .purple, .teal, .indigo, .pink, .brown, .cyan, .mint]

    private func sectionColor(for task: GanttTask) -> Color {
        let section = task.wbs.split(separator: ".").first.map(String.init) ?? task.wbs
        guard !section.isEmpty else { return .accentColor }
        var hasher = Hasher()
        hasher.combine(section)
        let index = abs(hasher.finalize()) % Self.sectionPalette.count
        return Self.sectionPalette[index]
    }

    private var weeks: [[Date]] { CalendarLayout.weeks(containing: displayedMonth) }

    var body: some View {
        VStack(spacing: 0) {
            modeToggleRow
            switch mode {
            case .month:
                monthContent
            case .team:
                ResourceTimelineView(
                    tasks: tasks, resources: resources, showCriticalPath: showCriticalPath,
                    selectedTaskId: selectedTaskId, onSelect: onSelect, highlightColor: highlightColor,
                    onJumpToWBS: onJumpToWBS, onDeleteRequest: onDeleteRequest, onEditNotes: onEditNotes,
                    onEditAssignments: onEditAssignments)
            case .taskUsage:
                TaskUsageView(
                    tasks: tasks, resources: resources, showCriticalPath: showCriticalPath,
                    selectedTaskId: selectedTaskId, onSelect: onSelect, onJumpToWBS: onJumpToWBS,
                    highlightColor: highlightColor)
            }
        }
    }

    /// A small shared strip above whichever mode's own card renders below it — deliberately outside
    /// both cards' own padding/background rather than folded into Month's `header` or Team's, so
    /// switching modes doesn't require two copies of this control to stay in sync.
    private var modeToggleRow: some View {
        HStack {
            Spacer()
            Picker("Mode", selection: $modeRawValue) {
                ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m.rawValue) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var monthContent: some View {
        VStack(spacing: 0) {
            header
            weekdayHeader
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            GeometryReader { geo in
                let cellWidth = geo.size.width / 7
                let rowHeight = geo.size.height / CGFloat(weeks.count)
                VStack(spacing: 0) {
                    ForEach(weeks.indices, id: \.self) { index in
                        weekRow(weeks[index], cellWidth: cellWidth)
                            .frame(height: rowHeight, alignment: .top)
                            // Faint zebra striping so a 6-week grid of otherwise-identical rows
                            // reads as distinct weeks at a glance, not one undifferentiated block.
                            .background(index % 2 == 1 ? Color.primary.opacity(0.018) : Color.clear)
                        if index < weeks.count - 1 {
                            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(16)
        .background(Color(nsColor: .underPageBackgroundColor))
        // "Anything selected in the WBS should be focused on when switching to any view": for
        // Calendar that means paging to the month containing it, not just leaving the grid wherever
        // it last was. Only on first appearance (switching into Calendar with an existing selection
        // from elsewhere) — not on every selection change, which also fired on a plain click already
        // inside Calendar and could yank the grid to a different month out from under the click (a
        // task whose bar is visible this month by continuing into it can still *start* in an earlier
        // month), breaking the click-then-right-click flow. Team mode's own card does the equivalent
        // itself (see ResourceTimelineView.navigateToSelection).
        .onAppear { navigateToSelection() }
    }

    private func navigateToSelection() {
        guard let selectedTaskId, let task = tasks.first(where: { $0.id == selectedTaskId }), let start = task.start else { return }
        if !CalendarLayout.isSameMonth(start, displayedMonth) {
            displayedMonth = start
        }
    }

    private var header: some View {
        let navigator = HStack(spacing: 0) {
            Button { displayedMonth = CalendarLayout.addingMonths(-1, to: displayedMonth) } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 22)
            }
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 14)
            Button { displayedMonth = CalendarLayout.addingMonths(1, to: displayedMonth) } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 22)
            }
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

        let icon = Image(systemName: "calendar")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.65)], startPoint: .top, endPoint: .bottom))

        let title = VStack(alignment: .leading, spacing: 3) {
            Text(Self.monthFormatter.string(from: displayedMonth))
                .font(.system(size: 19, weight: .bold, design: .rounded))
            Capsule()
                .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.15)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 36, height: 3)
        }

        return HStack(spacing: 10) {
            icon
            title
            Spacer()
            Button("Today") { displayedMonth = CalendarLayout.startOfDay(Date()) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            navigator
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// A soft tinted band rather than bare text floating over the grid — gives the header row a
    /// visible "shelf" to sit on, same motivation as Resource Sheet's header row background.
    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Self.weekdaySymbols, id: \.self) { symbol in
                Text(symbol.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035))
    }

    private func weekRow(_ week: [Date], cellWidth: CGFloat) -> some View {
        let weekStart = week[0]
        let weekEndExclusive = Calendar.ganttUTC.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let weekTasks = tasks
            .filter { task in
                guard let start = task.start, let finish = task.finish else { return false }
                return start < weekEndExclusive && finish >= weekStart
            }
            .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        let lanes = IntervalPacking.lanes(weekTasks, start: { $0.start ?? .distantPast }, end: { $0.finish ?? .distantFuture })
        let visibleLanes = Array(lanes.prefix(Self.maxVisibleLanesPerWeek))
        let visibleTaskIds = Set(visibleLanes.flatMap { $0 }.map(\.id))
        let hiddenCount = weekTasks.count - visibleTaskIds.count

        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(week, id: \.self) { day in
                    dayCell(day)
                        .frame(width: cellWidth)
                }
            }
            ForEach(Array(visibleLanes.enumerated()), id: \.offset) { laneIndex, laneTasks in
                ForEach(laneTasks) { task in
                    bar(for: task, weekStart: weekStart, weekEndExclusive: weekEndExclusive, cellWidth: cellWidth, laneIndex: laneIndex)
                }
            }
            if hiddenCount > 0 {
                moreChip(hiddenCount)
            }
        }
    }

    private func moreChip(_ count: Int) -> some View {
        Label("\(count) more", systemImage: "ellipsis.circle.fill")
            .font(.system(size: 9, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 4)
            .offset(y: Self.dayNumberHeight + CGFloat(Self.maxVisibleLanesPerWeek) * (Self.barHeight + Self.barGap))
    }

    private func dayCell(_ day: Date) -> some View {
        let inMonth = CalendarLayout.isSameMonth(day, displayedMonth)
        let isToday = CalendarLayout.isSameMonth(day, Date()) && Calendar.ganttUTC.isDate(day, inSameDayAs: Date())
        let isHovered = hoveredDay == day
        let weekday = Calendar.ganttUTC.component(.weekday, from: day)
        let isWeekend = weekday == 1 || weekday == 7
        let dayNumber = Calendar.ganttUTC.component(.day, from: day)

        let numberText = Text("\(dayNumber)")
            .font(.system(size: 12, weight: isToday ? .bold : .regular, design: .rounded))
            .frame(width: 22, height: 22)
        let todayFill = LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.8)], startPoint: .top, endPoint: .bottom)
        let todayBadge = Circle().fill(todayFill).shadow(color: .accentColor.opacity(0.55), radius: 3, x: 0, y: 1)
        let numberBackground: AnyView = isToday ? AnyView(todayBadge) : AnyView(Color.clear)
        let numberColor: Color = isToday ? .white : (inMonth ? .primary : .secondary.opacity(0.6))
        let styledNumber = numberText.background(numberBackground).foregroundStyle(numberColor).padding(6)

        // Today now tints the *whole* cell (a soft accent wash, not just the number badge) plus a
        // thin accent bar along the top edge — reads as "this column" at a glance while scanning the
        // grid, not just as a highlighted number easy to miss. Hover is a light neutral wash, skipped
        // for today's own cell (already has its own, stronger tint) and out-of-month cells (already
        // dimmed, and not independently useful to hover).
        let fill: Color
        if isToday {
            fill = Color.accentColor.opacity(0.07)
        } else if !inMonth {
            fill = Color.primary.opacity(0.035)
        } else if isHovered {
            fill = Color.primary.opacity(0.035)
        } else if isWeekend {
            fill = Color.primary.opacity(0.02)
        } else {
            fill = Color.clear
        }

        return VStack(alignment: .leading, spacing: 0) {
            styledNumber
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill)
        .overlay(alignment: .top) {
            if isToday {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .overlay(Rectangle().stroke(Color.primary.opacity(0.05), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onHover { hovering in hoveredDay = hovering ? day : (hoveredDay == day ? nil : hoveredDay) }
    }

    private func bar(for task: GanttTask, weekStart: Date, weekEndExclusive: Date, cellWidth: CGFloat, laneIndex: Int) -> some View {
        guard let start = task.start, let finish = task.finish else { return AnyView(EmptyView()) }
        let barStartDay = max(0, CalendarLayout.daysBetween(weekStart, start))
        let barEndDayExclusive = min(7, CalendarLayout.daysBetween(weekStart, finish) + 1)
        guard barEndDayExclusive > barStartDay else { return AnyView(EmptyView()) }

        let continuesLeft = start < weekStart
        let continuesRight = finish >= weekEndExclusive
        let x = CGFloat(barStartDay) * cellWidth + 2
        let width = CGFloat(barEndDayExclusive - barStartDay) * cellWidth - 4
        let y = Self.dayNumberHeight + CGFloat(laneIndex) * (Self.barHeight + Self.barGap)
        let isSelected = task.id == selectedTaskId
        let isHovered = task.id == hoveredTaskId
        let color: Color = (showCriticalPath && task.isCritical) ? .red : sectionColor(for: task)
        var corners: RectCorner = []
        if !continuesLeft { corners.insert(.leading) }
        if !continuesRight { corners.insert(.trailing) }

        let label = HStack(spacing: 2) {
            if task.isMilestone {
                Image(systemName: "diamond.fill").font(.system(size: 7))
            }
            Text(task.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 4)
        .frame(width: width, height: Self.barHeight, alignment: .leading)
        .foregroundStyle(.white)

        let shape = PartialRoundedRectangle(corners: corners, radius: 6)
        let fill = LinearGradient(colors: [color.opacity(0.95), color.opacity(0.72)], startPoint: .top, endPoint: .bottom)
        let filled = label.background(fill, in: shape)
        // A thin lighter wash tracing the top/leading arc of the bar's own outline — a cheap "glossy
        // pill" cue (the same trick a physical glass/plastic tab reads as lit from above) that reads
        // as noticeably less flat than a single flat gradient fill, without a second real light source.
        let gloss = shape.trim(from: 0, to: 0.5).stroke(Color.white.opacity(0.25), lineWidth: 1)
        let glossed = filled.overlay(gloss)
        let selectionWidth: CGFloat = isSelected ? 2 : 0
        let bordered = glossed.overlay(shape.stroke(highlightColor, lineWidth: selectionWidth))
        let shadowOpacity: Double = isSelected ? 0.5 : (isHovered ? 0.3 : 0)
        let shadowRadius: CGFloat = isSelected ? 4 : 3
        let shadowed = bordered.shadow(color: color.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: 1)
        let scale: CGFloat = (isHovered && !isSelected) ? 1.02 : 1
        let scaled = shadowed.scaleEffect(scale, anchor: .leading)

        let notesBinding = Binding(
            get: { notesEditorTaskId == task.id },
            set: { if !$0 { notesEditorTaskId = nil } })

        return AnyView(
            scaled
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onJumpToWBS(task.id) }
                .selectImmediatelyOnClick { onSelect(task.id) }
                .onHover { hovering in hoveredTaskId = hovering ? task.id : (hoveredTaskId == task.id ? nil : hoveredTaskId) }
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
                .contextMenu {
                    Button("Jump to WBS") { onJumpToWBS(task.id) }
                    Button("Notes…") { notesEditorTaskId = task.id }
                    Divider()
                    Button("Delete Task", role: .destructive) { onDeleteRequest(task.id) }
                }
                .popover(isPresented: notesBinding) {
                    NotesEditor(
                        initialNotes: task.notes,
                        onApply: { onEditNotes(task.id, $0); notesEditorTaskId = nil },
                        onCancel: { notesEditorTaskId = nil })
                }
                .help(task.name)
                .offset(x: x, y: y)
        )
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let weekdaySymbols: [String] = {
        var cal = Calendar.ganttUTC
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }()
}

/// Which corners get rounded — only the task's true start/end, never a week-row wrap boundary, so a
/// multi-week task visibly "continues" with a flat edge into the next row, same convention a
/// calendar app uses for multi-day events.
private struct RectCorner: OptionSet {
    let rawValue: Int
    static let leading = RectCorner(rawValue: 1 << 0)
    static let trailing = RectCorner(rawValue: 1 << 1)
}

private struct PartialRoundedRectangle: Shape {
    let corners: RectCorner
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, rect.height / 2)
        let topLeft = corners.contains(.leading) ? r : 0
        let bottomLeft = corners.contains(.leading) ? r : 0
        let topRight = corners.contains(.trailing) ? r : 0
        let bottomRight = corners.contains(.trailing) ? r : 0

        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + topRight), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - bottomLeft), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addQuadCurve(to: CGPoint(x: rect.minX + topLeft, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
