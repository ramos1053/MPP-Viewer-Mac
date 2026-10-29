import SwiftUI
import AppKit

/// The fixed-width task columns' content. This is plain (non-scrolling) content — it is hosted
/// inside a real NSScrollView by SyncedScrollHost, which is what actually provides scrolling and
/// keeps it vertically locked to the chart pane. See GanttChartPane / SyncedScrollHost.
struct TaskListPane: View, Equatable {
    let title: String
    let tasks: [GanttTask]
    let resources: [ResourceDto]
    /// Bumped by AppModel on every assignment to `tasks` — see its doc comment. Used here instead
    /// of a deep `tasks == tasks` comparison, which was real, repeated cost on every single click
    /// just to confirm a pure selection change hadn't touched the data.
    let tasksVersion: Int
    let selectedTaskId: Int?
    let onSelect: (Int) -> Void
    let onEditName: (Int, String) -> Void
    let onEditPercent: (Int, Double) -> Void
    let onEditDuration: (Int, Double) -> Void
    let onEditDateRange: (Int, Date, Date) -> Void
    let onEditPredecessors: (Int, [GanttLink]) -> Void
    let onEditAssignments: (Int, [TaskAssignment]) -> Void
    let onEditNotes: (Int, String) -> Void
    let onAddTaskBefore: (Int) -> Void
    let onAddTaskAfter: (Int) -> Void
    let onDeleteTask: (Int) -> Void
    let onJumpToTask: (Int) -> Void
    let showCriticalPath: Bool

    /// Sum of every column's fixed width plus its horizontal padding (9 columns × 8pt).
    static let naturalWidth: CGFloat = 44 + 220 + 60 + 80 + 80 + 56 + 80 + 140 + 160 + 9 * 8

    // Ignores closures (not Equatable) — lets SyncedScrollHost skip rebuilding this 70+ row view on
    // every pixel of an unrelated divider drag, which is what was causing the jank.
    nonisolated static func == (lhs: TaskListPane, rhs: TaskListPane) -> Bool {
        lhs.title == rhs.title && lhs.tasksVersion == rhs.tasksVersion && lhs.selectedTaskId == rhs.selectedTaskId
            && lhs.showCriticalPath == rhs.showCriticalPath
    }

