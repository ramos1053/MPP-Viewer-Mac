import Foundation

/// A task-list edit (Add Before/After/Delete) waiting on the user's confirmation — set identically
/// whether it was requested via a row's right-click context menu or via the Task menu/keyboard
/// shortcut on the current selection, so both paths show the exact same dialog (see ContentView).
enum PendingTaskAction: Identifiable, Equatable {
    case addBefore(taskId: Int)
    case addAfter(taskId: Int)
    case delete(taskId: Int)

    var id: String {
        switch self {
        case .addBefore(let id): return "addBefore-\(id)"
        case .addAfter(let id): return "addAfter-\(id)"
        case .delete(let id): return "delete-\(id)"
        }
    }

    var taskId: Int {
        switch self {
        case .addBefore(let id), .addAfter(let id), .delete(let id): return id
        }
    }

    var isDestructive: Bool {
        if case .delete = self { return true }
        return false
    }

    var title: String { isDestructive ? "Delete Task" : "Add Task" }
}

/// An Edit-menu Find command waiting on ContentView to act on it — same cross-view-to-AppModel trigger
/// pattern as PendingTaskAction, needed for the same reason: the Edit menu lives in MPPViewerMacApp,
/// but the search text and match-stepping logic it needs to drive are private state on ContentView.
enum FindMenuAction: Equatable {
    case next
    case previous
    case replace
}

final class AppModel: ObservableObject {
    @Published var title = ""
    /// The task highlighted in both panes. Lives here (not as View-local @State) so the Task menu's
    /// keyboard shortcuts can act on "whatever is currently selected" the same way a row's own
    /// right-click context menu acts on "whatever row you clicked" — see MPPViewerMacApp.commands.
    @Published var selectedTaskId: Int?
    @Published var pendingTaskAction: PendingTaskAction?
    @Published var pendingFindAction: FindMenuAction?
    /// Bumped on every assignment (see didSet) so views can tell "did the task data actually
    /// change" with a cheap Int compare instead of a deep field-by-field comparison of the whole
    /// array — see TaskListPane/TimelineCanvas's Equatable, which used to do that deep compare on
    /// every single click just to confirm a pure selection change hadn't touched the data, and was
    /// a real, measurable chunk of the per-click cost.
    private(set) var tasksVersion = 0
    @Published var tasks: [GanttTask] = [] {
        didSet { tasksVersion += 1 }
    }
    @Published var resources: [ResourceDto] = []
    var resourcesById: [Int: ResourceDto] {
        Dictionary(uniqueKeysWithValues: resources.map { ($0.uniqueId, $0) })
    }
    /// The whole project's budget — 0 means "no budget set," same sentinel convention as
    /// costPerUse/maxUnits defaulting to 0/100 elsewhere. Backed by MPXJ's real Budget Resource
    /// mechanism (see Helper's SetBudgetCost), not an app-local preference, so it round-trips with
    /// the file and would show up if the file were opened in MS Project itself.
    @Published var budgetCost: Double = 0
    /// Working-time calendar definitions (the Calendars view). Round-tripped on every save just
    /// like tasks/resources now that this app has a real editor for them — see Helper's Save for
    /// why an *external* caller (this app's own generator scripts, say) can still omit this field
    /// safely, which this app itself never needs to do.
    @Published var calendars: [CalendarDto] = []
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var isSaving = false
    /// Path of the file last opened or saved to — what plain "Save" (⌘S) writes to without prompting.
    /// nil until the first open or Save As, matching the "no file open" empty state.
    @Published private(set) var currentFilePath: String?

    /// True when plain Save can't just write to `currentFilePath` in place and needs to prompt for a
    /// location instead — true with nothing open yet, and true whenever the open file isn't already
    /// Project XML (the overwhelmingly common case: opening a .mpp and hitting ⌘S must not silently
    /// replace that binary file with XML content at the same path, since Project XML is the only
    /// format the Helper can actually write — see Helper's Save).
    var needsSaveAsPath: Bool {
        guard let currentFilePath else { return true }
        return !currentFilePath.lowercased().hasSuffix(".xml")
    }

    /// Set when New Project is requested while something's already loaded, so ContentView can
    /// confirm before silently discarding unsaved edits — there's no dirty-tracking in this app, so
    /// this is the one guard against losing work that way.
    @Published var pendingNewProject = false

