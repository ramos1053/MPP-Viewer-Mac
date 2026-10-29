import SwiftUI

/// One help article. `keywords` are extra search terms that wouldn't otherwise appear in the title
/// (e.g. a menu shortcut, an alternate name), checked alongside the title and body text when
/// filtering — see HelpView.matches(_:).
struct HelpTopic: Identifiable {
    let id = UUID()
    let title: String
    let keywords: [String]
    let body: String
}

struct HelpSection: Identifiable {
    let id = UUID()
    let title: String
    let topics: [HelpTopic]
}

/// The Help menu's "MPP Viewer Help" window (MPPViewerMacApp.commands, `CommandGroup(replacing: .help)`).
/// A deliberate alternative to a real Apple Help Book: a `.help` bundle needs `hiutil` indexing and
/// `CFBundleHelpBookFolder`/`Name` entries wired into an actual app bundle at build time, and this
/// project's packaging is explicitly deferred (see progress doc) — a plain SwiftUI window with its own
/// search gets every topic documented and searchable today without that separate toolchain. Content
/// lives in HelpView.allSections below; every feature in the app should have an entry there.
struct HelpView: View {
    @State private var query = ""
    @State private var selectedTopicId: HelpTopic.ID?

    private var filteredSections: [HelpSection] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return Self.allSections }
        let needle = query.lowercased()
        return Self.allSections.compactMap { section in
            let matches = section.topics.filter { $0.matches(needle) }
            return matches.isEmpty ? nil : HelpSection(title: section.title, topics: matches)
        }
    }

    private var selectedTopic: HelpTopic? {
        let all = filteredSections.flatMap(\.topics)
        if let id = selectedTopicId, let found = all.first(where: { $0.id == id }) { return found }
        return all.first
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTopicId) {
                ForEach(filteredSections) { section in
                    Section(section.title) {
                        ForEach(section.topics) { topic in
                            Text(topic.title).tag(topic.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $query, placement: .sidebar, prompt: "Search Help")
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .overlay {
                if filteredSections.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        } detail: {
            if let topic = selectedTopic {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(topic.title)
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text(topic.body)
                            .font(.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
            } else {
                ContentUnavailableView("No Results", systemImage: "questionmark.circle", description: Text("Nothing in Help matches \"\(query)\"."))
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

private extension HelpTopic {
    func matches(_ needle: String) -> Bool {
        title.lowercased().contains(needle)
            || body.lowercased().contains(needle)
            || keywords.contains { $0.lowercased().contains(needle) }
    }
}

extension HelpView {
    static let allSections: [HelpSection] = [
        gettingStarted, gantt, timeline, network, calendar, calendars, resources, budget,
        export, findAndReplace, toolbarSection, settingsSection, undoRedo, shortcuts, limitations,
    ]

    private static let gettingStarted = HelpSection(title: "Getting Started", topics: [
        HelpTopic(
            title: "Opening a project",
            keywords: ["open", "file formats", "import"],
            body: """
            Use File ▸ Open… (or the toolbar's Open button) to open a project file. Supported formats:

            • Microsoft Project — .mpp, .mpt
            • Microsoft Project XML (MSPDI) — .xml
            • Microsoft Project Exchange — .mpx
            • GanttProject — .gan
            • Microsoft Project for Mac / older formats — .pp
            • Primavera P6 — .xer, .pmxml
            • Asta Powerproject — .pp, .ppx
            • SureTrak — .stx
            • Phoenix Project Manager — .pod
            • Deltek Open Plan / other MPXJ-supported formats — .cdp, .edp

            All reading goes through the MPXJ.Net library (bundled in the app's Helper process). If a \
            file opens with no tasks, or with an error at the top of the window, it is almost always \
            an unsupported variant of a format rather than a corrupt file — check the error text for \
            specifics.
            """
        ),
        HelpTopic(
            title: "Saving a project",
            keywords: ["save", "save as", "export", "xml", "mspdi"],
            body: """
            Save (⌘S) and Save As… (⇧⌘S) always write Project XML (MSPDI format), regardless of what \
            format the file was opened from. This is a limitation of the underlying MPXJ library: it \
            can read far more formats than it can reliably write back out.

            The first time you save a project that was opened from a non-XML file (.mpp, .gan, and so \
            on), the app prompts for a new save location rather than silently overwriting the original \
            file with XML content under its old name and extension. After that first Save As…, plain \
            Save writes to the same XML file without prompting again.

            There is no in-place editing of the original .mpp file — opening a .mpp and saving always \
            produces a separate .xml file.
            """
        ),
        HelpTopic(
            title: "Starting a new project",
            keywords: ["new project", "blank project", "create"],
            body: """
            File ▸ New Project (⌘N) starts a blank project with one starter task, so the date-range \
            and WBS logic always has something to work with. If a project is already open and has \
            unsaved changes, you are asked to confirm before it is discarded from memory — save first \
            if you want to keep it.
            """
        ),
        HelpTopic(
            title: "How this app is built",
            keywords: ["architecture", "helper", "mpxj", "subprocess", "about"],
            body: """
            MPP Viewer is a native Swift/AppKit app. Reading and writing project files is handled by a \
            bundled .NET helper process (using the MPXJ.Net library), which the app talks to over a \
            local, private line-by-line JSON protocol — nothing is sent over the network, and no file \
            ever leaves your Mac as part of opening, editing, or saving it.

            Schedule recalculation (what happens to later tasks when you change a task's dates or \
            duration) is handled entirely by the Swift app itself, not by MPXJ — see "Known \
            limitations" for what that does and does not account for.
            """
        ),
    ])

    private static let gantt = HelpSection(title: "Gantt View", topics: [
        HelpTopic(
            title: "The WBS table and Gantt chart",
            keywords: ["wbs", "task list", "split view", "resize"],
            body: """
            The Gantt view is a resizable split: the task table (WBS, Task Name, Duration, Start, \
            Finish, % Complete, Predecessors, Resources) on the left, and the Gantt chart on the right. \
            Drag the divider between them to resize. The two sides scroll together vertically but keep \
            independent horizontal scroll positions; clicking a cross-reference (like a predecessor \
            link) explicitly jumps/scrolls the other side to match rather than keeping them locked \
            together on every scroll.
            """
        ),
        HelpTopic(
            title: "Editing task fields",
            keywords: ["edit", "name", "duration", "percent complete", "inline"],
            body: """
            Task Name, Duration, and % Complete are editable directly in the table — click into the \
            cell and type. Start and Finish are edited through a calendar popover (click the date); \
            Option-click a second date in that popover to extend the current range instead of starting \
            a new one. Changing Duration or dates recalculates every downstream task linked by a \
            predecessor relationship (see "How scheduling works").
            """
        ),
        HelpTopic(
            title: "Predecessors and relationship types",
            keywords: ["predecessor", "dependency", "fs", "ss", "ff", "sf", "lag"],
            body: """
            Predecessors are shown as clickable WBS references — clicking one jumps the selection to \
            that task. Click the Predecessors cell itself to open the editor, where you can add or \
            remove links and set the relationship type (Finish-to-Start, Start-to-Start, \
            Finish-to-Finish, Start-to-Finish) and lag. By default these show as short codes (FS, SS, \
            FF, SF); turn on "Show relationship types as full words" in Settings or the View menu to \
            spell them out instead. The editor refuses a link that would create a circular dependency.
            """
        ),
        HelpTopic(
            title: "How scheduling works",
            keywords: ["scheduler", "recalculate", "cpm", "critical path", "working days"],
            body: """
            This app recalculates dates itself rather than relying on the file format's own engine \
            (MPXJ has no scheduling engine — it only reads and writes). Changing a task's duration or \
            dates pushes every downstream task linked by a predecessor relationship forward, using \
            calendar-day arithmetic: an 8-hour day, 5-day work week, no holidays and no per-resource or \
            per-task working-time calendars. This is simpler than Microsoft Project's own engine — see \
            "Known limitations" for what that means in practice.

            Turn on "Highlight critical path" (Settings, the View menu, or the toolbar's warning-icon \
            button) to color every task, bar, and link on the critical path red across the Gantt, \
            Timeline, and Network views. This is a real, live calculation — a backward pass that derives \
            float from the same dependency graph the forward pass uses — so it updates automatically as \
            you edit, and works just as well for a project built entirely from scratch here (File ▸ New \
            Project, then Add Task) as for an imported file. It shares the forward pass's calendar-day \
            limitation above, so it can diverge from Microsoft Project's own critical path on a file that \
            relies on holidays or a non-default working week. See "Known limitations."
            """
        ),
        HelpTopic(
            title: "Notes",
            keywords: ["notes", "comments", "double-click"],
            body: """
            Double-click a task's Notes cell to open a small editor popover and type or paste free-text \
            notes. The same Notes editor is used everywhere else in the app that lets you edit notes \
            (Timeline, Network, and Calendar views' right-click menus).
            """
        ),
        HelpTopic(
            title: "Adding and deleting tasks",
            keywords: ["add task", "delete task", "insert", "wbs renumber"],
            body: """
            Right-click a row for Add Task Before / Add Task After / Delete Task, or use the toolbar's \
            + button and Delete Task button, or the Task menu (Add Task Before ⇧⌘↑, Add Task After \
            ⇧⌘↓, Delete Task ⌘Delete — these act on whatever row is currently selected). Every one of \
            these asks for confirmation first, since it renumbers the WBS of every task after the \
            insertion or removal point.
            """
        ),
        HelpTopic(
            title: "Assigning resources to a task",
            keywords: ["resources cell", "assignment", "units"],
            body: """
            Click a task's Resources cell to open the assignment editor, where you can add or remove \
            resources and set each one's assignment units (the percentage of that resource's time \
            committed to the task). The same editor is reused in Calendar's Team mode for editing an \
            assignment directly from its bar.
            """
        ),
        HelpTopic(
            title: "Selecting rows and keyboard navigation",
            keywords: ["select", "arrow keys", "drag select", "multi-select"],
            body: """
            Click a row to select it; drag across rows to select a range. With a row selected, the Up \
            and Down arrow keys move the selection one row at a time without needing to click again.
            """
        ),
        HelpTopic(
            title: "Zoom and Fit to Window",
            keywords: ["zoom in", "zoom out", "fit to window", "pixels per day"],
            body: """
            The toolbar's Zoom Out / Zoom In buttons change how many pixels represent one day on the \
            Gantt chart. Fit to Window scales the chart so the whole project's date range fits the \
            visible pane, and keeps re-fitting as you resize the window; zooming in or out manually \
            turns Fit to Window back off.
            """
        ),
    ])

    private static let timeline = HelpSection(title: "Timeline View", topics: [
        HelpTopic(
            title: "What the Timeline view shows",
            keywords: ["overview", "condensed", "top-level"],
            body: """
            Timeline is a condensed, always-fit-to-pane overview showing only top-level tasks (outline \
            level 1) — the same idea as Microsoft Project's own Timeline view: a hand-picked, \
            at-a-glance summary rather than the full WBS. It has no zoom control; it always shows the \
            whole project.

            The date axis shows month (or year, for long projects) tick labels, week-of-year \
            separators when there is enough room, and vertical "wall" lines with small dots at every \
            month boundary running through the chart.
            """
        ),
        HelpTopic(
            title: "Interacting with Timeline bars",
            keywords: ["double-click", "right-click", "context menu"],
            body: """
            Double-click a bar or milestone to jump to it in the Gantt view's WBS table. Right-click \
            for a context menu: Jump to WBS, Notes…, and Delete Task.
            """
        ),
    ])

    private static let network = HelpSection(title: "Network View", topics: [
        HelpTopic(
            title: "What the Network view shows",
            keywords: ["pert", "dependency diagram", "node graph"],
            body: """
            Network shows the project as a PERT-style dependency diagram: one box per task, arrows for \
            predecessor relationships, laid out in layers by dependency depth.
            """
        ),
        HelpTopic(
            title: "Panning and zooming",
            keywords: ["pan", "zoom", "trackpad", "scroll", "pinch", "command scroll", "cursor"],
            body: """
            Click and drag an empty area to pan; a plain two-finger scroll or mouse wheel pans too, the \
            ordinary way. Command+scroll or a pinch gesture zooms, anchored under the cursor (or pinch \
            center) — whatever you're looking at stays in place as the diagram scales around it. The \
            toolbar's Zoom Out/Zoom In buttons and Fit to Window also work here, anchored on the center \
            of the current view since there's no cursor position to anchor on from a button click.
            """
        ),
        HelpTopic(
            title: "Interacting with nodes",
            keywords: ["double-click", "right-click", "context menu", "select"],
            body: """
            Click a node to select that task (the Gantt view's WBS table updates to match). \
            Double-click to jump straight to it in the Gantt view. Right-click for Jump to WBS, \
            Notes…, and Delete Task.
            """
        ),
    ])

    private static let calendar = HelpSection(title: "Calendar View", topics: [
        HelpTopic(
            title: "Month mode",
            keywords: ["month", "grid", "6 weeks"],
            body: """
            A traditional month-grid calendar (distinct from the separate "Calendars" working-time \
            editor — see the Calendars section — which defines holidays and the working week rather \
            than showing the schedule). Always shows 6 weeks. Task bars wrap across week-row boundaries \
            with a flat edge at the wrap point; each week shows up to 3 bars, with any more folded into \
            a "+N more" chip. Bars are colored by each task's top-level WBS section, from an 8-color \
            palette that deliberately avoids red and orange so a project-colored bar is never confused \
            with a critical-path-red one.

            Double-click or right-click a bar for the same Jump to WBS / Notes… / Delete Task menu as \
            Timeline and Network.
            """
        ),
        HelpTopic(
            title: "Team mode",
            keywords: ["team", "resource timeline", "weekly", "per-resource", "overallocation"],
            body: """
            A per-resource weekly timeline: one row per resource (with an avatar and name), columns per \
            day, three weeks visible at a time with Previous / Next / Today paging. Allocation bars use \
            the same WBS-section color convention as Month mode. A thin orange strip above a day flags \
            that resource being over-allocated that day (summed assignment Units above their Max \
            Units).

            Bars here support two extra actions beyond Jump to WBS / Notes… / Delete Task: "Edit \
            Assignment…" (opens the same assignment editor as the Gantt view's Resources cell) and \
            "Remove from <Resource>" to unassign with one click.
            """
        ),
        HelpTopic(
            title: "Task Usage mode",
            keywords: ["task usage", "timephased work", "hours per day", "spreadsheet"],
            body: """
            A task-centric counterpart to Team mode: one row per task (with a resource sub-row per \
            assignment), columns per day, a "Work" column showing total scheduled hours, and the day \
            grid showing each task's/resource's timephased work in hours — a flat 8 hours × that \
            assignment's Units% on every day the task is scheduled, with nothing on days outside it. \
            Same three-week, Previous/Next/Today paging as Team mode. Clicking a row selects that task; \
            double-click jumps to it in the Gantt view.
            """
        ),
        HelpTopic(
            title: "Switching between Month, Team, and Task Usage",
            keywords: ["toggle", "mode switch", "persisted"],
            body: """
            Use the three-way toggle at the top of the Calendar view. Your last choice is remembered \
            across launches — the same setting as Settings' "Default calendar display," which both \
            read and write the same preference.
            """
        ),
        HelpTopic(
            title: "Selection color",
            keywords: ["outline color", "highlight", "selected task"],
            body: """
            The colored outline/highlight around whichever task you click is configurable, and applies \
            everywhere a selection is shown this way — all three Calendar modes and the Network view. \
            See Settings ▸ Selection highlight color.
            """
        ),
    ])

    private static let calendars = HelpSection(title: "Calendars (Working-Time Editor)", topics: [
        HelpTopic(
            title: "What the Calendars editor is for",
            keywords: ["working time", "holidays", "calendars button", "toolbar calendars"],
            body: """
            The toolbar's Calendars button (a calendar-with-clock icon) opens a separate editor for \
            working-time calendar *definitions* — which days of the week are normally working days, \
            and one-off exceptions (holidays, or "makeup" days that are worked despite normally being \
            off) — distinct from the Calendar view, which shows your actual schedule on a calendar \
            grid rather than defining what a working day even is.

            A project can have more than one calendar (for example, a resource-specific one derived \
            from the default); the sidebar on the left lists every calendar in the file, with the \
            project's default marked. Select one to edit its weekly pattern and exceptions on the \
            right. Add Calendar creates a new one (Monday–Friday by default); a non-default calendar \
            can be deleted, unless it's still in use by a task, resource, or another calendar derived \
            from it, in which case Delete is unavailable for it.
            """
        ),
        HelpTopic(
            title: "Working week and exceptions",
            keywords: ["working week toggle", "add holiday", "makeup day", "exception"],
            body: """
            Click any day pill (Sun–Sat) to toggle it working/non-working for the selected calendar. \
            Below that, Exceptions lists one-off overrides — type a name, pick a From/To date range, \
            and Add; leave "Working (makeup day)" unchecked for an ordinary holiday (the common case), \
            or check it for a day that's worked despite normally being off. Remove an exception with \
            the × next to it.
            """
        ),
        HelpTopic(
            title: "What this does and doesn't affect",
            keywords: ["doesn't affect schedule", "not used by scheduler", "simplification"],
            body: """
            Calendars you edit here are saved as real data in the file — they'll show up correctly if \
            the project is later opened in Microsoft Project. But this app's own scheduler does not yet \
            read them back: task dates still use plain calendar-day arithmetic regardless of what a \
            calendar's working week or holidays say. Editing a calendar here won't shift any task \
            dates. See "Known limitations."
            """
        ),
    ])

    private static let resources = HelpSection(title: "Resources", topics: [
        HelpTopic(
            title: "The Resource Sheet",
            keywords: ["resource sheet", "resource list"],
            body: """
            Switch to the Resources view for a table of every resource in the project, with Add and \
            Delete Resource buttons. Editable fields: Name, Type, Initials, Group, Code, and Accrue At \
            — click a cell (or use the dropdown, for Type and Accrue At) to edit, or double-click Name \
            to rename.
            """
        ),
        HelpTopic(
            title: "Rates, Max Units, and Base Calendar",
            keywords: ["standard rate", "overtime rate", "cost per use", "max units", "read-only"],
            body: """
            Standard Rate, Overtime Rate, Cost/Use, and Max Units are editable here too. Base Calendar \
            is read-only — the app has no calendar-management UI to validate a typed calendar name \
            against, so changing which named working-time calendar a resource uses isn't supported.
            """
        ),
        HelpTopic(
            title: "Custom resource type",
            keywords: ["custom type", "work", "material", "cost", "nonlabor"],
            body: """
            The underlying file format only supports four resource types (Work, Material, Cost, \
            Nonlabor). The Type cell's "Custom…" option lets you label a resource with your own text \
            anyway — it is still stored as Work underneath, but displays your custom label (with a \
            small sparkles badge) everywhere the resource's type is shown.
            """
        ),
        HelpTopic(
            title: "The resource detail inspector",
            keywords: ["double-click avatar", "resource detail", "scheduled hours", "billable"],
            body: """
            Double-click a resource's avatar (not the name, which has its own rename behavior) to open \
            a detail panel: editable profile fields, scheduled vs. completed hours, hourly rate, \
            cost-to-date, planned cost, a progress breakdown by WBS section, and a list of every task \
            the resource is engaged on — click an engagement to jump straight to it in the Gantt view.
            """
        ),
    ])

    private static let budget = HelpSection(title: "Budget", topics: [
        HelpTopic(
            title: "Setting a project budget",
            keywords: ["budget button", "toolbar budget", "set budget"],
            body: """
            Click the toolbar's Budget button (a dollar-sign icon) to set or change the project-wide \
            budget and see current status. The icon's color reflects status at a glance: gray for no \
            budget set, green for on track, orange for nearing the budget, red for over it.
            """
        ),
        HelpTopic(
            title: "Planned vs. earned cost",
            keywords: ["earned cost", "planned cost", "progress-weighted"],
            body: """
            Planned cost is the full cost of all assigned work at each resource's rate. Earned cost is \
            that same figure weighted by each task's % Complete — it only counts the portion of planned \
            cost that corresponds to work actually marked done, not the whole project's planned total. \
            The budget popover shows both, plus a per-resource cost breakdown.
            """
        ),
        HelpTopic(
            title: "How the budget is stored",
            keywords: ["budget resource", "project summary task", "mechanism"],
            body: """
            Setting a budget creates a special "Budget" resource and assigns it to the project's top \
            summary row, matching how Microsoft Project itself stores a project-wide budget — this is \
            what lets a budget set here also show up correctly if the file is later opened in \
            Microsoft Project.
            """
        ),
    ])

    private static let export = HelpSection(title: "Export and Print", topics: [
        HelpTopic(
            title: "Export as CSV",
            keywords: ["csv export", "file menu export", "spreadsheet"],
            body: """
            File ▸ Export as CSV… writes every task (WBS, Name, Duration, Start, Finish, % Complete, \
            Predecessors as WBS references, Resources, Notes) to a .csv file, regardless of which view \
            is currently on screen — this reads straight from the task list, not from any view's \
            rendering.
            """
        ),
        HelpTopic(
            title: "Export Timeline as PDF / PNG",
            keywords: ["pdf export", "png export", "image export"],
            body: """
            File ▸ Export Timeline as PDF… / as PNG… renders a snapshot of the Timeline view's own \
            condensed, whole-project overview (not whatever view happens to be on screen) to an image \
            or PDF file, sized to fit everything with nothing scrolled or clipped.
            """
        ),
        HelpTopic(
            title: "Printing",
            keywords: ["print", "command-p", "print timeline"],
            body: """
            File ▸ Print Timeline… (⌘P) sends the same Timeline snapshot used for PDF/PNG export to the \
            standard macOS print panel.
            """
        ),
    ])

    private static let findAndReplace = HelpSection(title: "Find and Search", topics: [
        HelpTopic(
            title: "Searching tasks",
            keywords: ["search field", "toolbar search", "cmd-f"],
            body: """
            The toolbar's search field (⌘F focuses it) searches Task Name, Notes, and WBS code, \
            case-insensitively, as you type. Press Return to jump to the first match in the Gantt view; \
            press Return again (or use Edit ▸ Find Next, ⌘G) to cycle to the next one. Edit ▸ Find \
            Previous (⇧⌘G) cycles backward through the same matches.
            """
        ),
        HelpTopic(
            title: "Find and Replace",
            keywords: ["replace", "replace all", "edit menu", "option-command-f"],
            body: """
            Edit ▸ Find and Replace… (⌥⌘F) opens a separate dialog for find-and-replace across Task \
            Name and Notes. Previous / Next step through matches (selecting the matching task in the \
            Gantt view as you go, so you can see what you're about to change). Replace rewrites every \
            occurrence of the find text within that one match's field, then advances to the next match. \
            Replace All does the same for every remaining match at once and reports how many it \
            changed.

            Matching is case-insensitive. Each individual replacement is its own separate, undoable \
            step — Undo after a Replace All reverts just the last replacement, not the whole batch.
            """
        ),
    ])

    private static let toolbarSection = HelpSection(title: "Toolbar", topics: [
        HelpTopic(
            title: "Toolbar buttons",
            keywords: ["new project button", "open button", "save button", "add task button", "delete task button", "zoom buttons", "fit to window button", "critical path button", "budget button", "calendars button", "search field"],
            body: """
            Left to right: New Project, Open…, Save, Add Task (a menu — Add Task Before / Add Task \
            After), Delete Task, Zoom Out, Zoom In, Fit to Window, Critical Path (toggle), Budget, \
            Calendars, and the search field at the far right. The view switcher (Gantt / Timeline / \
            Network / Calendar / Resources) sits in its own row directly below the toolbar, alongside \
            the open project's file name.
            """
        ),
        HelpTopic(
            title: "Icon Only vs. Icon and Text",
            keywords: ["right-click toolbar", "display style", "labels"],
            body: """
            Right-click anywhere on the toolbar for a choice between Icon Only and Icon and Text \
            display styles. This choice is remembered across launches.
            """
        ),
        HelpTopic(
            title: "Why the toolbar can't be rearranged",
            keywords: ["customize toolbar", "rearrange", "remove buttons", "not available"],
            body: """
            Unlike most Mac apps, this toolbar does not support drag-to-rearrange, removing buttons, or \
            a Customize Toolbar… command. That capability had to be removed after it was found to \
            reliably crash the app on this version of macOS — it is not a missing feature so much as \
            one that was deliberately turned off for stability. Icon Only/Icon and Text (above) is \
            still available, since that does not share the same problem.
            """
        ),
    ])

    private static let settingsSection = HelpSection(title: "Settings", topics: [
        HelpTopic(
            title: "Opening Settings",
            keywords: ["preferences", "command-comma"],
            body: """
            MPP Viewer ▸ Settings… (⌘,) opens the Settings window, grouped into General and Display.
            """
        ),
        HelpTopic(
            title: "General settings",
            keywords: ["default view", "default calendar display"],
            body: """
            Default view when opening a project: which view (Gantt, Timeline, Network, Calendar, \
            Resources) a project opens into. Default calendar display: Month, Team, or Task Usage — \
            the same setting as the Calendar view's own three-way toggle, kept in sync in both \
            directions.
            """
        ),
        HelpTopic(
            title: "Display settings",
            keywords: ["relationship types", "critical path toggle", "selection color"],
            body: """
            Show relationship types as full words: spells out FS/SS/FF/SF as Finish-to-Start, \
            Start-to-Start, and so on in the Predecessors editor. Highlight critical path: colors \
            critical tasks, bars, and links red across the Gantt, Timeline, and Network views. \
            Selection highlight color: the outline/highlight color around whatever task you click, in \
            all three Calendar modes and the Network view.
            """
        ),
    ])

    private static let undoRedo = HelpSection(title: "Undo and Redo", topics: [
        HelpTopic(
            title: "What can be undone",
            keywords: ["undo", "redo", "history"],
            body: """
            Edit ▸ Undo (⌘Z) and Redo (⇧⌘Z) cover essentially every change: task edits, predecessor \
            changes, resource assignments, adding/deleting tasks or resources, resource field edits, \
            and budget changes. Each Find and Replace replacement is its own separate undo step, not \
            batched together, even when it came from Replace All.
            """
        ),
    ])

    private static let shortcuts = HelpSection(title: "Keyboard Shortcuts", topics: [
        HelpTopic(
            title: "Full shortcut list",
            keywords: ["shortcuts", "hotkeys", "cmd", "command key"],
            body: """
            File
            • ⌘N — New Project
            • ⌘S — Save
            • ⇧⌘S — Save As…
            • ⌘P — Print Timeline…

            Edit
            • ⌘Z — Undo
            • ⇧⌘Z — Redo
            • ⌘F — Focus the search field
            • ⌘G — Find Next
            • ⇧⌘G — Find Previous
            • ⌥⌘F — Find and Replace…

            Task (acts on the currently selected row)
            • ⇧⌘↑ — Add Task Before
            • ⇧⌘↓ — Add Task After
            • ⌘Delete — Delete Task

            General
            • ⌘, — Settings…
            • ⌘? — This Help window
            • Up / Down arrow — Move the row selection, when a row is selected
            • Return — Confirm whatever popover or dialog is currently open
            """
        ),
    ])

    private static let limitations = HelpSection(title: "Known Limitations", topics: [
        HelpTopic(
            title: "Scheduling is simplified",
            keywords: ["working time", "calendars", "holidays", "cpm", "backward pass", "slack", "float", "critical path not computed"],
            body: """
            Schedule recalculation — and the critical-path/float calculation behind "Highlight critical \
            path" — both use calendar-day arithmetic only: a fixed 8-hour day and 5-day week, with no \
            holidays, no per-resource working hours, and no named working-time calendars (beyond reading \
            whatever calendar name a resource already has — it cannot be changed here). This is true \
            even for calendars you've edited in the Calendars editor — see that section. A project that \
            depends heavily on Microsoft Project's own calendar system will not recalculate, or show the \
            same critical path, identically here.
            """
        ),
        HelpTopic(
            title: "Project budget on a from-scratch project",
            keywords: ["budget not saving", "new project budget", "budget resource missing"],
            body: """
            A budget set on a project that has been saved and reopened at least once persists \
            correctly. A budget set on a project that started as File ▸ New Project and has never been \
            through a save/reopen cycle may not persist on the very first save — save, reopen, then set \
            or confirm the budget if it looks like it didn't take.
            """
        ),
        HelpTopic(
            title: "Save always writes Project XML",
            keywords: ["save format", "mspdi only", "round-trip"],
            body: """
            There is no writer for most of the formats this app can open — only Project XML (MSPDI). \
            Opening a .mpp and saving produces a separate .xml file; it never writes back to .mpp, \
            .gan, or any other original format.
            """
        ),
        HelpTopic(
            title: "Toolbar customization is unavailable",
            keywords: ["crash", "customize toolbar"],
            body: """
            See Toolbar ▸ "Why the toolbar can't be rearranged." This was removed deliberately after it \
            was found to crash the app.
            """
        ),
        HelpTopic(
            title: "Other known gaps",
            keywords: ["timeline labels", "network zoom", "resource rates", "base calendar"],
            body: """
            • Timeline view: bar and milestone labels are not collision-checked against each other, so \
            tightly packed short items can visually crowd.
            • Resource Sheet: Base Calendar cannot be changed (no calendar-management UI exists to \
            validate a typed name against, though you can now see and edit the calendars themselves in \
            the Calendars editor).
            """
        ),
    ])
}
