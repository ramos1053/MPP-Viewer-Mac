import Foundation
import Testing
@testable import MPPViewerMac

struct SchedulerTests {
    @Test func increasingDurationPushesTheWholeFinishToStartChain() {
        // Deliberately use non-contiguous IDs and reverse array order.
        var tasks = [
            task(90, duration: 1, start: 5, links: [link(7)]),
            task(7, duration: 3, start: 2, links: [link(40)]),
            task(40, duration: 2),
        ]
        tasks[2].durationDays = 5

        Scheduler.recalculate(&tasks, from: 40)

        #expect(tasks[2].finish == date(5))
        #expect(tasks[1].start == date(5))
        #expect(tasks[1].finish == date(8))
        #expect(tasks[0].start == date(8))
        #expect(tasks[0].finish == date(9))
        #expect(tasks.allSatisfy { $0.isCritical })
    }

    @Test(arguments: [
        ("FS", 0.0, 14.0), ("FS", 2.0, 16.0), ("FS", -1.5, 12.5),
        ("SS", 0.0, 10.0), ("SS", 2.0, 12.0), ("SS", -1.5, 8.5),
        ("FF", 0.0, 11.0), ("FF", 2.0, 13.0), ("FF", -1.5, 9.5),
        ("SF", 0.0, 7.0), ("SF", 2.0, 9.0), ("SF", -1.5, 5.5),
    ])
    func dependencyConstraintsRespectLinkTypeAndLag(_ type: String, _ lag: Double, _ expectedStart: Double) {
        var tasks = [
            task(1, duration: 4, start: 10),
            task(2, duration: 3, links: [link(1, type: type, lag: lag)]),
        ]

        Scheduler.recalculate(&tasks, from: 1)

        #expect(tasks[1].start == date(expectedStart))
        #expect(tasks[1].finish == date(expectedStart + 3))
    }

    @Test func multiplePredecessorsUseTheLatestConstraint() {
        var tasks = [
            task(1, duration: 3),
            task(2, duration: 6),
            task(3, duration: 2, links: [link(1, lag: 2), link(2, type: "SS", lag: 4)]),
        ]

        Scheduler.recalculate(&tasks, from: 1)

        #expect(tasks[2].start == date(5))
        #expect(tasks[2].finish == date(7))
    }

    @Test func aLaterManualStartIsPreserved() {
        var tasks = [task(1, duration: 2), task(2, duration: 3, start: 10, links: [link(1)])]

        Scheduler.recalculate(&tasks, from: 1)

        #expect(tasks[1].start == date(10))
        #expect(tasks[1].finish == date(13))
    }

    @Test func editingPredecessorsRevisitsOwnConstraintsAndSuccessors() {
        var tasks = [
            task(1, duration: 2, start: 5),
            task(2, duration: 3, links: [link(1)]),
            task(3, duration: 1, links: [link(2)]),
        ]

        Scheduler.recalculate(&tasks, from: 2, revisitOwnConstraints: true)

        #expect(tasks[1].start == date(7))
        #expect(tasks[1].finish == date(10))
        #expect(tasks[2].start == date(10))
        #expect(tasks[2].finish == date(11))
    }

    @Test func criticalPathDistinguishesZeroFloatFromTheShorterBranch() {
        var tasks = diamond()
        tasks[2].isCritical = true // A stale flag from a file must be recomputed.

        Scheduler.recomputeCriticalPath(&tasks)

        #expect(tasks.map(\.isCritical) == [true, true, false, true])
    }

    @Test func consumingTheShorterBranchesFloatMakesItCritical() {
        var tasks = diamond()
        Scheduler.recomputeCriticalPath(&tasks)
        #expect(!tasks[2].isCritical)

        // The short branch has two calendar days of float.
        tasks[2].durationDays = 4
        Scheduler.recalculate(&tasks, from: 3)

        #expect(tasks[2].finish == date(6))
        #expect(tasks[3].start == date(6))
        #expect(tasks.map(\.isCritical) == [true, true, true, true])
    }

    @Test(arguments: [
        ("SS", 1.0, 2.0, 4.0),
        ("FF", 1.0, 1.0, 4.0),
        ("SF", 1.0, 1.0, 3.0),
    ])
    func backwardPassUsesTheLinkType(_ type: String, _ lag: Double, _ successorStart: Double, _ successorDuration: Double) {
        var tasks = [
            task(1, duration: 2),
            task(2, duration: successorDuration, start: successorStart, links: [link(1, type: type, lag: lag)]),
        ]

        Scheduler.recomputeCriticalPath(&tasks)

        #expect(!tasks[0].isCritical)
        #expect(tasks[1].isCritical)
    }

    @Test func newProjectSchedulesBlankTasksWithoutLoadingAFile() {
        var tasks: [GanttTask] = []
        Scheduler.recomputeCriticalPath(&tasks)
        #expect(tasks.isEmpty)

        tasks.append(.blank(id: 1, outlineLevel: 1, start: date(0), finish: date(1)))
        Scheduler.recalculate(&tasks, from: 1)
        #expect(tasks[0].isCritical)

        var next = GanttTask.blank(id: 2, outlineLevel: 1, start: date(1), finish: date(2))
        next.links = [link(1)]
        tasks.append(next)
        tasks[0].durationDays = 2
        Scheduler.recalculate(&tasks, from: 1)

        #expect(tasks[0].finish == date(2))
        #expect(tasks[1].start == date(2))
        #expect(tasks[1].finish == date(3))
        #expect(tasks.allSatisfy { $0.isCritical })
    }

    @Test(arguments: [false, true])
    func undatedTasksLoseStaleCriticalFlags(_ includeDatedTask: Bool) {
        var undated = GanttTask.blank(id: 1, outlineLevel: 1, start: nil, finish: nil)
        undated.isCritical = true
        var tasks = [undated]
        if includeDatedTask { tasks.append(task(2, duration: 2)) }

        Scheduler.recomputeCriticalPath(&tasks)

        #expect(!tasks[0].isCritical)
        if includeDatedTask { #expect(tasks[1].isCritical) }
    }

    @Test func anUnknownChangedIDLeavesTasksUntouched() {
        var tasks = [task(1, duration: 2), task(2, duration: 3, start: 2, links: [link(1)])]
        let original = tasks

        Scheduler.recalculate(&tasks, from: 999)

        #expect(tasks == original)
    }

    private func diamond() -> [GanttTask] {
        [
            task(1, duration: 2),
            task(2, duration: 4, start: 2, links: [link(1)]),
            task(3, duration: 2, start: 2, links: [link(1)]),
            task(4, duration: 1, start: 6, links: [link(2), link(3)]),
        ]
    }

    private func task(_ id: Int, duration: Double, start: Double = 0, links: [GanttLink] = []) -> GanttTask {
        var task = GanttTask.blank(id: id, outlineLevel: 1, start: date(start), finish: date(start + duration))
        task.durationDays = duration
        task.links = links
        return task
    }

    private func link(_ predecessor: Int, type: String = "FS", lag: Double = 0) -> GanttLink {
        GanttLink(predecessorId: predecessor, type: type, lagDays: lag)
    }

    private func date(_ day: Double) -> Date {
        // Expected dates use elapsed UTC days, independently of Scheduler.addDays.
        Date(timeIntervalSince1970: 1_767_225_600 + day * 86_400)
    }
}