    var body: some View {
        let wbsById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.wbs) })
        let wbsToId = Self.wbsToId(for: tasks)
        VStack(spacing: 0) {
            headerRow
            ForEach(tasks) { task in
                row(for: task, wbsById: wbsById, wbsToId: wbsToId)
                    .equatable()
            }
        }
        .frame(width: Self.naturalWidth, alignment: .leading)
    }

    private func row(for task: GanttTask, wbsById: [Int: String], wbsToId: [String: Int]) -> TaskListRow {
        let taskId = task.id
        let onEditNameForTask: (String) -> Void = { onEditName(taskId, $0) }
        let onEditPercentForTask: (Double) -> Void = { onEditPercent(taskId, $0) }
        let onEditDurationForTask: (Double) -> Void = { onEditDuration(taskId, $0) }
        let onEditDateRangeForTask: (Date, Date) -> Void = { onEditDateRange(taskId, $0, $1) }
        let onEditPredecessorsForTask: ([GanttLink]) -> Void = { onEditPredecessors(taskId, $0) }
        let onEditAssignmentsForTask: ([TaskAssignment]) -> Void = { onEditAssignments(taskId, $0) }
        let onEditNotesForTask: (String) -> Void = { onEditNotes(taskId, $0) }
        let onSelectForTask: () -> Void = { onSelect(taskId) }
        let onAddTaskBeforeForTask: () -> Void = { onAddTaskBefore(taskId) }
        let onAddTaskAfterForTask: () -> Void = { onAddTaskAfter(taskId) }
        let onDeleteTaskForTask: () -> Void = { onDeleteTask(taskId) }
        let allTasks = tasks
        let wouldCreateCycleForTask: (Int) -> Bool = { predecessorId in
            Scheduler.wouldCreateCycle(addingPredecessor: predecessorId, to: taskId, in: allTasks)
        }
        return TaskListRow(
            task: task, tasksVersion: tasksVersion, isSelected: taskId == selectedTaskId,
            onSelect: onSelectForTask,
            onEditName: onEditNameForTask,
            onEditPercent: onEditPercentForTask,
            onEditDuration: onEditDurationForTask,
            onEditDateRange: onEditDateRangeForTask,
            onEditPredecessors: onEditPredecessorsForTask,
            onEditAssignments: onEditAssignmentsForTask,
            onEditNotes: onEditNotesForTask,
            predecessorLabels: Self.predecessorLabels(for: task, wbsById: wbsById),
            resources: resources,
            wbsById: wbsById, wbsToId: wbsToId,
            wouldCreateCycle: wouldCreateCycleForTask,
            onJumpToTask: onJumpToTask,
            onAddTaskBefore: onAddTaskBeforeForTask,
            onAddTaskAfter: onAddTaskAfterForTask,
            onDeleteTask: onDeleteTaskForTask,
            showCriticalPath: showCriticalPath)
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Self.cell("WBS", width: 44, bold: true)
            Self.cell("Task Name", width: 220, bold: true, alignment: .leading)
            Self.cell("Duration", width: 60, bold: true)
            Self.cell("Start", width: 80, bold: true)
            Self.cell("Finish", width: 80, bold: true)
            Self.cell("% Comp.", width: 56, bold: true)
            Self.cell("Predecessors", width: 80, bold: true)
            Self.cell("Resource Names", width: 140, bold: true, alignment: .leading)
            Self.cell("Notes", width: 160, bold: true, alignment: .leading)
        }
        .frame(height: ganttHeaderHeight)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// First task wins on a duplicate WBS (shouldn't happen in a valid file, but this is purely a
    /// best-effort lookup used to resolve a typed-in WBS code when adding a predecessor).
    private static func wbsToId(for tasks: [GanttTask]) -> [String: Int] {
        var result: [String: Int] = [:]
        for task in tasks where !task.wbs.isEmpty && result[task.wbs] == nil {
            result[task.wbs] = task.id
        }
        return result
    }

    private static func predecessorLabels(for task: GanttTask, wbsById: [Int: String]) -> [PredecessorRef] {
        var result: [PredecessorRef] = []
        for link in task.links {
            let wbs: String = wbsById[link.predecessorId] ?? ""
            let label: String = wbs.isEmpty ? "#\(link.predecessorId)" : wbs
            result.append(PredecessorRef(id: link.predecessorId, label: label))
        }
        return result
    }

    static func cell(_ text: String, width: CGFloat, bold: Bool = false, alignment: Alignment = .center) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(bold ? .semibold : .regular)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 4)
    }
}

/// A predecessor reference resolved to something the table can display and click: the predecessor
/// task's own id (for jump-to) plus its WBS label (or "#<id>" if that task has no WBS).
struct PredecessorRef: Equatable, Identifiable {
    let id: Int
    let label: String
}

extension View {
    /// Selects on mouse-down-up with no perceptible delay. Plain `.onTapGesture(count: 1)` only has
    /// that property in isolation — the moment a same-view `.onTapGesture(count: 2)` also exists
    /// (true of every editable cell below, for double-click-to-edit), SwiftUI inserts a ~0.3s wait
    /// before committing to the single-tap action, to give a possible second click time to arrive
    /// and promote it to a double-tap. A zero-minimum-distance DragGesture isn't part of that
    /// same-family tap-count disambiguation, so its `onEnded` fires immediately on mouse-up — the
    /// double-click still works exactly the same afterward if a second click actually follows.
    func selectImmediatelyOnClick(_ onSelect: @escaping () -> Void) -> some View {
        simultaneousGesture(DragGesture(minimumDistance: 0).onEnded { _ in onSelect() })
    }
}

