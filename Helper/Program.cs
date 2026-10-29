using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using MPXJ.Net;
using Task = MPXJ.Net.Task;

namespace MppHelper;

// Line-delimited JSON over stdin/stdout. One request per line in, one response per line out.
// Nothing else may be written to stdout; diagnostics go to stderr.

internal sealed record Request(int Id, string Command, string? Path, string? Title, List<TaskDto>? Tasks, List<ResourceDto>? Resources, double? BudgetCost, List<CalendarDto>? Calendars);

internal sealed record LinkDto(int PredecessorUniqueId, string Type, double LagDays);

internal sealed record AssignmentDto(int ResourceUniqueId, double Units);

internal sealed record TaskDto(
    int Id,
    int UniqueId,
    int OutlineLevel,
    string Wbs,
    string Name,
    string Duration,
    double DurationDays,
    string? Start,
    string? Finish,
    double Percent,
    List<LinkDto> Links,
    List<AssignmentDto> Assignments,
    string Notes,
    bool Summary,
    bool Milestone,
    bool Critical);

internal sealed record ResourceDto(
    int UniqueId,
    string Name,
    string Type,
    string Initials,
    string Group,
    double MaxUnits,
    double StandardRateAmount,
    string StandardRateUnit,
    double OvertimeRateAmount,
    string OvertimeRateUnit,
    double CostPerUse,
    string AccrueAt,
    string BaseCalendar,
    string Code);

/// A whole-day calendar exception — a holiday or other one-off override of the calendar's normal
/// weekly pattern. `FromDate`/`ToDate` are "yyyy-MM-dd" (no time component; exceptions are always
/// whole days). `Working=false` is the common case (a holiday); `true` means "working despite
/// falling on an otherwise non-working day" (a makeup day), also real and also supported.
internal sealed record CalendarExceptionDto(string Name, string FromDate, string ToDate, bool Working);

/// `WorkingDays` is always exactly 7 entries, index 0=Sunday...6=Saturday (`System.DayOfWeek`'s own
/// ordering) — simpler than per-day custom hour ranges, which this app doesn't expose; a working
/// day is always the same standard 8-hour day (see ApplyCalendarFields), matching the flat-rate/
/// flat-availability simplification already used for resource cost/availability editing.
internal sealed record CalendarDto(int UniqueId, string Name, bool IsDefault, List<bool> WorkingDays, List<CalendarExceptionDto> Exceptions);

internal sealed record OpenResult(string Title, List<TaskDto> Tasks, List<ResourceDto> Resources, double BudgetCost, List<CalendarDto> Calendars);

internal sealed record Response(int Id, bool Ok, OpenResult? Result, string? Error);

