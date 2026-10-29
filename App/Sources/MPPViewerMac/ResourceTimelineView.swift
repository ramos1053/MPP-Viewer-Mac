import SwiftUI

/// Calendar view's "Team" mode: a per-resource weekly scheduling timeline (rows = resources, columns
/// = days, colored bars = task assignments) — a second way to look at the same schedule Month mode
/// shows, switched via CalendarView's own mode toggle, not a separate top-level view. Modeled on a
/// resource-planning tool screenshot the user shared: avatar rows down the left, a multi-week day
/// grid across the top, gradient allocation bars.
///
/// Week-paged (3 weeks at a time, prev/next/Today, same navigator language as Month mode) rather than
/// a free-scrolling canvas — simpler than Gantt's synced-dual-NSScrollView machinery (GanttChartPane/
/// SyncedScrollHost), and it's the same interaction model the reference screenshot itself uses.
/// Needs only a single native `ScrollView(.vertical)` since nothing scrolls horizontally.
///
/// No ToolbarContentDivider of its own — see ResourceSheetView's doc comment for why.
struct ResourceTimelineView: View {
    let tasks: [GanttTask]
    let resources: [ResourceDto]
    let showCriticalPath: Bool
    let selectedTaskId: Int?
    let onSelect: (Int) -> Void
    let highlightColor: Color
    let onJumpToWBS: (Int) -> Void
    let onDeleteRequest: (Int) -> Void
    let onEditNotes: (Int, String) -> Void
    let onEditAssignments: (Int, [TaskAssignment]) -> Void

    @State private var weekStart = ResourceTimelineLayout.mondayAligned(Date())
    @State private var notesEditorTaskId: Int?
    @State private var assignmentEditorTaskId: Int?
    @State private var hoveredBarId: String?

    private static let weekCount = 3
    /// Floor on the responsive day-column width (see `body`'s GeometryReader) — below this, bar
    /// labels and day numbers stop being legible, so the grid stops shrinking and a horizontal
    /// scrollbar (the GeometryReader's parent ScrollView) takes over instead of squeezing further.
    private static let minDayColumnWidth: CGFloat = 56
    private static let nameColumnWidth: CGFloat = 190
    /// dayHeaderCell's own natural height (6pt vertical padding + ~11pt weekday label + 2pt spacing +
    /// 22pt day-number circle + 6pt padding), given explicitly to the header's ScrollView below rather
    /// than left to infer — a plain `ScrollView` reports an unbounded/flexible ideal height to its
    /// parent VStack regardless of how short its actual content is, so without this the VStack split
    /// the available height between the header's ScrollView and the row list's ScrollView as if both
    /// wanted to grow, leaving the header floating with a large dead gap above it instead of sitting
    /// flush under the title.
    private static let dayHeaderRowHeight: CGFloat = 48
    private static let rowHeaderHeight: CGFloat = 44
    private static let barHeight: CGFloat = 24
    private static let barGap: CGFloat = 4
    private static let maxVisibleLanes = 3
    private static let rowPadding: CGFloat = 8