/// `: Equatable` + `.equatable()` at the ForEach call site (see TaskListPane.body) lets SwiftUI
/// skip re-running a row's body entirely when none of these fields actually changed — critical for
/// click responsiveness: selecting a row changes `isSelected` for exactly two rows (the old and new
/// selection), and without this, SwiftUI would re-diff all 70+ rows' bodies (each with several
/// AppKit-backed cells) on every single click, an O(task count) cost on the most frequent
/// interaction in the app.
private struct TaskListRow: View, Equatable {
    let task: GanttTask
    /// Same role as TaskListPane.tasksVersion: if it's unchanged, this task's own data (and its
    /// derived predecessorLabels) are guaranteed unchanged too, so there's no need to deep-compare
    /// `task`/`predecessorLabels` themselves — a cheap Int + Bool compare is enough.
    let tasksVersion: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onEditName: (String) -> Void
    let onEditPercent: (Double) -> Void
    let onEditDuration: (Double) -> Void
    let onEditDateRange: (Date, Date) -> Void
    let onEditPredecessors: ([GanttLink]) -> Void
    let onEditAssignments: ([TaskAssignment]) -> Void
    let onEditNotes: (String) -> Void
    let predecessorLabels: [PredecessorRef]
    let resources: [ResourceDto]
    let wbsById: [Int: String]
    let wbsToId: [String: Int]
    let wouldCreateCycle: (Int) -> Bool
    let onJumpToTask: (Int) -> Void
    let onAddTaskBefore: () -> Void
    let onAddTaskAfter: () -> Void
    let onDeleteTask: () -> Void
    let showCriticalPath: Bool

    nonisolated static func == (lhs: TaskListRow, rhs: TaskListRow) -> Bool {
        lhs.tasksVersion == rhs.tasksVersion && lhs.isSelected == rhs.isSelected
            && lhs.showCriticalPath == rhs.showCriticalPath
    }