internal static class Program
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    /// <summary>
    /// The project from the last "open", kept alive across requests so "save" can mutate the same
    /// live MPXJ object graph rather than rebuild one from the DTOs — that's what lets an edit touch
    /// only the tasks it actually changed and leave everything else (calendars, resources, custom
    /// fields, baselines, ...) exactly as the source file had it.
    /// </summary>
    private static ProjectFile? _currentProject;

    private static int Main()
    {
        string? line;
        while ((line = Console.In.ReadLine()) != null)
        {
            if (line.Length == 0) continue;

            Request? request;
            try
            {
                request = JsonSerializer.Deserialize<Request>(line, JsonOptions);
            }
            catch (JsonException ex)
            {
                Respond(new Response(0, false, null, $"Bad request: {ex.Message}"));
                continue;
            }

            if (request is null) continue;

            if (request.Command == "exit") return 0;

            Handle(request);
        }

        return 0;
    }

    private static void Handle(Request request)
    {
        try
        {
            switch (request.Command)
            {
                case "open":
                    Respond(new Response(request.Id, true, Open(request.Path), null));
                    break;
                case "new":
                    Respond(new Response(request.Id, true, New(), null));
                    break;
                case "save":
                    Save(request.Path, request.Title, request.Tasks, request.Resources, request.BudgetCost, request.Calendars);
                    Respond(new Response(request.Id, true, null, null));
                    break;
                default:
                    Respond(new Response(request.Id, false, null, $"Unknown command: {request.Command}"));
                    break;
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            Respond(new Response(request.Id, false, null, ex.Message));
        }
    }

    private static OpenResult Open(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
            throw new ArgumentException("Missing path.");

        var project = new UniversalProjectReader().Read(path)
            ?? throw new InvalidDataException("Unrecognized file format.");
        _currentProject = project;

        var assignments = project.ResourceAssignments
            .Where(a => a.Task?.UniqueID != null && a.Resource?.UniqueID != null && !string.IsNullOrWhiteSpace(a.Resource.Name))
            .GroupBy(a => a.Task!.UniqueID!.Value)
            .ToDictionary(
                g => g.Key,
                g => g.Select(a => new AssignmentDto(a.Resource!.UniqueID!.Value, a.Units ?? 100)).ToList());

        var tasks = project.Tasks
            // OutlineLevel 0 (equivalently UniqueID 0) is MPXJ's synthetic Project Summary Task —
            // a rollup of the whole project, not a real task. Showing/editing/deleting it makes no
            // sense, and its outline level 0 (below every real top-level task's level 1) would throw
            // off WBS numbering if it were ever treated as a normal row.
            .Where(t => t.OutlineLevel != 0)
            .Select(t => ToDto(t, assignments.GetValueOrDefault(t.UniqueID ?? -1, new List<AssignmentDto>())))
            .ToList();

        var title = project.ProjectProperties.ProjectTitle;
        if (string.IsNullOrWhiteSpace(title))
            title = System.IO.Path.GetFileNameWithoutExtension(path);

        return new OpenResult(title, tasks, Resources(project), BudgetCostFor(project), Calendars(project));
    }

    private static readonly DayOfWeek[] WeekOrder =
    {
        DayOfWeek.Sunday, DayOfWeek.Monday, DayOfWeek.Tuesday, DayOfWeek.Wednesday,
        DayOfWeek.Thursday, DayOfWeek.Friday, DayOfWeek.Saturday,
    };

    private static List<CalendarDto> Calendars(ProjectFile project) =>
        project.Calendars.Select(ToCalendarDto).ToList();

    private static CalendarDto ToCalendarDto(ProjectCalendar cal) => new(
        UniqueId: cal.UniqueID ?? 0,
        Name: cal.Name ?? "",
        IsDefault: cal.Default,
        WorkingDays: WeekOrder.Select(cal.IsWorkingDay).ToList(),
        Exceptions: cal.CalendarExceptions.Select(ex => new CalendarExceptionDto(
            Name: ex.Name ?? "",
            FromDate: ex.FromDate?.ToString("yyyy-MM-dd") ?? "",
            ToDate: ex.ToDate?.ToString("yyyy-MM-dd") ?? "",
            Working: ex.Working)).ToList());

    /// <summary>
    /// MS Project's real "project budget" mechanism: a Resource with its Budget flag set, assigned
    /// to the Project Summary Task (OutlineLevel 0), with the budget amount living on that one
    /// ResourceAssignment's BudgetCost field — not a plain settable field on the task or project
    /// properties (confirmed by testing: writing directly to Task.BudgetCost silently doesn't survive
    /// a save/reopen round trip, since it's a rollup the writer recomputes, not stored data). The
    /// budget resource itself is never sent to the app as an ordinary ResourceDto — same "exists in
    /// the file, but synthetic/not user-editable as a normal row" treatment as the Project Summary
    /// Task itself or a blank-name resource (see Resources()).
    /// </summary>
    private static double BudgetCostFor(ProjectFile project) =>
        project.ResourceAssignments
            .FirstOrDefault(a => a.Resource?.Budget == true && a.Task?.OutlineLevel == 0)
            ?.BudgetCost ?? 0;

    /// <summary>
    /// Starts a brand-new, empty in-memory project — same role as Open, but with nothing read from
    /// disk. The Swift side seeds its own single starter task locally after this; the Helper doesn't
    /// need to know about it until the first Save, whose existing create-if-missing logic (see Save)
    /// already handles "this UniqueID has no matching MPXJ task yet" uniformly, new project or not.
    /// </summary>
    private static OpenResult New()
    {
        var project = new ProjectFile();
        project.ProjectProperties.ProjectTitle = "Untitled Project";
        _currentProject = project;
        return new OpenResult("Untitled Project", new List<TaskDto>(), new List<ResourceDto>(), 0, Calendars(project));
    }

    /// <summary>
    /// Resources with a blank name are a real but useless row to show (an unused pool slot, or —
    /// same convention as the Project Summary Task — a synthetic unique-ID-0 placeholder some files
    /// carry); filtering on the name rather than unique ID is deliberate, since (unlike tasks) a
    /// resource's unique ID 0 doesn't reliably mean "synthetic" across files.
    /// </summary>
    private static List<ResourceDto> Resources(ProjectFile project) =>
        project.Resources
            .Where(r => !string.IsNullOrWhiteSpace(r.Name) && r.Budget != true)
            .Select(ToResourceDto)
            .ToList();

    /// MS Project (and MPXJ's Resource.Type) only ever has these four real categories — there's no
    /// native fifth "custom" one. A resource whose Text1 custom field is non-blank is understood as
    /// "the user typed a custom type" (see ApplyResourceFields): Text1 holds their label verbatim and
    /// is what's shown/edited as Type instead of the enum name, while Type itself still holds a real
    /// (Work) value underneath so every other MPXJ-aware consumer of the file still sees something
    /// sane there.
    private static readonly string[] KnownResourceTypes = { "Work", "Material", "Cost", "NonLabor" };

    private static ResourceDto ToResourceDto(Resource r)
    {
        var (stdAmount, stdUnit) = RateParts(r.StandardRate);
        var (ovtAmount, ovtUnit) = RateParts(r.OvertimeRate);
        var customType = r.GetText(1);
        return new(
            UniqueId: r.UniqueID ?? 0,
            Name: r.Name ?? "",
            Type: !string.IsNullOrWhiteSpace(customType) ? customType : r.Type?.ToString() ?? "",
            Initials: r.Initials ?? "",
            Group: r.Group ?? "",
            MaxUnits: r.MaxUnits ?? 0,
            StandardRateAmount: stdAmount,
            StandardRateUnit: stdUnit,
            OvertimeRateAmount: ovtAmount,
            OvertimeRateUnit: ovtUnit,
            CostPerUse: r.CostPerUse ?? 0,
            AccrueAt: r.AccrueAt?.ToString() ?? "",
            BaseCalendar: r.BaseCalendar ?? "",
            Code: r.Code ?? "");
    }

    private static (double amount, string unit) RateParts(Rate? rate) =>
        rate is null ? (0, "Hours") : (rate.Amount, rate.Units?.ToString() ?? "Hours");

    /// <summary>
    /// Applies the Swift side's current (possibly edited) task list onto the live project from the
    /// last "open" and writes it out as Project XML (MSPDI) — the one format MPXJ.Net can reliably
    /// write back out regardless of what format the file was originally opened from.
    /// </summary>
    /// <remarks>
    /// Strategy: match every incoming task to its MPXJ Task by UniqueID. Existing tasks just get
    /// their editable fields overwritten in place — everything this app never exposed (calendars,
    /// constraints, custom fields, baselines, ...) is simply never touched, so it survives untouched.
    /// A UniqueID with no match is a task this app created (Add Task); a UniqueID that existed before
    /// but is missing now was deleted (Delete Task) and its MPXJ Task is removed. New tasks are
    /// inserted at the position implied by their neighbors in the incoming (already fully-ordered)
    /// list, in both the project's flat task list and their parent's child list, since AddTask()/
    /// Tasks.Add() only ever appends.
    /// </remarks>
    private static void Save(string? path, string? title, List<TaskDto>? tasks, List<ResourceDto>? resources, double? budgetCost, List<CalendarDto>? calendars)
    {
        if (string.IsNullOrWhiteSpace(path))
            throw new ArgumentException("Missing path.");
        if (tasks is null)
            throw new ArgumentException("Missing tasks.");
        resources ??= new List<ResourceDto>();
        var project = _currentProject
            ?? throw new InvalidOperationException("No project is open.");
        if (!string.IsNullOrWhiteSpace(title))
        {
            var props = project.ProjectProperties;
            props.ProjectTitle = title;
            // An explicit title means the caller is establishing this project's identity fresh
            // (e.g. replacing another file's content wholesale) — clear every other identity field
            // MPXJ carries over from whatever file was last opened (Author/LastAuthor/Manager/
            // Company/...), since none of them describe the new content and leaving them is how a
            // prior real author's name ends up baked into an unrelated saved file (confirmed: this
            // exact leak happened once already, see progress notes). The real app's own Save never
            // passes a title, so none of this touches normal user behavior.
            props.Author = "";
            props.LastAuthor = "";
            props.Manager = "";
            props.Company = "";
            props.Subject = "";
            props.Keywords = "";
            props.Comments = "";
            props.Category = "";
            props.CreationDate = DateTime.Now;
            props.Revision = 1;
        }

        // Every assignment and relation is torn down before anything else, including before deleting
        // tasks/resources: removing a task or resource that still has an assignment or relation
        // pointing at or from it crashes inside MPXJ's own bookkeeping. Tearing the whole graph down
        // first, while every task/resource still exists, sidesteps that — both are rebuilt from the
        // incoming DTOs afterward regardless, so nothing is lost by clearing early.
        foreach (var assignment in project.ResourceAssignments.ToList())
            assignment.Remove();

        foreach (var existing in project.Tasks.ToList())
        {
            if (existing.OutlineLevel == 0) continue; // the Project Summary Task; see Open
            foreach (var relation in existing.Predecessors.ToList())
                existing.Predecessors.Remove(relation);
        }

        var incomingIds = tasks.Select(t => t.UniqueId).ToHashSet();
        foreach (var existing in project.Tasks.ToList())
        {
            if (existing.OutlineLevel == 0) continue; // never sent to the app; never "deleted"
            if (!incomingIds.Contains(existing.UniqueID ?? -1))
                existing.Remove();
        }

        // Same create/update/delete-by-UniqueID strategy as tasks below. A resource with a blank name
        // is never sent to the app (see Resources()), so it's never in the incoming set either — guard
        // on the name, not just membership, or every blank-name placeholder would look "deleted" and
        // get removed on every save.
        var incomingResourceIds = resources.Select(r => r.UniqueId).ToHashSet();
        foreach (var existing in project.Resources.ToList())
        {
            if (string.IsNullOrWhiteSpace(existing.Name)) continue;
            if (existing.Budget == true) continue; // the budget resource; see BudgetCostFor/SetBudgetCost
            if (!incomingResourceIds.Contains(existing.UniqueID ?? -1))
                existing.Remove();
        }
        foreach (var dto in resources)
        {
            var resource = project.GetResourceByUniqueID(dto.UniqueId);
            if (resource is null)
            {
                resource = project.Resources.Add();
                resource.UniqueID = dto.UniqueId;
            }
            ApplyResourceFields(project, resource, dto);
        }
        project.Resources.RenumberIDs();

        // Calendars are optional on Save (unlike tasks/resources) — omitted (null) means "this
        // caller doesn't know about calendars, leave them untouched," not "delete every calendar,"
        // since an old caller sending no calendars field at all must not wipe out a file's working-
        // time setup. Only sync when the caller actually sent a list.
        if (calendars is not null)
            SyncCalendars(project, calendars);

        // previousByLevel[level] = the most recently processed MPXJ task at that outline level —
        // i.e. the current last child of whichever parent is active at that level. Used to find
        // both a new task's parent (previousByLevel[level - 1]) and where among its siblings it goes.
        var previousByLevel = new Dictionary<int, Task>();
        Task? previousOverall = null;

        foreach (var dto in tasks)
        {
            var mpxjTask = project.GetTaskByUniqueID(dto.UniqueId);
            if (mpxjTask is null)
            {
                previousByLevel.TryGetValue(dto.OutlineLevel - 1, out var parent);
                mpxjTask = parent is not null ? parent.AddTask() : project.Tasks.Add();
                mpxjTask.UniqueID = dto.UniqueId;

                // AddTask()/Tasks.Add() only ever append; reposition to where this task actually
                // belongs now that we know its real neighbors.
                InsertAfter(project.Tasks, mpxjTask, previousOverall);
                if (parent is not null)
                    InsertAfter(parent.ChildTasks, mpxjTask, previousByLevel.GetValueOrDefault(dto.OutlineLevel));
            }

            ApplyFields(mpxjTask, dto);

            previousByLevel[dto.OutlineLevel] = mpxjTask;
            previousOverall = mpxjTask;
        }

        // Second pass, once every task (and resource) in the incoming lists is guaranteed to exist:
        // relation/assignment endpoints can be anywhere in the list relative to each other, so both
        // are only safe to wire up after the loops above have created every task and resource. Both
        // were already cleared above, so this just rebuilds them fresh from the DTOs.
        foreach (var dto in tasks)
        {
            var mpxjTask = project.GetTaskByUniqueID(dto.UniqueId)!;
            foreach (var link in dto.Links)
            {
                var predecessor = project.GetTaskByUniqueID(link.PredecessorUniqueId);
                if (predecessor is null) continue; // dangling reference; nothing sensible to write
                mpxjTask.AddPredecessor(new Relation.Builder(project)
                    .PredecessorTask(predecessor)
                    .Type(RelationTypeFor(link.Type))
                    .Lag(Duration.GetInstance(link.LagDays, TimeUnit.Days)));
            }
            foreach (var assignment in dto.Assignments)
            {
                var resource = project.GetResourceByUniqueID(assignment.ResourceUniqueId);
                if (resource is null) continue; // dangling reference; nothing sensible to write
                mpxjTask.AddResourceAssignment(resource).Units = assignment.Units;
            }
        }

        // A task created above via AddTask()/Tasks.Add() has UniqueID set (to match the Swift side)
        // but no ID (the sequential row-number field, distinct from UniqueID) — MSPDIWriter sorts by
        // ID internally and a null there crashes that sort, so every task needs one before writing.
        project.Tasks.RenumberIDs();
        project.UpdateStructure();
        // After the task loop above, not before: on a brand-new project's very first save the
        // Project Summary Task this needs (OutlineLevel 0) doesn't exist until at least one real
        // task has been created, which only just happened. Can create a brand-new budget Resource,
        // so Resources needs another RenumberIDs() pass too — the one earlier in this method ran
        // before this resource could have existed.
        SetBudgetCost(project, budgetCost);
        project.Resources.RenumberIDs();
        new MSPDIWriter().Write(project, path);
    }

    /// <summary>
    /// Rebuilds the budget resource's assignment to the Project Summary Task fresh — like relations
    /// and regular assignments, it was already torn down wholesale at the top of Save (every
    /// ResourceAssignment is cleared there, budget resource's included). A `budgetCost` of 0 with no
    /// existing budget resource is a no-op (nothing to set up for an unused feature); a 0 with an
    /// existing budget resource still writes the assignment, so clearing a previously-set budget back
    /// to zero is reflected in the file rather than silently leaving the old value behind.
    /// </summary>
    private static void SetBudgetCost(ProjectFile project, double? budgetCost)
    {
        var amount = budgetCost ?? 0;
        var summary = project.Tasks.FirstOrDefault(t => t.OutlineLevel == 0);
        if (summary is null) return; // no project structure yet to attach a budget to

        var budgetResource = project.Resources.FirstOrDefault(r => r.Budget == true);
        if (amount == 0 && budgetResource is null) return;

        if (budgetResource is null)
        {
            // Unlike the main resource-sync loop's creations, Resources.Add() here leaves UniqueID
            // unset — and an unset UniqueID breaks the Resource<->ResourceAssignment linkage this
            // same method immediately relies on below (the assignment's own `.Resource` navigation
            // silently resolves to nothing until some later renumbering pass gives the resource a
            // real ID). Assigning one explicitly, the same way the main loop already does, avoids
            // that: confirmed by testing — the budget was silently lost on a project's very first
            // save without this, and only "fixed itself" on the next save once a reopen had given
            // the resource a real ID.
            budgetResource = project.Resources.Add();
            budgetResource.UniqueID = project.Resources.Select(r => r.UniqueID ?? 0).DefaultIfEmpty(0).Max() + 1;
            budgetResource.Name = "Project Budget";
            budgetResource.Budget = true;
        }

        summary.AddResourceAssignment(budgetResource).BudgetCost = amount;
    }

    private static void ApplyFields(Task task, TaskDto dto)
    {
        task.Name = dto.Name;
        task.WBS = dto.Wbs;
        task.PercentageComplete = dto.Percent;
        task.Duration = Duration.GetInstance(dto.DurationDays, TimeUnit.Days);
        task.Start = ParseDate(dto.Start);
        task.Finish = ParseDate(dto.Finish);
        task.Notes = dto.Notes;
        task.Milestone = dto.Milestone;
        task.Critical = dto.Critical;
    }

    /// <summary>
    /// MPXJ's own "always in effect" date range for a resource's cost rate table / availability
    /// table entry when there's genuinely just one flat rate/availability for the whole project, not
    /// a real date-phased schedule of changes — this app only edits a single flat value per resource,
    /// so every entry it writes spans this same "NA" range. Matches exactly what MPXJ itself writes
    /// for a resource that was never given a phased rate (confirmed by reading real files: every
    /// resource's existing table already uses exactly this 1984–2049 range).
    /// </summary>
    private static readonly DateTime NaStart = new(1984, 1, 1);
    private static readonly DateTime NaEnd = new(2049, 12, 31, 23, 59, 0);

    /// <summary>
    /// BaseCalendar is deliberately still left untouched here — settable on Resource, but this app
    /// has no calendar-management UI to guarantee the name it's set to actually matches a calendar
    /// that exists in the file.
    /// </summary>
    private static void ApplyResourceFields(ProjectFile project, Resource resource, ResourceDto dto)
    {
        resource.Name = dto.Name;
        if (KnownResourceTypes.Contains(dto.Type, StringComparer.OrdinalIgnoreCase))
        {
            resource.Type = ResourceTypeFor(dto.Type);
            resource.SetText(1, "");
        }
        else
        {
            // A custom type the user typed instead of picking one of the four real categories (see
            // KnownResourceTypes) — Type itself still needs a real value, Work is as good a default
            // as any; the actual label lives in Text1 and is what ToResourceDto shows back instead.
            resource.Type = ResourceType.Work;
            resource.SetText(1, dto.Type);
        }
        resource.Initials = dto.Initials;
        resource.Group = dto.Group;
        resource.Code = dto.Code;
        resource.AccrueAt = AccrueTypeFor(dto.AccrueAt);

        // MaxUnits/StandardRate/OvertimeRate/CostPerUse aren't plain settable properties — MPXJ backs
        // them with a date-ranged AvailabilityTable/CostRateTable (a resource can in principle have
        // different rates over different periods). This app only ever edits a single flat value, so
        // each write clears the table and replaces it with one NA-range entry — same shape MPXJ's own
        // writer already produces for a resource with no phased rate history, confirmed round-tripping
        // correctly through a real save+reopen.
        resource.Availability.Clear();
        resource.Availability.Add(new Availability(NaStart, NaEnd, dto.MaxUnits));

        var costRateTable = resource.GetCostRateTable(0);
        costRateTable.Clear();
        costRateTable.Add(new CostRateTableEntry(
            project, NaStart, NaEnd, dto.CostPerUse,
            new[]
            {
                new Rate(dto.StandardRateAmount, RateUnitFor(dto.StandardRateUnit)),
                new Rate(dto.OvertimeRateAmount, RateUnitFor(dto.OvertimeRateUnit)),
            }));
    }

    /// Same create/update/delete-by-UniqueID shape as Resources/Tasks, with one difference: a
    /// calendar still referenced by a task, a resource, or a derived calendar is skipped rather than
    /// removed — MPXJ's own bookkeeping doesn't tolerate deleting one out from under something that
    /// points at it (the same class of crash the top-of-Save teardown exists to avoid for tasks'
    /// relations/assignments), and this app has no UI yet for reassigning a task/resource to a
    /// different calendar first, so "silently keep it" is the only safe option here, not "crash" or
    /// "silently corrupt the file."
    private static void SyncCalendars(ProjectFile project, List<CalendarDto> calendars)
    {
        var incomingIds = calendars.Select(c => c.UniqueId).ToHashSet();
        foreach (var existing in project.Calendars.ToList())
        {
            if (incomingIds.Contains(existing.UniqueID ?? -1)) continue;
            if (existing.ResourceCount > 0 || existing.Tasks.Count > 0 || existing.DerivedCalendars.Count > 0) continue;
            existing.Remove();
        }

        foreach (var dto in calendars)
        {
            var calendar = project.Calendars.FirstOrDefault(c => c.UniqueID == dto.UniqueId);
            var isNew = calendar is null;
            if (calendar is null)
            {
                calendar = project.Calendars.Add();
                calendar.UniqueID = dto.UniqueId;
            }
            ApplyCalendarFields(calendar, dto, isNew);
        }
    }

    private static void ApplyCalendarFields(ProjectCalendar calendar, CalendarDto dto, bool isNew)
    {
        calendar.Name = dto.Name;
        if (isNew)
        {
            // A calendar created via AddTask()-style `Calendars.Add()` starts with no days/hours
            // template at all — every day reports NonWorking and SetWorkingDay(day, true) below has
            // no default hour range to fall back on without this, confirmed by testing.
            calendar.AddDefaultCalendarDays();
            calendar.AddDefaultCalendarHours();
        }
        for (var i = 0; i < WeekOrder.Length && i < dto.WorkingDays.Count; i++)
            calendar.SetWorkingDay(WeekOrder[i], dto.WorkingDays[i]);

        // Exceptions have no stable identity of their own to match incrementally against (unlike
        // tasks/resources' UniqueID) — same tear-down-and-rebuild-fresh approach already used for
        // relations and assignments elsewhere in Save.
        calendar.ClearCalendarExceptions();
        foreach (var ex in dto.Exceptions)
        {
            if (!DateOnly.TryParse(ex.FromDate, out var from) || !DateOnly.TryParse(ex.ToDate, out var to)) continue;
            var exception = calendar.AddCalendarException(from, to);
            exception.Name = ex.Name;
            // ProjectCalendarException.Working has no public setter (confirmed by reflection) —
            // it's derived from whether the exception carries any time ranges at all.
            // AddCalendarException starts with none (Working=false, a holiday); a "working"
            // exception (a makeup day) needs one added, same flat standard-hours convention
            // every other working day on this calendar uses.
            if (ex.Working)
                exception.Add(new TimeOnlyRange(new TimeOnly(8, 0), new TimeOnly(17, 0)));
        }
    }

    private static ResourceType? ResourceTypeFor(string type) =>
        Enum.TryParse<ResourceType>(type, ignoreCase: true, out var parsed) ? parsed : ResourceType.Work;

    private static AccrueType? AccrueTypeFor(string accrueAt) =>
        Enum.TryParse<AccrueType>(accrueAt, ignoreCase: true, out var parsed) ? parsed : AccrueType.Prorated;

    private static TimeUnit RateUnitFor(string unit) =>
        Enum.TryParse<TimeUnit>(unit, ignoreCase: true, out var parsed) ? parsed : TimeUnit.Hours;

    /// <summary>Removes `item` from `list` if present, then reinserts it right after `after` (or at
    /// index 0 if `after` is null/absent) — used to place a newly-created task among its real
    /// neighbors after AddTask()/Tasks.Add() appended it at the end.</summary>
    private static void InsertAfter(IList<Task> list, Task item, Task? after)
    {
        list.Remove(item);
        var index = after is not null ? list.IndexOf(after) + 1 : 0;
        if (index < 0) index = list.Count; // `after` not in this list (e.g. cross-parent); append
        list.Insert(index, item);
    }

    private static DateTime? ParseDate(string? s) =>
        string.IsNullOrEmpty(s) ? null : DateTime.ParseExact(s, "s", CultureInfo.InvariantCulture);

    private static RelationType RelationTypeFor(string abbrev) => abbrev switch
    {
        "SS" => RelationType.StartStart,
        "FF" => RelationType.FinishFinish,
        "SF" => RelationType.StartFinish,
        _ => RelationType.FinishStart,
    };

    private static TaskDto ToDto(Task task, List<AssignmentDto> assignments) => new(
        Id: task.ID ?? 0,
        UniqueId: task.UniqueID ?? 0,
        OutlineLevel: task.OutlineLevel ?? 1,
        Wbs: task.WBS ?? "",
        Name: task.Name ?? "",
        Duration: task.Duration?.ToString() ?? "",
        DurationDays: DaysFor(task.Duration),
        Start: task.Start?.ToString("s"),
        Finish: task.Finish?.ToString("s"),
        Percent: task.PercentageComplete ?? 0,
        Links: task.Predecessors
            .Where(r => r.PredecessorTask?.UniqueID != null)
            .Select(r => new LinkDto(r.PredecessorTask!.UniqueID!.Value, Abbrev(r.Type), DaysFor(r.Lag)))
            .ToList(),
        Assignments: assignments,
        // Kept as real multi-line text now that it's editable in a scrollable text view, not
        // collapsed to one line — the WBS table's single-line grid cell flattens it for display
        // on the Swift side instead, where "how to show it compactly" belongs.
        Notes: task.Notes ?? "",
        Summary: task.Summary,
        Milestone: task.Milestone,
        Critical: task.Critical);

    /// <summary>
    /// Calendar-day equivalent of a Duration, ignoring working-time calendars (a documented
    /// simplification — see progress notes). 8-hour day / 5-day week, matching MS Project's defaults.
    /// </summary>
    private static double DaysFor(Duration? d)
    {
        if (d is null || d.DurationValue == 0) return 0;
        return d.Units switch
        {
            TimeUnit.Minutes => d.DurationValue / 480.0,
            TimeUnit.Hours => d.DurationValue / 8.0,
            TimeUnit.Weeks => d.DurationValue * 7.0,
            TimeUnit.Months => d.DurationValue * 30.0,
            TimeUnit.Years => d.DurationValue * 365.0,
            _ => d.DurationValue,
        };
    }

    private static string Abbrev(RelationType? t) => t switch
    {
        RelationType.StartStart => "SS",
        RelationType.FinishFinish => "FF",
        RelationType.StartFinish => "SF",
        _ => "FS",
    };

    private static void Respond(Response response)
    {
        Console.Out.WriteLine(JsonSerializer.Serialize(response, JsonOptions));
        Console.Out.Flush();
    }
}