    private var sortedResources: [ResourceDto] { resources.sorted { $0.name < $1.name } }
    private var visibleDays: [Date] { ResourceTimelineLayout.days(from: weekStart, count: Self.weekCount * 7) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if resources.isEmpty {
                ContentUnavailableView(
                    "No Resources",
                    systemImage: "person.2",
                    description: Text("Add resources in the Resources view, then assign them to tasks to see them here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // The grid shrinks each day column to fit the available width down to
                // minDayColumnWidth; narrower than that, this GeometryReader's own width stops
                // shrinking further and the ScrollView around it scrolls horizontally instead —
                // same "fit, then scroll" behavior Month mode doesn't need (its 7-column grid always
                // fits by construction) but this one does, since weekCount is fixed at 3.
                GeometryReader { geo in
                    let dayColumnWidth = max(Self.minDayColumnWidth, (geo.size.width - Self.nameColumnWidth) / CGFloat(visibleDays.count))
                    let gridWidth = CGFloat(visibleDays.count) * dayColumnWidth
                    // Two separate ScrollViews, not one outer horizontal one wrapping everything — the
                    // header gets its own height-capped one (see dayHeaderRowHeight) and the row list
                    // gets its own two-axis one, so each lays out independently instead of a VStack
                    // trying to split space between two same-looking flexible children. Trade-off: the
                    // header only re-syncs its horizontal scroll position with the rows on appear, not
                    // continuously while dragging — acceptable since this only matters in the rare
                    // narrow-window fallback where dayColumnWidth hits minDayColumnWidth (the common
                    // case has nothing to scroll at all); same "header doesn't stay stuck while
                    // scrolling" simplification Gantt's own date header already accepts.
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            dayHeader(dayColumnWidth: dayColumnWidth)
                                .frame(minWidth: geo.size.width, alignment: .leading)
                        }
                        .frame(height: Self.dayHeaderRowHeight)
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                        ScrollView([.horizontal, .vertical]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(sortedResources) { resource in
                                    resourceRow(resource, dayColumnWidth: dayColumnWidth, gridWidth: gridWidth)
                                    Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                                }
                            }
                            .frame(minWidth: geo.size.width, alignment: .leading)
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
        .onAppear { navigateToSelection() }
    }

    private func navigateToSelection() {
        guard let selectedTaskId, let task = tasks.first(where: { $0.id == selectedTaskId }), let start = task.start else { return }
        let visibleRange = visibleDays.first!...Calendar.ganttUTC.date(byAdding: .day, value: 1, to: visibleDays.last!)!
        if !visibleRange.contains(start) {
            weekStart = ResourceTimelineLayout.mondayAligned(start)
        }
    }

    // ---- header ---------------------------------------------------------------------------------

    private var header: some View {
        let navigator = HStack(spacing: 0) {
            Button { weekStart = ResourceTimelineLayout.addingWeeks(-1, to: weekStart) } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 22)
            }
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 14)
            Button { weekStart = ResourceTimelineLayout.addingWeeks(1, to: weekStart) } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 22)
            }
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

