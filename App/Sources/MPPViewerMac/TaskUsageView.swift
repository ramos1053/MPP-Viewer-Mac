import SwiftUI

/// A dedicated Task Usage view: rows per task (with a resource sub-row per assignment), columns per
/// day, cells showing that task/resource's timephased work for the day — the task-centric counterpart
/// to Calendar's Team mode (which is resource-centric: rows per resource, bars per task). Same
/// week-paged navigation language as Team mode (ResourceTimelineView) for consistency, but a plain
/// numeric grid rather than colored bars — a spreadsheet, which is what MS Project's own Task Usage
/// view actually is, not another timeline.
///
/// No ToolbarContentDivider of its own — see ResourceSheetView's doc comment for why.
struct TaskUsageView: View {
    let tasks: [GanttTask]
    let resources: [ResourceDto]
    let showCriticalPath: Bool
    let selectedTaskId: Int?
    let onSelect: (Int) -> Void
    let onJumpToWBS: (Int) -> Void
    /// Same user-configurable selection color Month/Team mode already honor (see Settings) —
    /// Task Usage is a third mode of the same Calendar view, so its selected row reads consistently
    /// with the other two rather than a hardcoded accent tint.
    let highlightColor: Color

    @State private var weekStart = ResourceTimelineLayout.mondayAligned(Date())

    private static let weekCount = 3
    private static let minDayColumnWidth: CGFloat = 52
    private static let nameColumnWidth: CGFloat = 230
    private static let totalColumnWidth: CGFloat = 56
    private static let dayHeaderRowHeight: CGFloat = 48
    private static let taskRowHeight: CGFloat = 30
    private static let assignmentRowHeight: CGFloat = 22

