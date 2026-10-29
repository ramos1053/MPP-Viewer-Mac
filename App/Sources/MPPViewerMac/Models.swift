import Foundation

// Mirrors the line-delimited JSON protocol spoken by the Helper (../Helper/Program.cs).

struct HelperRequest: Encodable {
    let id: Int
    let command: String
    let path: String?
    var tasks: [TaskDto]? = nil
    var resources: [ResourceDto]? = nil
    var budgetCost: Double? = nil
    /// Omitted (nil) on every save this app itself issues unless the user actually touched the
    /// Calendars view this session — Helper treats a missing `calendars` field as "leave calendars
    /// untouched," not "delete them all" (see Helper's Save), so there's no need to round-trip this
    /// on every save the way tasks/resources are. Set from AppModel.calendars once that view has
    /// been opened/edited.
    var calendars: [CalendarDto]? = nil
}

struct LinkDto: Codable {
    let predecessorUniqueId: Int
    let type: String
    let lagDays: Double
}

struct AssignmentDto: Codable {
    let resourceUniqueId: Int
    let units: Double
}

struct TaskDto: Codable {
    let id: Int
    let uniqueId: Int
    let outlineLevel: Int
    let wbs: String
    let name: String
    let duration: String
    let durationDays: Double
    let start: String?
    let finish: String?
    let percent: Double
    let links: [LinkDto]
    let assignments: [AssignmentDto]
    let notes: String
    let summary: Bool
    let milestone: Bool
    let critical: Bool
}

/// Unlike TaskDto/GanttTask, this doubles as both the wire DTO *and* AppModel's own stored,
/// editable view-model row — there's no derived/parsed representation to split out (no dates, no
/// WBS renumbering), so a second struct would just be a copy. `var` fields so AppModel's resource
/// mutation methods can edit in place the same way GanttTask's do.
struct ResourceDto: Codable, Identifiable, Equatable {
    let uniqueId: Int
    var name: String
    var type: String
    var initials: String
    var group: String
    /// Read-only in this app's UI — see Helper's ApplyResourceFields for why (backed by MPXJ's
    /// date-ranged AvailabilityTable, not a plain settable property).
    var maxUnits: Double
    /// Amount + unit, not a pre-formatted string — editable now (Helper writes a single flat
    /// CostRateTable entry spanning MPXJ's own "NA" date range; see ApplyResourceFields). Unit is one
    /// of MPXJ's TimeUnit names ("Hours", "Days", "Weeks", "Months", "Years") so it round-trips
    /// directly with no translation.
    var standardRateAmount: Double
    var standardRateUnit: String
    var overtimeRateAmount: Double
    var overtimeRateUnit: String
    var costPerUse: Double
    var accrueAt: String
    /// Read-only — this app has no calendar-management UI, so there's no way to guarantee a typed
    /// name here actually matches a calendar that exists in the file.
    var baseCalendar: String
    var code: String

    var id: Int { uniqueId }

    static func blank(uniqueId: Int) -> ResourceDto {
        ResourceDto(
            uniqueId: uniqueId, name: "New Resource", type: "Work", initials: "", group: "",
            maxUnits: 100, standardRateAmount: 0, standardRateUnit: "Hours",
            overtimeRateAmount: 0, overtimeRateUnit: "Hours", costPerUse: 0, accrueAt: "Prorated",
            baseCalendar: "", code: "")
    }
}

/// A whole-day calendar exception — a holiday (`working == false`, the common case) or a makeup
/// day (`working == true`, a day that would normally be off but is scheduled anyway). Dates are
/// "yyyy-MM-dd", no time component — see Helper's CalendarExceptionDto.
struct CalendarExceptionDto: Codable, Identifiable, Equatable {
    var name: String
    var fromDate: String
    var toDate: String
    var working: Bool

    var id: String { "\(fromDate)-\(toDate)-\(name)" }
}

/// Doubles as wire DTO and stored/editable row, same as ResourceDto — no derived representation to
/// split out. `workingDays` is always 7 entries, index 0 = Sunday...6 = Saturday (`WeekdaySymbol`
/// below maps that same convention to display labels).
struct CalendarDto: Codable, Identifiable, Equatable {
    let uniqueId: Int
    var name: String
    var isDefault: Bool
    var workingDays: [Bool]
    var exceptions: [CalendarExceptionDto]

    var id: Int { uniqueId }

    static let weekdaySymbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    static func blank(uniqueId: Int, name: String) -> CalendarDto {
        CalendarDto(
            uniqueId: uniqueId, name: name, isDefault: false,
            workingDays: [false, true, true, true, true, true, false], exceptions: [])
    }
}

struct OpenResult: Decodable {
    let title: String
    let tasks: [TaskDto]
    let resources: [ResourceDto]
    let budgetCost: Double
    let calendars: [CalendarDto]
}

struct HelperResponse: Decodable {
    let id: Int
    let ok: Bool
    let result: OpenResult?
    let error: String?
}