    let undoManager = UndoManager()

    private var helper: HelperProcess?

    var dateRange: ClosedRange<Date>? {
        let starts = tasks.compactMap(\.start)
        let finishes = tasks.compactMap(\.finish)
        guard let minStart = starts.min(), let maxFinish = finishes.max(), minStart < maxFinish else { return nil }
        return minStart...maxFinish
    }

    func openFile(at path: String) {
        isLoading = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let helper = try self.helper ?? self.makeHelper()
                self.helper = helper
                let result = try helper.open(path: path)
                var rows = result.tasks.map(GanttTask.init)
                let resourcesById = Dictionary(uniqueKeysWithValues: result.resources.map { ($0.uniqueId, $0) })
                for i in rows.indices {
                    rows[i].resourceNames = Self.resourceNamesText(for: rows[i].assignments, resourcesById: resourcesById)
                }
                Scheduler.recomputeCriticalPath(&rows)
                DispatchQueue.main.async {
                    self.title = result.title
                    self.tasks = rows
                    self.resources = result.resources
                    self.budgetCost = result.budgetCost
                    self.calendars = result.calendars
                    self.currentFilePath = path
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "\(error)"
                    self.isLoading = false
                }
            }
        }
    }

    /// Entry point for New Project (toolbar, File menu, and the empty-state action all call this).
    /// Nothing to lose with an empty project already, so that case skips the confirmation outright.
    func requestNewProject() {
        if tasks.isEmpty {
            newProject()
        } else {
            pendingNewProject = true
        }
    }

    func confirmNewProject() {
        pendingNewProject = false
        newProject()
    }

    /// Starts a blank project seeded with one starter task (rather than truly zero tasks) so the
    /// Gantt/table view renders immediately instead of falling back to the "No File Open" empty
    /// state — `dateRange` (and Fit-to-window, and every WBS/Scheduler computation) all assume at
    /// least one dated task exists. The seed is an ordinary task from here on: rename it, delete it,
    /// add more around it with the same Add Task flow as any other project.
    private func newProject() {
        isLoading = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let helper = try self.helper ?? self.makeHelper()
                self.helper = helper
                let result = try helper.new()
                let start = Calendar.ganttUTC.startOfDay(for: Date())
                var seed = GanttTask.blank(id: 1, outlineLevel: 1, start: start, finish: Scheduler.addDays(start, 1))
                seed.wbs = "1"
                seed.isCritical = true
                DispatchQueue.main.async {
                    self.title = result.title
                    self.tasks = [seed]
                    self.resources = result.resources
                    self.budgetCost = result.budgetCost
                    self.calendars = result.calendars
                    self.currentFilePath = nil
                    self.selectedTaskId = nil
                    self.undoManager.removeAllActions()
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "\(error)"
                    self.isLoading = false
                }
            }
        }
    }

    /// Plain Save (⌘S): writes back to whatever file is already open. No-ops if nothing's open yet —
    /// ContentView only offers this once `currentFilePath` is non-nil, so this is a safety guard, not
    /// the primary gate.
    func save() {
        guard let path = currentFilePath else { return }
        performSave(to: path)
    }

    /// Save As: writes to a new path and, on success, adopts it as the file further plain Saves go
    /// to — same as every other document-based Mac app.
    func saveAs(to path: String) {
        performSave(to: path)
    }

    /// Writes Project XML (MSPDI) via the Helper, which applies this array onto the live MPXJ
    /// project it already holds from `open` — see Helper's Save for why that's done there and not
    /// by reconstructing a project from these DTOs here.
    private func performSave(to path: String) {
        isSaving = true
        errorMessage = nil
        let dtos = tasks.map { $0.toDto() }
        let resourceDtos = resources
        let budget = budgetCost
        let calendarDtos = calendars

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                guard let helper = self.helper else {
                    throw HelperError.helperError("No project is open.")
                }
                try helper.save(path: path, tasks: dtos, resources: resourceDtos, budgetCost: budget, calendars: calendarDtos)
                DispatchQueue.main.async {
                    self.currentFilePath = path
                    self.isSaving = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "\(error)"
                    self.isSaving = false
                }
            }
        }
    }

    func shutdown() {
        helper?.shutdown()
        helper = nil
    }

    func setName(taskId: Int, to newName: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }), tasks[idx].name != newName else { return }
        pushUndoSnapshot(actionName: "Rename")
        tasks[idx].name = newName
    }

    func setNotes(taskId: Int, to newNotes: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }), tasks[idx].notes != newNotes else { return }
        pushUndoSnapshot(actionName: "Edit Notes")
        tasks[idx].notes = newNotes
    }

    func setPercent(taskId: Int, to newPercent: Double) {
        let clamped = min(max(newPercent, 0), 100)
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }), tasks[idx].percent != clamped else { return }
        pushUndoSnapshot(actionName: "Edit % Complete")
        tasks[idx].percent = clamped
    }

    func setDurationDays(taskId: Int, to newDuration: Double) {
        let clamped = max(newDuration, 0)
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }), tasks[idx].durationDays != clamped else { return }
        pushUndoSnapshot(actionName: "Edit Duration")
        tasks[idx].durationDays = clamped
        Scheduler.recalculate(&tasks, from: taskId)
    }

    /// From the DateRangePicker popover — sets Start/Finish directly rather than a duration
    /// number, then re-derives duration (Finish − Start, matching the convention Scheduler/Helper
    /// already use) and cascades to successors exactly like a duration edit.
    func setDateRange(taskId: Int, start: Date, finish: Date) {
        let clampedFinish = max(start, finish)
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }),
              tasks[idx].start != start || tasks[idx].finish != clampedFinish else { return }
        pushUndoSnapshot(actionName: "Edit Dates")
        tasks[idx].start = start
        tasks[idx].finish = clampedFinish
        tasks[idx].durationDays = Double(Calendar.ganttUTC.dateComponents([.day], from: start, to: clampedFinish).day ?? 0)
        Scheduler.recalculate(&tasks, from: taskId)
    }

    /// From the Predecessors popover editor. Validation (no self-reference, no duplicate
    /// predecessor, no cycle) happens in the popover before it ever calls this — this just applies
    /// whatever link list it was handed and re-derives the task's own schedule from it.
    func setPredecessors(taskId: Int, to newLinks: [GanttLink]) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }), tasks[idx].links != newLinks else { return }
        pushUndoSnapshot(actionName: "Edit Predecessors")
        tasks[idx].links = newLinks
        Scheduler.recalculate(&tasks, from: taskId, revisitOwnConstraints: true)
    }

    /// From the Resources popover editor (TaskListPane's AssignmentsCell). No scheduling impact —
    /// this app doesn't do resource leveling, so assigning/reassigning a resource never moves dates.
    func setAssignments(taskId: Int, to newAssignments: [TaskAssignment]) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }), tasks[idx].assignments != newAssignments else { return }
        pushUndoSnapshot(actionName: "Edit Resources")
        tasks[idx].assignments = newAssignments
        tasks[idx].resourceNames = Self.resourceNamesText(for: newAssignments, resourcesById: resourcesById)
    }

    // ---- Resource Sheet edits --------------------------------------------------------------------

    func setResourceName(id: Int, to newName: String) {
        updateResource(id: id, actionName: "Rename Resource") { $0.name = newName }
    }

    func setResourceType(id: Int, to newType: String) {
        updateResource(id: id, actionName: "Edit Resource Type") { $0.type = newType }
    }

    func setResourceInitials(id: Int, to newInitials: String) {
        updateResource(id: id, actionName: "Edit Resource Initials") { $0.initials = newInitials }
    }

    func setResourceGroup(id: Int, to newGroup: String) {
        updateResource(id: id, actionName: "Edit Resource Group") { $0.group = newGroup }
    }

    func setResourceCode(id: Int, to newCode: String) {
        updateResource(id: id, actionName: "Edit Resource Code") { $0.code = newCode }
    }

    func setResourceAccrueAt(id: Int, to newAccrueAt: String) {
        updateResource(id: id, actionName: "Edit Resource Accrual") { $0.accrueAt = newAccrueAt }
    }

    func setResourceMaxUnits(id: Int, to newMaxUnits: Double) {
        updateResource(id: id, actionName: "Edit Max Units") { $0.maxUnits = max(0, newMaxUnits) }
    }

    func setResourceStandardRate(id: Int, amount: Double, unit: String) {
        updateResource(id: id, actionName: "Edit Standard Rate") {
            $0.standardRateAmount = max(0, amount)
            $0.standardRateUnit = unit
        }
    }

    func setResourceOvertimeRate(id: Int, amount: Double, unit: String) {
        updateResource(id: id, actionName: "Edit Overtime Rate") {
            $0.overtimeRateAmount = max(0, amount)
            $0.overtimeRateUnit = unit
        }
    }

    func setResourceCostPerUse(id: Int, to newCostPerUse: Double) {
        updateResource(id: id, actionName: "Edit Cost Per Use") { $0.costPerUse = max(0, newCostPerUse) }
    }

    /// From the budget popover (see ContentView's toolbar). Undoable like every other edit, via the
    /// same whole-array-snapshot pushUndoSnapshot — see its doc comment for why that still works fine
    /// for a single scalar like this (the tasks/resources arrays just restore to themselves, a no-op).
    func setBudget(to newBudget: Double) {
        let clamped = max(0, newBudget)
        guard budgetCost != clamped else { return }
        pushUndoSnapshot(actionName: "Edit Budget")
        budgetCost = clamped
    }

    private func updateResource(id: Int, actionName: String, _ mutate: (inout ResourceDto) -> Void) {
        guard let idx = resources.firstIndex(where: { $0.uniqueId == id }) else { return }
        var updated = resources[idx]
        mutate(&updated)
        guard updated != resources[idx] else { return }
        pushUndoSnapshot(actionName: actionName)
        resources[idx] = updated
        // A resource's own name feeds every task's cached display string below, so a rename needs to
        // ripple there too, not just into the Resource Sheet row.
        recomputeAllResourceNames()
    }

    func addResource() {
        pushUndoSnapshot(actionName: "Add Resource")
        let newId = (resources.map(\.uniqueId).max() ?? 0) + 1
        resources.append(.blank(uniqueId: newId))
    }

    /// Removes a resource and strips it out of every task's assignment list (otherwise those
    /// assignments would dangle, pointing at an id nothing resolves to) — same pattern as
    /// deleteTask's predecessor-link cleanup.
    func deleteResource(_ resourceId: Int) {
        guard let idx = resources.firstIndex(where: { $0.uniqueId == resourceId }) else { return }
        pushUndoSnapshot(actionName: "Delete Resource")
        resources.remove(at: idx)
        for i in tasks.indices {
            tasks[i].assignments.removeAll { $0.resourceId == resourceId }
        }
        recomputeAllResourceNames()
    }

    private func recomputeAllResourceNames() {
        let byId = resourcesById
        for i in tasks.indices {
            tasks[i].resourceNames = Self.resourceNamesText(for: tasks[i].assignments, resourcesById: byId)
        }
    }

    /// Same display convention the Helper used to compute server-side before assignments became
    /// editable client-side: resource names joined by "; ", with a "[N%]" suffix only when a resource
    /// isn't assigned at the default 100%.
    static func resourceNamesText(for assignments: [TaskAssignment], resourcesById: [Int: ResourceDto]) -> String {
        assignments.map { assignment in
            let name = resourcesById[assignment.resourceId]?.name ?? "#\(assignment.resourceId)"
            let suffix = abs(assignment.units - 100) > 0.001 ? "[\(Self.trimmedPercent(assignment.units))%]" : ""
            return name + suffix
        }.joined(separator: "; ")
    }

    private static func trimmedPercent(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func updateCalendar(id: Int, actionName: String, _ mutate: (inout CalendarDto) -> Void) {
        guard let idx = calendars.firstIndex(where: { $0.uniqueId == id }) else { return }
        var updated = calendars[idx]
        mutate(&updated)
        guard updated != calendars[idx] else { return }
        pushUndoSnapshot(actionName: actionName)
        calendars[idx] = updated
    }

    func setCalendarWorkingDay(calendarId: Int, dayIndex: Int, working: Bool) {
        updateCalendar(id: calendarId, actionName: "Edit Working Day") { cal in
            guard cal.workingDays.indices.contains(dayIndex) else { return }
            cal.workingDays[dayIndex] = working
        }
    }

    func setCalendarExceptions(calendarId: Int, to newExceptions: [CalendarExceptionDto]) {
        updateCalendar(id: calendarId, actionName: "Edit Calendar Exceptions") { cal in
            cal.exceptions = newExceptions
        }
    }

    func renameCalendar(calendarId: Int, to newName: String) {
        updateCalendar(id: calendarId, actionName: "Rename Calendar") { cal in
            cal.name = newName
        }
    }

    func addCalendar() {
        pushUndoSnapshot(actionName: "Add Calendar")
        let newId = (calendars.map(\.uniqueId).max() ?? 0) + 1
        calendars.append(.blank(uniqueId: newId, name: "New Calendar"))
    }

    func deleteCalendar(_ calendarId: Int) {
        guard let idx = calendars.firstIndex(where: { $0.uniqueId == calendarId }) else { return }
        pushUndoSnapshot(actionName: "Delete Calendar")
        calendars.remove(at: idx)
    }

    /// Carries out whatever Add/Delete is currently waiting on confirmation, then clears it.
    /// ContentView's confirmation dialog calls this from its primary button.
    func confirmPendingTaskAction() {
        guard let action = pendingTaskAction else { return }
        switch action {
        case .addBefore(let id): insertTask(before: id)
        case .addAfter(let id): insertTask(after: id)
        case .delete(let id): deleteTask(id)
        }
        pendingTaskAction = nil
    }

    /// Inserts a blank new task immediately before `anchorId`, at the same outline level, then
    /// renumbers WBS as narrowly as possible (see renumberWBS).
    func insertTask(before anchorId: Int) { insertTask(relativeTo: anchorId, placeAfter: false) }

    /// Inserts a blank new task immediately after `anchorId`, at the same outline level, then
    /// renumbers WBS as narrowly as possible (see renumberWBS).
    func insertTask(after anchorId: Int) { insertTask(relativeTo: anchorId, placeAfter: true) }

    private func insertTask(relativeTo anchorId: Int, placeAfter: Bool) {
        guard let anchorIdx = tasks.firstIndex(where: { $0.id == anchorId }) else { return }
        pushUndoSnapshot(actionName: "Add Task")
        let anchor = tasks[anchorIdx]
        let newId = (tasks.map(\.id).max() ?? 0) + 1
        let finish = anchor.start.map { Scheduler.addDays($0, 1) }
        let newTask = GanttTask.blank(id: newId, outlineLevel: anchor.outlineLevel, start: anchor.start, finish: finish)
        let insertIdx = placeAfter ? anchorIdx + 1 : anchorIdx
        tasks.insert(newTask, at: insertIdx)
        Self.renumberWBS(&tasks, near: insertIdx)
        Scheduler.recomputeCriticalPath(&tasks)
    }

    /// Removes a task, strips it out of every other task's predecessor list (otherwise those links
    /// would dangle, pointing at an id nothing resolves to), then renumbers WBS to close the gap.
    func deleteTask(_ taskId: Int) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        pushUndoSnapshot(actionName: "Delete Task")
        tasks.remove(at: idx)
        for i in tasks.indices {
            tasks[i].links.removeAll { $0.predecessorId == taskId }
        }
        if !tasks.isEmpty {
            Self.renumberWBS(&tasks, near: min(idx, tasks.count - 1))
        }
        Scheduler.recomputeCriticalPath(&tasks)
    }

    /// Renumbers WBS after an insert/delete, scoped as tightly as possible. A top-level
    /// ("whole-number") task has no narrower scope available — opening or closing a whole-number
    /// slot necessarily shifts every later whole-number section — so that case still renumbers the
    /// entire sheet. But a task nested *under* a whole number only renumbers the decimals within
    /// that one branch (e.g. inserting under "1.7" touches 1.8, 1.9, … but leaves "2", "3", etc. and
    /// everything under them completely untouched, including any custom/gapped numbering they have).
    private static func renumberWBS(_ tasks: inout [GanttTask], near index: Int) {
        guard tasks.indices.contains(index) else { return }
        if tasks[index].outlineLevel <= 1 {
            recomputeWBS(&tasks)
        } else {
            recomputeWBS(&tasks, withinBranchContaining: index)
        }
    }

    /// Recomputes every task's WBS from outline level + array order — the canonical hierarchical
    /// numbering (1, 1.1, 1.2, 2, 2.1, ...), not whatever string the file originally had.
    private static func recomputeWBS(_ tasks: inout [GanttTask]) {
        var counters: [Int] = []
        for i in tasks.indices {
            let level = max(1, tasks[i].outlineLevel)
            if counters.count < level {
                counters.append(contentsOf: Array(repeating: 0, count: level - counters.count))
            } else if counters.count > level {
                counters.removeLast(counters.count - level)
            }
            counters[level - 1] += 1
            tasks[i].wbs = counters.map(String.init).joined(separator: ".")
        }
    }

    /// Same renumbering, but confined to the one whole-number branch containing `index`: everything
    /// from the nearest enclosing top-level (outlineLevel 1) task up to (not including) the next
    /// top-level task. The branch's own leading WBS segment (its whole number, whatever string it
    /// already is) is kept as-is and reused as the prefix for every nested item.
    private static func recomputeWBS(_ tasks: inout [GanttTask], withinBranchContaining index: Int) {
        var branchStart = index
        while branchStart > 0 && tasks[branchStart].outlineLevel > 1 {
            branchStart -= 1
        }
        var branchEnd = branchStart + 1
        while branchEnd < tasks.count && tasks[branchEnd].outlineLevel > 1 {
            branchEnd += 1
        }
        guard branchEnd > branchStart + 1 else { return }

        let wholeNumber = tasks[branchStart].wbs.split(separator: ".").first.map(String.init) ?? tasks[branchStart].wbs
        let rootLevel = tasks[branchStart].outlineLevel
        var counters: [Int] = []
        for i in (branchStart + 1)..<branchEnd {
            let level = tasks[i].outlineLevel - rootLevel
            guard level >= 1 else { continue }
            if counters.count < level {
                counters.append(contentsOf: Array(repeating: 0, count: level - counters.count))
            } else if counters.count > level {
                counters.removeLast(counters.count - level)
            }
            counters[level - 1] += 1
            tasks[i].wbs = ([wholeNumber] + counters.map(String.init)).joined(separator: ".")
        }
    }

    /// Every mutation above registers the whole-array before/after as one undo step rather than
    /// computing a precise inverse. Duration edits can cascade dates across many successor tasks,
    /// so a full snapshot is simpler and safer than hand-writing an inverse recalculation — the
    /// array is just structs, so copying it is cheap. Snapshots both `tasks` and `resources`
    /// unconditionally (not just whichever one the caller is about to touch) so a single undo step
    /// always restores both consistently — e.g. deleting a resource touches both arrays at once, and
    /// a task-only edit just restores `resources` to itself, a no-op.
    private func pushUndoSnapshot(actionName: String) {
        let beforeTasks = tasks
        let beforeResources = resources
        let beforeBudget = budgetCost
        let beforeCalendars = calendars
        undoManager.registerUndo(withTarget: self) { target in
            let afterTasks = target.tasks
            let afterResources = target.resources
            let afterBudget = target.budgetCost
            let afterCalendars = target.calendars
            target.tasks = beforeTasks
            target.resources = beforeResources
            target.budgetCost = beforeBudget
            target.calendars = beforeCalendars
            target.undoManager.registerUndo(withTarget: target) { target in
                target.tasks = afterTasks
                target.resources = afterResources
                target.budgetCost = afterBudget
                target.calendars = afterCalendars
            }
        }
        undoManager.setActionName(actionName)
    }

    private func makeHelper() throws -> HelperProcess {
        try HelperProcess(executableURL: Self.defaultHelperURL())
    }

    /// A packaged .app bundles its own self-contained Helper publish output (the whole directory —
    /// MppHelper plus every native dylib it needs, all signed, see BUILDING.md's packaging section)
    /// under Contents/Resources/Helper/. Preferred first so a real installed app never depends on the
    /// dev-only source-relative fallback below, which only exists inside this source checkout.
    private static func defaultHelperURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["MPP_HELPER_PATH"] {
            return URL(fileURLWithPath: override)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Helper/MppHelper"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        // Dev-time location: Helper/bin/Debug/net9.0/MppHelper, a sibling of the App/ package.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources/MPPViewerMac
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // App
            .deletingLastPathComponent() // MPP-Viewer-Mac
            .appendingPathComponent("Helper/bin/Debug/net9.0/MppHelper")
    }
}
