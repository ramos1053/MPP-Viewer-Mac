import Foundation

/// Dependency scheduling. MPXJ has no scheduling engine of its own (it only reads and writes project
/// files), so this is a small hand-rolled CPM pass: calendar days only, no working-time calendars, no
/// resource leveling — but it does do both halves of real CPM now: a forward pass (`recalculate`)
/// that pushes dates to keep dependents consistent after an edit, and a backward pass
/// (`recomputeCriticalPath`) that derives float and a live critical path from the result. A
/// documented simplification, consistent with the other calendar-day approximations already in this
/// project (see Helper's DaysFor) — just without a calendar, not without a critical path anymore.
enum Scheduler {
    /// Recomputes dates for `changedId` and everything downstream of it, in place.
    /// Call after mutating a task's own start/duration; this only pushes dates forward, it never
    /// moves a task earlier than a manual edit just gave it.
    ///
    /// `revisitOwnConstraints`: when the edit was to `changedId`'s *own* predecessor list (not its
    /// duration/dates), its own start needs to be re-derived from those predecessors too, not just
    /// pushed forward to successors from wherever it already was — pass true from
    /// AppModel.setPredecessors. Duration/date edits don't need this: the task's own start was just
    /// set directly by the edit, so only its finish (and then its successors) need recomputing.
    static func recalculate(_ tasks: inout [GanttTask], from changedId: Int, revisitOwnConstraints: Bool = false) {
        var indexById: [Int: Int] = [:]
        for (i, task) in tasks.enumerated() { indexById[task.id] = i }

        // successors[predecessorId] = [(successorId, linkType, lagDays)]
        var successors: [Int: [(Int, String, Double)]] = [:]
        for task in tasks {
            for link in task.links {
                successors[link.predecessorId, default: []].append((task.id, link.type, link.lagDays))
            }
        }

        guard let startIndex = indexById[changedId] else { return }
        if revisitOwnConstraints {
            applyConstraints(&tasks[startIndex], predecessors: predecessorsOf(changedId, in: tasks, indexById: indexById))
        } else {
            recomputeOwnFinish(&tasks[startIndex])
        }

        var queue = [changedId]
        var queued = Set(queue)
        while let id = queue.first {
            queue.removeFirst()
            queued.remove(id)
            guard let successorList = successors[id] else { continue }
            for (successorId, _, _) in successorList {
                guard let idx = indexById[successorId] else { continue }
                if applyConstraints(&tasks[idx], predecessors: predecessorsOf(successorId, in: tasks, indexById: indexById)) {
                    if !queued.contains(successorId) {
                        queue.append(successorId)
                        queued.insert(successorId)
                    }
                }
            }
        }

        // Criticality is a whole-project property (float on an untouched task can appear or
        // disappear because of an edit somewhere else entirely in the network), so this always
        // does a full pass rather than trying to limit itself to whatever just cascaded above.
        recomputeCriticalPath(&tasks)
    }

    /// Backward pass: computes late start/finish and total float for every dated task, then marks
    /// `isCritical` (float ~0) — the piece the forward pass above deliberately doesn't do (see its
    /// doc comment). Call this after any edit that can move dates or change the dependency graph;
    /// `recalculate` above already does, and so does AppModel after load/insert/delete.
    ///
    /// This still has no concept of a working-time calendar (see Calendars/CalendarsView) — late
    /// dates are plain calendar-day arithmetic, same as the forward pass, so a project that depends
    /// on Microsoft Project's own calendar system will diverge. It does, however, give a from-scratch
    /// project a real, live critical path for the first time, rather than only ever displaying a
    /// `critical` flag a file happened to carry in.
    static func recomputeCriticalPath(_ tasks: inout [GanttTask]) {
        var indexById: [Int: Int] = [:]
        for (i, task) in tasks.enumerated() { indexById[task.id] = i }

        // Every dated task participates in the graph, summaries included — a real file can have a
        // dependency pointing at a summary's id, and the forward pass above doesn't special-case
        // that either (predecessorsOf looks up by id, not by isSummary). Summaries get their
        // `isCritical` overwritten by the rollup rule at the bottom regardless of what this graph
        // pass computes for them directly.
        let participantIds = tasks.filter { $0.start != nil && $0.finish != nil }.map(\.id)
        guard !participantIds.isEmpty else {
            for i in tasks.indices { tasks[i].isCritical = false }
            return
        }
        let participantSet = Set(participantIds)

        var successors: [Int: [(id: Int, type: String, lag: Double)]] = [:]
        var indegree: [Int: Int] = Dictionary(uniqueKeysWithValues: participantIds.map { ($0, 0) })
        for id in participantIds {
            guard let idx = indexById[id] else { continue }
            for link in tasks[idx].links where participantSet.contains(link.predecessorId) {
                successors[link.predecessorId, default: []].append((id, link.type, link.lagDays))
                indegree[id, default: 0] += 1
            }
        }

        // Kahn topological sort so the backward pass below can process every successor of a task
        // before the task itself. A real project file can't contain a predecessor cycle, but a
        // defensive fallback (append whatever's left, in original order) keeps this from looping
        // forever if one somehow exists rather than relying on that invariant.
        var order: [Int] = []
        var queue = participantIds.filter { indegree[$0] == 0 }
        var remaining = indegree
        while !queue.isEmpty {
            let id = queue.removeFirst()
            order.append(id)
            for (successorId, _, _) in successors[id] ?? [] {
                remaining[successorId, default: 0] -= 1
                if remaining[successorId] == 0 { queue.append(successorId) }
            }
        }
        if order.count != participantIds.count {
            let seen = Set(order)
            order.append(contentsOf: participantIds.filter { !seen.contains($0) })
        }

        guard let projectFinish = participantIds.compactMap({ indexById[$0] }).compactMap({ tasks[$0].finish }).max() else { return }

        var lateStart: [Int: Date] = [:]
        var lateFinish: [Int: Date] = [:]
        for id in order.reversed() {
            guard let idx = indexById[id] else { continue }
            let duration = tasks[idx].durationDays
            let succList = successors[id] ?? []
            let candidates: [Date]
            if succList.isEmpty {
                candidates = [projectFinish]
            } else {
                candidates = succList.compactMap { (successorId, type, lag) -> Date? in
                    guard let succLS = lateStart[successorId], let succLF = lateFinish[successorId] else { return nil }
                    switch type {
                    case "SS": // successor.start >= own.start + lag -> bounds own late start
                        return addDays(addDays(succLS, -lag), duration)
                    case "FF": // successor.finish >= own.finish + lag -> bounds own late finish directly
                        return addDays(succLF, -lag)
                    case "SF": // successor.finish >= own.start + lag -> bounds own late start
                        return addDays(addDays(succLF, -lag), duration)
                    default: // "FS": successor.start >= own.finish + lag -> bounds own late finish directly
                        return addDays(succLS, -lag)
                    }
                }
            }
            guard let lf = candidates.min() else { continue }
            lateFinish[id] = lf
            lateStart[id] = addDays(lf, -duration)
        }

        // A full day's rounding slack (addDays rounds to the nearest second) easily compounds
        // across a multi-hop chain; real float on calendar-day durations is effectively never this
        // small, so a generous tolerance avoids flagging a merely-adjacent task as critical.
        let toleranceSeconds: TimeInterval = 60
        for id in participantIds {
            guard let idx = indexById[id], let es = tasks[idx].start, let ls = lateStart[id] else { continue }
            tasks[idx].isCritical = ls.timeIntervalSince(es) <= toleranceSeconds
        }
        for i in tasks.indices where !participantSet.contains(tasks[i].id) {
            tasks[i].isCritical = false
        }

        // Summary rollup, per Microsoft Project's own convention (confirmed against a real file
        // during this feature's development): a summary task is critical only if every leaf task
        // nested under it is critical — its own computed float above is discarded in favor of this.
        var i = 0
        while i < tasks.count {
            guard tasks[i].isSummary else { i += 1; continue }
            let level = tasks[i].outlineLevel
            var j = i + 1
            var sawLeaf = false
            var allCritical = true
            while j < tasks.count && tasks[j].outlineLevel > level {
                if !tasks[j].isSummary {
                    sawLeaf = true
                    if !tasks[j].isCritical { allCritical = false }
                }
                j += 1
            }
            tasks[i].isCritical = sawLeaf && allCritical
            i += 1
        }
    }