        return HStack(spacing: 10) {
            Text("\(Self.rangeFormatter.string(from: visibleDays.first ?? weekStart)) – \(Self.rangeFormatter.string(from: visibleDays.last ?? weekStart))")
            Spacer()
            Button("Today") { weekStart = ResourceTimelineLayout.mondayAligned(Date()) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            navigator
        }
        .font(.system(size: 19, weight: .bold, design: .rounded))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func dayHeader(dayColumnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.nameColumnWidth)
            ForEach(visibleDays, id: \.self) { day in
                dayHeaderCell(day).frame(width: dayColumnWidth)
            }
        }
    }

    private func dayHeaderCell(_ day: Date) -> some View {
        let isToday = Calendar.ganttUTC.isDate(day, inSameDayAs: Date())
        let weekday = Calendar.ganttUTC.component(.weekday, from: day)
        let isWeekend = weekday == 1 || weekday == 7
        let isWeekStart = Calendar.ganttUTC.component(.weekday, from: day) == 2 // Monday

        return VStack(spacing: 2) {
            Text(Self.weekdayFormatter.string(from: day).uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Text(Self.dayFormatter.string(from: day))
                .font(.system(size: 13, weight: isToday ? .bold : .medium, design: .rounded))
                .foregroundStyle(isToday ? .white : .primary)
                .frame(width: 22, height: 22)
                .background(
                    isToday
                        ? AnyView(Circle().fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                            .shadow(color: .accentColor.opacity(0.5), radius: 3, x: 0, y: 1))
                        : AnyView(Color.clear))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(isWeekend ? Color.primary.opacity(0.03) : Color.clear)
        .overlay(alignment: .leading) {
            if isWeekStart {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
            }
        }
    }

    // ---- rows -----------------------------------------------------------------------------------

    private func resourceRow(_ resource: ResourceDto, dayColumnWidth: CGFloat, gridWidth: CGFloat) -> some View {
        let bars = ResourceTimelineLayout.bars(for: resource.uniqueId, in: tasks)
            .filter { bar in
                guard let start = bar.task.start, let finish = bar.task.finish else { return false }
                let windowEnd = Calendar.ganttUTC.date(byAdding: .day, value: 1, to: visibleDays.last!) ?? finish
                return start < windowEnd && finish >= visibleDays.first!
            }
            .sorted { ($0.task.start ?? .distantPast) < ($1.task.start ?? .distantPast) }
        let lanes = IntervalPacking.lanes(bars, start: { $0.task.start ?? .distantPast }, end: { $0.task.finish ?? .distantFuture })
        let visibleLanes = Array(lanes.prefix(Self.maxVisibleLanes))
        let hiddenCount = bars.count - visibleLanes.flatMap { $0 }.count
        let rowHeight = Self.rowHeaderHeight + CGFloat(max(1, visibleLanes.count)) * (Self.barHeight + Self.barGap) + Self.rowPadding

        return HStack(spacing: 0) {
            resourceNameCell(resource).frame(width: Self.nameColumnWidth, height: rowHeight)
            ZStack(alignment: .topLeading) {
                dayGridBackground(for: resource, dayColumnWidth: dayColumnWidth)
                ForEach(Array(visibleLanes.enumerated()), id: \.offset) { laneIndex, laneBars in
                    ForEach(laneBars) { bar in
                        barView(bar, resource: resource, laneIndex: laneIndex, dayColumnWidth: dayColumnWidth)
                    }
                }
                if hiddenCount > 0 {
                    Text("+\(hiddenCount) more")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .offset(x: 4, y: Self.rowHeaderHeight + CGFloat(Self.maxVisibleLanes) * (Self.barHeight + Self.barGap))
                }
            }
            .frame(width: gridWidth, height: rowHeight, alignment: .topLeading)
        }
    }

    private func resourceNameCell(_ resource: ResourceDto) -> some View {
        HStack(spacing: 8) {
            avatar(for: resource)
            VStack(alignment: .leading, spacing: 1) {
                Text(resource.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if !resource.group.isEmpty {
                    Text(resource.group).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func dayGridBackground(for resource: ResourceDto, dayColumnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(visibleDays, id: \.self) { day in
                dayColumnBackground(day, resource: resource).frame(width: dayColumnWidth)
            }
        }
    }

    private func dayColumnBackground(_ day: Date, resource: ResourceDto) -> some View {
        let weekday = Calendar.ganttUTC.component(.weekday, from: day)
        let isWeekend = weekday == 1 || weekday == 7
        let isToday = Calendar.ganttUTC.isDate(day, inSameDayAs: Date())
        let isWeekStart = weekday == 2
        let allocated = ResourceTimelineLayout.allocatedUnits(for: resource.uniqueId, on: day, in: tasks)
        let overAllocated = allocated > resource.maxUnits + 0.01

        return VStack(spacing: 0) {
            Capsule()
                .fill(overAllocated ? Color.orange : Color.clear)
                .frame(height: overAllocated ? 3 : 0)
                .padding(.horizontal, 3)
                .padding(.top, 2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isToday ? Color.accentColor.opacity(0.05) : (isWeekend ? Color.primary.opacity(0.025) : Color.clear))
        .overlay(Rectangle().stroke(Color.primary.opacity(0.05), lineWidth: 0.5))
        .overlay(alignment: .leading) {
            if isWeekStart {
                Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
            }
        }
    }

    private func barView(_ bar: ResourceTimelineLayout.Bar, resource: ResourceDto, laneIndex: Int, dayColumnWidth: CGFloat) -> some View {
        let task = bar.task
        let windowStart = visibleDays.first!
        let start = task.start ?? windowStart
        let finish = task.finish ?? windowStart
        let barStartDay = max(0, CalendarLayout.daysBetween(windowStart, start))
        let barEndDayExclusive = min(visibleDays.count, CalendarLayout.daysBetween(windowStart, finish) + 1)
        guard barEndDayExclusive > barStartDay else { return AnyView(EmptyView()) }

        let x = CGFloat(barStartDay) * dayColumnWidth + 2
        let width = CGFloat(barEndDayExclusive - barStartDay) * dayColumnWidth - 4
        let y = Self.rowHeaderHeight + CGFloat(laneIndex) * (Self.barHeight + Self.barGap)
        let isSelected = task.id == selectedTaskId
        let isHovered = bar.id == hoveredBarId
        let color: Color = (showCriticalPath && task.isCritical) ? .red : Self.sectionColor(for: task)
        let unitsSuffix = abs(bar.assignment.units - 100) > 0.001 ? " (\(Self.trimmed(bar.assignment.units))%)" : ""

        let label = Text(task.name + unitsSuffix)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(width: width, height: Self.barHeight, alignment: .leading)
            .foregroundStyle(.white)

        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let fill = LinearGradient(colors: [color.opacity(0.95), color.opacity(0.72)], startPoint: .top, endPoint: .bottom)
        let filled = label.background(fill, in: shape)
        let selectionWidth: CGFloat = isSelected ? 2 : 0
        let bordered = filled.overlay(shape.stroke(highlightColor, lineWidth: selectionWidth))
        let shadowOpacity: Double = isSelected ? 0.5 : (isHovered ? 0.3 : 0)
        let shadowed = bordered.shadow(color: color.opacity(shadowOpacity), radius: isSelected ? 4 : 3, x: 0, y: 1)
        let scale: CGFloat = (isHovered && !isSelected) ? 1.02 : 1

        let notesBinding = Binding(
            get: { notesEditorTaskId == task.id },
            set: { if !$0 { notesEditorTaskId = nil } })
        let assignmentBinding = Binding(
            get: { assignmentEditorTaskId == task.id },
            set: { if !$0 { assignmentEditorTaskId = nil } })

        return AnyView(
            shadowed
                .scaleEffect(scale, anchor: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onJumpToWBS(task.id) }
                .selectImmediatelyOnClick { onSelect(task.id) }
                .onHover { hovering in hoveredBarId = hovering ? bar.id : (hoveredBarId == bar.id ? nil : hoveredBarId) }
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
                .contextMenu {
                    Button("Jump to WBS") { onJumpToWBS(task.id) }
                    Button("Notes…") { notesEditorTaskId = task.id }
                    Button("Edit Assignment…") { assignmentEditorTaskId = task.id }
                    Button("Remove from \(resource.name)") {
                        onEditAssignments(task.id, task.assignments.filter { $0.resourceId != resource.uniqueId })
                    }
                    Divider()
                    Button("Delete Task", role: .destructive) { onDeleteRequest(task.id) }
                }
                .popover(isPresented: notesBinding) {
                    NotesEditor(
                        initialNotes: task.notes,
                        onApply: { onEditNotes(task.id, $0); notesEditorTaskId = nil },
                        onCancel: { notesEditorTaskId = nil })
                }
                .popover(isPresented: assignmentBinding) {
                    AssignmentEditor(
                        initialAssignments: task.assignments, resources: resources,
                        onApply: { onEditAssignments(task.id, $0); assignmentEditorTaskId = nil },
                        onCancel: { assignmentEditorTaskId = nil })
                }
                .help("\(task.name) — \(resource.name), \(Self.trimmed(bar.assignment.units))%")
                .offset(x: x, y: y)
        )
    }

    // ---- styling ----------------------------------------------------------------------------------

    private func avatar(for resource: ResourceDto) -> some View {
        let color = Self.avatarColor(for: resource.name)
        let gradient = LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        let initialsText = Text(initials(for: resource)).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white)
        return Circle().fill(gradient).frame(width: 24, height: 24)
            .overlay(initialsText)
            .shadow(color: color.opacity(0.35), radius: 1.5, x: 0, y: 1)
    }

    private func initials(for resource: ResourceDto) -> String {
        if !resource.initials.isEmpty { return String(resource.initials.prefix(2)).uppercased() }
        let parts = resource.name.split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first).map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    private static let avatarPalette: [Color] = [.blue, .purple, .teal, .indigo, .pink, .brown, .cyan, .mint, .orange]

    private static func avatarColor(for name: String) -> Color {
        guard !name.isEmpty else { return .accentColor }
        var hasher = Hasher()
        hasher.combine(name)
        return avatarPalette[abs(hasher.finalize()) % avatarPalette.count]
    }

    /// Same WBS-top-level-section color convention as Month mode's bars (see CalendarView.sectionColor)
    /// — a task reads the same color whether you're looking at it in Month or Team mode.
    private static let sectionPalette: [Color] = [.blue, .purple, .teal, .indigo, .pink, .brown, .cyan, .mint]

    private static func sectionColor(for task: GanttTask) -> Color {
        let section = task.wbs.split(separator: ".").first.map(String.init) ?? task.wbs
        guard !section.isEmpty else { return .accentColor }
        var hasher = Hasher()
        hasher.combine(section)
        return sectionPalette[abs(hasher.finalize()) % sectionPalette.count]
    }

    private static func trimmed(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let rangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