    /// Real work only — same exclusion Network uses, and for the same reason: a summary task's
    /// "work" is just its children's rolled up, nothing of its own to show a timephased breakdown
    /// for.
    private var usageTasks: [GanttTask] { tasks.filter { !$0.isSummary } }
    private var resourcesById: [Int: ResourceDto] { Dictionary(uniqueKeysWithValues: resources.map { ($0.uniqueId, $0) }) }
    private var visibleDays: [Date] { ResourceTimelineLayout.days(from: weekStart, count: Self.weekCount * 7) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if usageTasks.isEmpty {
                ContentUnavailableView(
                    "No Tasks",
                    systemImage: "calendar.day.timeline.left",
                    description: Text("Task Usage shows each task's timephased work, day by day.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    let fixedWidth = Self.nameColumnWidth + Self.totalColumnWidth
                    let dayColumnWidth = max(Self.minDayColumnWidth, (geo.size.width - fixedWidth) / CGFloat(visibleDays.count))
                    let gridWidth = CGFloat(visibleDays.count) * dayColumnWidth

                    // Same two-ScrollView split ResourceTimelineView uses, for the same reason: a
                    // plain ScrollView reports an unbounded ideal height to its parent VStack, so
                    // one shared ScrollView would fight the row list for vertical space instead of
                    // the header sitting flush at its own natural height.
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            dayHeader(dayColumnWidth: dayColumnWidth)
                                .frame(minWidth: geo.size.width, alignment: .leading)
                        }
                        .frame(height: Self.dayHeaderRowHeight)
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                        ScrollView([.horizontal, .vertical]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(usageTasks) { task in
                                    taskRow(task, dayColumnWidth: dayColumnWidth, gridWidth: gridWidth)
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
            Text("Work")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: Self.totalColumnWidth)
            ForEach(visibleDays, id: \.self) { day in
                dayHeaderCell(day).frame(width: dayColumnWidth)
            }
        }
    }

    private func dayHeaderCell(_ day: Date) -> some View {
        let isToday = Calendar.ganttUTC.isDate(day, inSameDayAs: Date())
        let weekday = Calendar.ganttUTC.component(.weekday, from: day)
        let isWeekend = weekday == 1 || weekday == 7
        let isWeekStart = weekday == 2

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

    private func taskRow(_ task: GanttTask, dayColumnWidth: CGFloat, gridWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                taskNameCell(task).frame(width: Self.nameColumnWidth, height: Self.taskRowHeight)
                totalCell(TaskUsageLayout.totalWork(task: task), bold: true).frame(width: Self.totalColumnWidth, height: Self.taskRowHeight)
                dayGrid(dayColumnWidth: dayColumnWidth) { day in
                    TaskUsageLayout.totalDailyHours(task: task, on: day)
                }
                .frame(width: gridWidth, height: Self.taskRowHeight)
            }
            .background(
                selectedTaskId == task.id ? highlightColor.opacity(0.18)
                : ((showCriticalPath && task.isCritical) ? Color.red.opacity(0.08) : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onJumpToWBS(task.id) }
            .selectImmediatelyOnClick { onSelect(task.id) }
            .contextMenu {
                Button("Jump to WBS") { onJumpToWBS(task.id) }
            }

            ForEach(task.assignments, id: \.resourceId) { assignment in
                if let resource = resourcesById[assignment.resourceId] {
                    HStack(spacing: 0) {
                        assignmentNameCell(resource, units: assignment.units).frame(width: Self.nameColumnWidth, height: Self.assignmentRowHeight)
                        totalCell(task.durationDays * 8 * (assignment.units / 100), bold: false)
                            .frame(width: Self.totalColumnWidth, height: Self.assignmentRowHeight)
                        dayGrid(dayColumnWidth: dayColumnWidth) { day in
                            TaskUsageLayout.dailyHours(assignment: assignment, task: task, on: day)
                        }
                        .frame(width: gridWidth, height: Self.assignmentRowHeight)
                    }
                }
            }
        }
    }

    private func taskNameCell(_ task: GanttTask) -> some View {
        HStack(spacing: 6) {
            Text(task.wbs)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            Text(task.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func assignmentNameCell(_ resource: ResourceDto, units: Double) -> some View {
        let unitsSuffix = abs(units - 100) > 0.001 ? " (\(Self.trimmed(units))%)" : ""
        return HStack(spacing: 6) {
            Circle().fill(Self.avatarColor(for: resource.name)).frame(width: 6, height: 6)
            Text(resource.name + unitsSuffix)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, 36)
        .padding(.trailing, 10)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func totalCell(_ hours: Double, bold: Bool) -> some View {
        Text(hours > 0 ? Self.hoursFormatter(hours) : "")
            .font(.system(size: bold ? 11 : 10, weight: bold ? .semibold : .regular, design: .rounded))
            .foregroundStyle(bold ? .primary : .secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dayGrid(dayColumnWidth: CGFloat, hours: @escaping (Date) -> Double) -> some View {
        HStack(spacing: 0) {
            ForEach(visibleDays, id: \.self) { day in
                dayCell(hours(day), day: day).frame(width: dayColumnWidth)
            }
        }
    }

    private func dayCell(_ hours: Double, day: Date) -> some View {
        let weekday = Calendar.ganttUTC.component(.weekday, from: day)
        let isWeekend = weekday == 1 || weekday == 7
        let isToday = Calendar.ganttUTC.isDate(day, inSameDayAs: Date())
        let isWeekStart = weekday == 2
        let isOverAllocated = hours > 8.01

        return Text(hours > 0 ? Self.hoursFormatter(hours) : "")
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(isOverAllocated ? .orange : .primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isToday ? Color.accentColor.opacity(0.05) : (isWeekend ? Color.primary.opacity(0.025) : Color.clear))
            .overlay(Rectangle().stroke(Color.primary.opacity(0.05), lineWidth: 0.5))
            .overlay(alignment: .leading) {
                if isWeekStart {
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
                }
            }
    }

    // ---- styling ----------------------------------------------------------------------------------

    private static let avatarPalette: [Color] = [.blue, .purple, .teal, .indigo, .pink, .brown, .cyan, .mint, .orange]

    private static func avatarColor(for name: String) -> Color {
        guard !name.isEmpty else { return .accentColor }
        var hasher = Hasher()
        hasher.combine(name)
        return avatarPalette[abs(hasher.finalize()) % avatarPalette.count]
    }

    private static func trimmed(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func hoursFormatter(_ hours: Double) -> String {
        "\(trimmed(hours))h"
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