    /// True if making `predecessorId` precede `taskId` would close a cycle given the *current*
    /// links (i.e. `taskId` can already reach `predecessorId` by following existing successor
    /// edges forward). A real project file can't contain cycles, but a UI that lets someone type an
    /// arbitrary predecessor reference can — and the forward-pass BFS above has no cycle guard of
    /// its own (each pass would keep pushing dates further out, looping forever), so this has to be
    /// checked before a new link is ever accepted, not discovered at recalculation time.
    static func wouldCreateCycle(addingPredecessor predecessorId: Int, to taskId: Int, in tasks: [GanttTask]) -> Bool {
        if predecessorId == taskId { return true }

        var successors: [Int: [Int]] = [:]
        for task in tasks {
            for link in task.links {
                successors[link.predecessorId, default: []].append(task.id)
            }
        }

        var visited = Set<Int>()
        var queue = [taskId]
        while let current = queue.first {
            queue.removeFirst()
            guard !visited.contains(current) else { continue }
            visited.insert(current)
            if current == predecessorId { return true }
            if let next = successors[current] {
                queue.append(contentsOf: next)
            }
        }
        return false
    }

    private static func predecessorsOf(_ taskId: Int, in tasks: [GanttTask], indexById: [Int: Int]) -> [(GanttTask, String, Double)] {
        guard let idx = indexById[taskId] else { return [] }
        return tasks[idx].links.compactMap { link in
            guard let predIdx = indexById[link.predecessorId] else { return nil }
            return (tasks[predIdx], link.type, link.lagDays)
        }
    }

    /// Applies every predecessor constraint to `task`, taking the latest resulting start.
    /// Returns true if the task's dates actually moved (so callers know whether to keep cascading).
    @discardableResult
    private static func applyConstraints(_ task: inout GanttTask, predecessors: [(GanttTask, String, Double)]) -> Bool {
        guard !predecessors.isEmpty else { return false }
        let oldStart = task.start
        let oldFinish = task.finish
        var earliestStart = task.start

        for (predecessor, type, lag) in predecessors {
            guard let predStart = predecessor.start, let predFinish = predecessor.finish else { continue }
            let candidate: Date
            switch type {
            case "SS":
                candidate = addDays(predStart, lag)
            case "FF":
                candidate = addDays(predFinish, lag - task.durationDays)
            case "SF":
                candidate = addDays(predStart, lag - task.durationDays)
            default: // "FS"
                candidate = addDays(predFinish, lag)
            }
            if earliestStart == nil || candidate > earliestStart! {
                earliestStart = candidate
            }
        }

        guard let newStart = earliestStart else { return false }
        task.start = newStart
        task.finish = addDays(newStart, task.durationDays)
        return task.start != oldStart || task.finish != oldFinish
    }

    private static func recomputeOwnFinish(_ task: inout GanttTask) {
        guard let start = task.start else { return }
        task.finish = addDays(start, task.durationDays)
    }

    static func addDays(_ date: Date, _ days: Double) -> Date {
        Calendar.ganttUTC.date(byAdding: .second, value: Int((days * 86400).rounded()), to: date) ?? date
    }
}