    var body: some View {
        HStack(spacing: 0) {
            selectableCell(TaskListPane.cell(task.wbs, width: 44))
            EditableCell(
                text: String(repeating: "    ", count: max(0, task.outlineLevel - 1)) + task.name,
                width: 220, alignment: .leading, bold: task.isSummary,
                onSelect: onSelect,
                onCommit: { onEditName($0.trimmingCharacters(in: .whitespaces)) })
            EditableCell(
                text: task.durationText, width: 60,
                onSelect: onSelect,
                onCommit: { if let days = Self.parseDays($0) { onEditDuration(days) } })
            DateCell(
                text: Self.dateText(task.start), width: 80,
                taskStart: task.start, taskFinish: task.finish,
                onSelect: onSelect, onApply: onEditDateRange)
            DateCell(
                text: Self.dateText(task.finish), width: 80,
                taskStart: task.start, taskFinish: task.finish,
                onSelect: onSelect, onApply: onEditDateRange)
            EditableCell(
                text: "\(Int(task.percent))%", width: 56,
                onSelect: onSelect,
                onCommit: { if let p = Double($0.filter { $0.isNumber || $0 == "." }) { onEditPercent(p) } })
            PredecessorsCell(
                taskId: task.id, links: task.links, labels: predecessorLabels, width: 80,
                wbsById: wbsById, wbsToId: wbsToId, wouldCreateCycle: wouldCreateCycle,
                onSelect: onSelect, onJump: onJumpToTask, onApply: onEditPredecessors)
            AssignmentsCell(
                taskId: task.id, assignments: task.assignments, displayText: task.resourceNames, width: 140,
                resources: resources, onSelect: onSelect, onApply: onEditAssignments)
            NotesCell(notes: task.notes, width: 160, onSelect: onSelect, onApply: onEditNotes)
        }
        .frame(height: ganttRowHeight)
        .background(
            isSelected ? Color.accentColor.opacity(0.25)
            : ((showCriticalPath && task.isCritical) ? Color.red.opacity(0.08) : Color.clear))
        // A faint per-row divider, matching the Gantt chart's own row-grid line exactly (same color/
        // opacity/weight) so the two synced panes read as one continuous grid rather than the task
        // list looking bare next to the chart's already-gridded rows.
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.gray.opacity(0.2)).frame(height: 0.5)
        }
        .contextMenu {
            Button("Add Task Before", action: onAddTaskBefore)
            Button("Add Task After", action: onAddTaskAfter)
            Divider()
            Button("Delete Task", role: .destructive, action: onDeleteTask)
        }
    }

    // `.frame(maxHeight: .infinity)` before contentShape matters: without it, the clickable area
    // is only as tall as the cell's text (its natural line height), not the full row — leaving an
    // uncovered band near the top/bottom of every row where a click hits nothing.
    private func selectableCell(_ cell: some View) -> some View {
        cell.frame(maxHeight: .infinity).contentShape(Rectangle()).selectImmediatelyOnClick(onSelect)
    }

    /// Accepts a bare number ("5") or a number with a day/week unit ("5 days", "2w") typed back
    /// into a cell that currently displays "<n> days" — intentionally loose, not a full MPXJ-style
    /// duration parser.
    private static func parseDays(_ text: String) -> Double? {
        let trimmed = text.lowercased().trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("w"), let v = Double(trimmed.dropLast().trimmingCharacters(in: .whitespaces)) {
            return v * 7
        }
        let numeric = trimmed.replacingOccurrences(of: "days", with: "").replacingOccurrences(of: "day", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(numeric)
    }

    private static func dateText(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// A table cell that's a plain label until double-clicked, then becomes a text field; Enter or
/// focus-loss commits, Escape cancels. Kept local to TaskListPane rather than reusing
/// TaskListPane.cell since it needs its own edit state.
///
/// Single-tap (select) and double-tap (edit) are both attached to this one view rather than split
/// across this cell and its ancestor row — SwiftUI only reliably disambiguates a tap count against
/// a second, lower-count tap gesture on the *same* view. Split across two nesting levels, the
/// ancestor's single-tap fires immediately on the first click and the double-tap on this view never
/// gets a chance to see the second one.
private struct EditableCell: View {
    let text: String
    let width: CGFloat
    var alignment: Alignment = .center
    var bold: Bool = false
    let onSelect: () -> Void
    let onCommit: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        Group {
            if isEditing {
                FocusedTextField(
                    text: $draft,
                    alignment: alignment == .leading ? .left : .center,
                    onCommit: commit,
                    onCancel: { isEditing = false })
                    .frame(height: 16)
            } else {
                Text(text)
                    .font(.caption)
                    .fontWeight(bold ? .bold : .regular)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: alignment)
        .padding(.horizontal, 4)
        .frame(maxHeight: .infinity)
        .background(isEditing ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(isEditing ? Color.accentColor : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            draft = text
            isEditing = true
        }
        .selectImmediatelyOnClick(onSelect)
    }

    private func commit() {
        isEditing = false
        onCommit(draft)
    }
}

/// A Start/Finish cell: single-tap selects the row like any other cell, double-tap opens a
/// DateRangePicker popover seeded with the task's current Start/Finish (not just this cell's own
/// date — editing either the Start or Finish cell lets you adjust the whole range).
private struct DateCell: View {
    let text: String
    let width: CGFloat
    let taskStart: Date?
    let taskFinish: Date?
    let onSelect: () -> Void
    let onApply: (Date, Date) -> Void

    @State private var showingPicker = false

    var body: some View {
        TaskListPane.cell(text, width: width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if taskStart != nil { showingPicker = true }
            }
            .selectImmediatelyOnClick(onSelect)
            .popover(isPresented: $showingPicker) {
                if let start = taskStart {
                    DateRangePicker(
                        start: start, finish: taskFinish ?? start,
                        onApply: { newStart, newFinish in
                            onApply(newStart, newFinish)
                            showingPicker = false
                        },
                        onCancel: { showingPicker = false })
                }
            }
    }
}

/// The Notes cell: shows notes flattened to one line (real newlines read oddly in a fixed-height
/// grid row), double-click opens a scrollable NotesEditor popover with the real multi-line text for
/// both reading and editing — same double-click-to-edit convention as every other cell.
private struct NotesCell: View {
    let notes: String
    let width: CGFloat
    let onSelect: () -> Void
    let onApply: (String) -> Void

    @State private var showingEditor = false

    var body: some View {
        TaskListPane.cell(Self.singleLine(notes), width: width, alignment: .leading)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                showingEditor = true
            }
            .selectImmediatelyOnClick(onSelect)
            .popover(isPresented: $showingEditor) {
                NotesEditor(
                    initialNotes: notes,
                    onApply: { onApply($0); showingEditor = false },
                    onCancel: { showingEditor = false })
            }
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}

/// The Predecessors cell: plain, static text (same cost as any other cell — no per-item gesture
/// recognizers live in the table row itself, which an earlier version had and which made every
/// row noticeably slower to click, multiplied across 70+ rows). Double-click opens a popover
/// editor (PredecessorEditor, below) for adding/removing/retyping links; it also sidesteps this
/// column's fixed 80pt width, which was clipping chips for any task with more than ~2 predecessors.
private struct PredecessorsCell: View {
    let taskId: Int
    let links: [GanttLink]
    let labels: [PredecessorRef]
    let width: CGFloat
    let wbsById: [Int: String]
    let wbsToId: [String: Int]
    let wouldCreateCycle: (Int) -> Bool
    let onSelect: () -> Void
    let onJump: (Int) -> Void
    let onApply: ([GanttLink]) -> Void

    @State private var showingEditor = false

    var body: some View {
        TaskListPane.cell(labels.map(\.label).joined(separator: ", "), width: width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                showingEditor = true
            }
            .selectImmediatelyOnClick(onSelect)
            .popover(isPresented: $showingEditor) {
                PredecessorEditor(
                    ownTaskId: taskId, initialLinks: links, wbsById: wbsById, wbsToId: wbsToId,
                    wouldCreateCycle: wouldCreateCycle,
                    onJump: { id in
                        onJump(id)
                        showingEditor = false
                    },
                    onApply: { newLinks in
                        onApply(newLinks)
                        showingEditor = false
                    },
                    onCancel: { showingEditor = false })
            }
    }
}

/// Predecessor editor popover: each existing link shows its WBS (click to jump to that row),
/// relation type (FS/SS/FF/SF via a segmented control) and lag in days, plus a remove button; a
/// trailing row adds a new predecessor by WBS code. Everything is local state until Apply — editing
/// a lag field keystroke-by-keystroke shouldn't push half-typed values through AppModel. Jumping to
/// a predecessor discards any in-progress local edits rather than silently half-applying them.
private struct PredecessorEditor: View {
    let ownTaskId: Int
    let wbsById: [Int: String]
    let wbsToId: [String: Int]
    let wouldCreateCycle: (Int) -> Bool
    let onJump: (Int) -> Void
    let onApply: ([GanttLink]) -> Void
    let onCancel: () -> Void

    @State private var links: [GanttLink]
    @State private var newWbsText = ""
    @State private var newType = "FS"
    @State private var newLagText = ""
    @State private var errorMessage: String?

    /// Persisted (not per-popover) so the choice sticks across tasks and app relaunches — this is
    /// an accessibility preference, not a transient editing state like `links`/`newWbsText` above.
    @AppStorage("predecessorTypeFullNames") private var useFullTypeNames = false

    private static let types: [(code: String, full: String)] = [
        ("FS", "Finish-to-Start"),
        ("SS", "Start-to-Start"),
        ("FF", "Finish-to-Finish"),
        ("SF", "Start-to-Finish"),
    ]

    init(
        ownTaskId: Int, initialLinks: [GanttLink], wbsById: [Int: String], wbsToId: [String: Int],
        wouldCreateCycle: @escaping (Int) -> Bool,
        onJump: @escaping (Int) -> Void, onApply: @escaping ([GanttLink]) -> Void, onCancel: @escaping () -> Void
    ) {
        self.ownTaskId = ownTaskId
        self.wbsById = wbsById
        self.wbsToId = wbsToId
        self.wouldCreateCycle = wouldCreateCycle
        self.onJump = onJump
        self.onApply = onApply
        self.onCancel = onCancel
        _links = State(initialValue: initialLinks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Predecessors").font(.headline)
                Spacer()
                Toggle(isOn: $useFullTypeNames) {
                    Text("Full names").font(.caption)
                }
                .toggleStyle(.checkbox)
                .help("Show relationship types (FS/SS/FF/SF) as full words")
            }

            if links.isEmpty {
                Text("None").font(.caption).foregroundStyle(.secondary)
            }

            ForEach(links.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    Button(wbsById[links[index].predecessorId] ?? "#\(links[index].predecessorId)") {
                        onJump(links[index].predecessorId)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .frame(width: 60, alignment: .leading)

                    relationshipPicker(selection: $links[index].type)

                    TextField("Lag", value: $links[index].lagDays, format: .number)
                        .frame(width: 40)

                    Button {
                        links.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 6) {
                TextField("WBS", text: $newWbsText)
                    .frame(width: 60)
                relationshipPicker(selection: $newType)
                TextField("Lag", text: $newLagText)
                    .frame(width: 40)
                Button("Add", action: addPredecessor)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Apply") { onApply(links) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(minWidth: 330)
    }

    /// Segmented when abbreviated (compact, four codes fit side by side); a dropdown menu when
    /// spelled out, since "Finish-to-Start" etc. side by side wouldn't fit this popover's width —
    /// the menu button only ever shows the one selected label, so switching modes doesn't reflow
    /// anything else in the editor. Full words exist for VoiceOver: a segmented control's abbreviated
    /// titles get read letter-by-letter ("F", "S"), which doesn't convey the relationship.
    @ViewBuilder
    private func relationshipPicker(selection: Binding<String>) -> some View {
        if useFullTypeNames {
            Picker("", selection: selection) {
                ForEach(Self.types, id: \.code) { Text($0.full).tag($0.code) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 150)
        } else {
            Picker("", selection: selection) {
                ForEach(Self.types, id: \.code) { Text($0.code).tag($0.code) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
        }
    }

    private func addPredecessor() {
        errorMessage = nil
        let trimmed = newWbsText.trimmingCharacters(in: .whitespaces)
        guard let predecessorId = wbsToId[trimmed] else {
            errorMessage = "No task with WBS \"\(trimmed)\""
            return
        }
        guard predecessorId != ownTaskId else {
            errorMessage = "A task can't depend on itself"
            return
        }
        guard !links.contains(where: { $0.predecessorId == predecessorId }) else {
            errorMessage = "Already a predecessor"
            return
        }
        guard !wouldCreateCycle(predecessorId) else {
            errorMessage = "That would create a circular dependency"
            return
        }
        let lag = Double(newLagText.trimmingCharacters(in: .whitespaces)) ?? 0
        links.append(GanttLink(predecessorId: predecessorId, type: newType, lagDays: lag))
        newWbsText = ""
        newLagText = ""
    }
}

/// The Resources cell: same read-until-double-clicked shape as PredecessorsCell — plain text
/// (`task.resourceNames`, already kept up to date by AppModel) until double-clicked, then an
/// AssignmentEditor popover for adding/removing resources and editing each one's Units%.
private struct AssignmentsCell: View {
    let taskId: Int
    let assignments: [TaskAssignment]
    let displayText: String
    let width: CGFloat
    let resources: [ResourceDto]
    let onSelect: () -> Void
    let onApply: ([TaskAssignment]) -> Void

    @State private var showingEditor = false

    var body: some View {
        TaskListPane.cell(displayText, width: width, alignment: .leading)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                showingEditor = true
            }
            .selectImmediatelyOnClick(onSelect)
            .popover(isPresented: $showingEditor) {
                AssignmentEditor(
                    initialAssignments: assignments, resources: resources,
                    onApply: { newAssignments in
                        onApply(newAssignments)
                        showingEditor = false
                    },
                    onCancel: { showingEditor = false })
            }
    }
}

/// Resource assignment editor popover: each existing assignment shows the resource's name (not
/// editable here — reassigning to a *different* resource is remove-then-add, same as Predecessors'
/// "jump instead of retype" convention) and an editable Units% field, plus a remove button; a
/// trailing row adds a new assignment by picking from resources not already on this task. Everything
/// is local state until Apply, same rationale as PredecessorEditor — a half-typed Units% shouldn't
/// push through AppModel keystroke-by-keystroke.
///
/// Not private: also reused by ResourceTimelineView's "Edit Assignment…" context menu action, which
/// opens this same editor scoped to whichever task's bar was clicked — one editor, two entry points.
struct AssignmentEditor: View {
    let resources: [ResourceDto]
    let onApply: ([TaskAssignment]) -> Void
    let onCancel: () -> Void

    @State private var assignments: [TaskAssignment]
    @State private var newResourceId: Int?
    @State private var errorMessage: String?

    init(
        initialAssignments: [TaskAssignment], resources: [ResourceDto],
        onApply: @escaping ([TaskAssignment]) -> Void, onCancel: @escaping () -> Void
    ) {
        self.resources = resources
        self.onApply = onApply
        self.onCancel = onCancel
        _assignments = State(initialValue: initialAssignments)
    }

    private var resourcesById: [Int: ResourceDto] {
        Dictionary(uniqueKeysWithValues: resources.map { ($0.uniqueId, $0) })
    }

    private var availableResources: [ResourceDto] {
        let assignedIds = Set(assignments.map(\.resourceId))
        return resources.filter { !assignedIds.contains($0.uniqueId) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Resources").font(.headline)

            if assignments.isEmpty {
                Text("None").font(.caption).foregroundStyle(.secondary)
            }

            ForEach(assignments.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    Text(resourcesById[assignments[index].resourceId]?.name ?? "#\(assignments[index].resourceId)")
                        .frame(width: 140, alignment: .leading)
                        .lineLimit(1)

                    TextField("Units", value: $assignments[index].units, format: .number)
                        .frame(width: 44)
                    Text("%").font(.caption).foregroundStyle(.secondary)

                    Button {
                        assignments.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            Divider()

            if availableResources.isEmpty {
                Text(resources.isEmpty ? "No resources defined yet." : "Every resource is already assigned.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Picker("", selection: $newResourceId) {
                        Text("Resource…").tag(Int?.none)
                        ForEach(availableResources) { resource in
                            Text(resource.name).tag(Int?.some(resource.uniqueId))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Button("Add", action: addAssignment)
                        .disabled(newResourceId == nil)
                }
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Apply") { onApply(assignments) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(minWidth: 300)
    }

    private func addAssignment() {
        errorMessage = nil
        guard let resourceId = newResourceId else { return }
        assignments.append(TaskAssignment(resourceId: resourceId, units: 100))
        newResourceId = nil
    }
}

/// A plain AppKit NSTextField, used instead of SwiftUI's own TextField/@FocusState combo.
/// @FocusState's request to become first responder turned out not to reliably reach real AppKit
/// keyboard focus here — this cell lives inside an NSHostingView that's manually set as an
/// NSScrollView's documentView (see SyncedScrollHost), not a plain SwiftUI ScrollView, and that
/// extra layer of custom hosting is exactly the kind of setup where SwiftUI's focus bridging is
/// known to silently fail. Driving `window.makeFirstResponder` ourselves is deterministic.
private struct FocusedTextField: NSViewRepresentable {
    @Binding var text: String
    var alignment: NSTextAlignment = .center
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusGrabbingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.alignment = alignment
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.stringValue = text
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var didFocus = false
        private let text: Binding<String>
        private let onCommit: () -> Void
        private let onCancel: () -> Void
        private var committed = false

        init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                commitOnce()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                committed = true // suppress the end-editing commit that follows resigning focus
                onCancel()
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            commitOnce()
        }

        private func commitOnce() {
            guard !committed else { return }
            committed = true
            onCommit()
        }
    }
}

/// Grabs real AppKit keyboard focus the moment it's inserted into a window, synchronously as part
/// of the view-hierarchy hookup — not via a DispatchQueue.main.async from SwiftUI's updateNSView,
/// which can race a fast typist (the async block may not run until after the first keystroke has
/// already been dispatched elsewhere).
private final class FocusGrabbingTextField: NSTextField {
    private var didFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didFocus, let window else { return }
        didFocus = true
        window.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }
}
