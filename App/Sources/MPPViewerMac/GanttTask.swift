import Foundation

struct GanttLink: Equatable {
    let predecessorId: Int
    var type: String // "FS", "SS", "FF", "SF"
    var lagDays: Double
}

struct TaskAssignment: Equatable {
    let resourceId: Int
    var units: Double // percent, 100 = full-time
}

/// View-model row over a TaskDto: parses the helper's date strings once, up front.
/// Mutable (`var`) so edits can be applied in place by AppModel/Scheduler; GanttTask itself has no
/// editing logic — see AppModel's mutation methods and Scheduler.recalculate.
struct GanttTask: Identifiable, Equatable {
    let id: Int
    let outlineLevel: Int
    var wbs: String
    var name: String
    var durationDays: Double
    var start: Date?
    var finish: Date?
    var percent: Double
    var links: [GanttLink]
    var assignments: [TaskAssignment]
    /// Cached display text ("Juan Pérez[50%]; María López"), kept in sync by AppModel whenever
    /// `assignments` or the resource list itself changes — can't be a computed property like
    /// `durationText` since it depends on other tasks' data (resource names), not just this task's
    /// own fields. See AppModel.resourceNamesText.
    var resourceNames: String
    var notes: String
    let isSummary: Bool
    let isMilestone: Bool
    var isCritical: Bool

    var durationText: String {
        durationDays == 1 ? "1 day" : "\(Self.trimmed(durationDays)) days"
    }

    private static func trimmed(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    init(_ dto: TaskDto) {
        self.init(
            id: dto.uniqueId, outlineLevel: dto.outlineLevel, wbs: dto.wbs, name: dto.name,
            durationDays: dto.durationDays, start: Self.parseDate(dto.start), finish: Self.parseDate(dto.finish),
            percent: dto.percent,
            links: dto.links.map { GanttLink(predecessorId: $0.predecessorUniqueId, type: $0.type, lagDays: $0.lagDays) },
            assignments: dto.assignments.map { TaskAssignment(resourceId: $0.resourceUniqueId, units: $0.units) },
            resourceNames: "", notes: dto.notes, isSummary: dto.summary, isMilestone: dto.milestone,
            isCritical: dto.critical)
    }

    init(
        id: Int, outlineLevel: Int, wbs: String, name: String, durationDays: Double,
        start: Date?, finish: Date?, percent: Double, links: [GanttLink], assignments: [TaskAssignment],
        resourceNames: String, notes: String, isSummary: Bool, isMilestone: Bool, isCritical: Bool
    ) {
        self.id = id
        self.outlineLevel = outlineLevel
        self.wbs = wbs
        self.name = name
        self.durationDays = durationDays
        self.start = start
        self.finish = finish
        self.percent = percent
        self.links = links
        self.assignments = assignments
        self.resourceNames = resourceNames
        self.notes = notes
        self.isSummary = isSummary
        self.isMilestone = isMilestone
        self.isCritical = isCritical
    }

    /// A freshly inserted task: default name/duration the caller lets the user edit afterward, no
    /// predecessors, and a placeholder WBS — insertTask in AppModel recomputes WBS across the whole
    /// list right after inserting, since adding a sibling shifts every WBS number that follows it.
    static func blank(id: Int, outlineLevel: Int, start: Date?, finish: Date?) -> GanttTask {
        GanttTask(
            id: id, outlineLevel: outlineLevel, wbs: "", name: "New Task", durationDays: 1,
            start: start, finish: finish, percent: 0, links: [], assignments: [], resourceNames: "", notes: "",
            isSummary: false, isMilestone: false, isCritical: false)
    }

    // The helper writes dates as DateTime.ToString("s") — "yyyy-MM-dd'T'HH:mm:ss", local wall-clock time, no offset.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return formatter.date(from: string)
    }

    /// Reverses `init(_ dto:)` for Save — the Helper applies these fields onto the live MPXJ task it
    /// already has in memory (matched by `uniqueId`). `duration`/`summary`/`milestone`/`critical` are
    /// carried along for the DTO's sake but aren't read back by the Helper's save path; `notes` is.
    func toDto() -> TaskDto {
        TaskDto(
            id: id, uniqueId: id, outlineLevel: outlineLevel, wbs: wbs, name: name,
            duration: durationText, durationDays: durationDays,
            start: start.map(Self.formatter.string(from:)), finish: finish.map(Self.formatter.string(from:)),
            percent: percent,
            links: links.map { LinkDto(predecessorUniqueId: $0.predecessorId, type: $0.type, lagDays: $0.lagDays) },
            assignments: assignments.map { AssignmentDto(resourceUniqueId: $0.resourceId, units: $0.units) },
            notes: notes, summary: isSummary, milestone: isMilestone, critical: isCritical)
    }
}

extension Calendar {
    /// Task dates are parsed as wall-clock-as-UTC (see GanttTask.formatter); all date arithmetic
    /// on them must use this same UTC calendar or day counts will drift by a timezone offset.
    static let ganttUTC: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
