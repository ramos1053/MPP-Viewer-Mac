import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The main window's switchable panes. New views (Network Diagram, Calendars, Task/Resource Usage,
/// …) add a case here and a branch in ContentView.body's switch — see ResourceSheetView's doc
/// comment for why those views don't draw their own ToolbarContentDivider.
enum ViewMode: String, CaseIterable, Identifiable {
    case gantt = "Gantt"
    case timeline = "Timeline"
    case network = "Network"
    case calendar = "Calendar"
    case resources = "Resources"
    var id: Self { self }

    /// Whether the toolbar's Zoom Out/In/Fit to Window act on this view. Zoom is a capability of
    /// *views with a pannable/zoomable canvas* (the Gantt chart, the Network Diagram's node graph),
    /// not something specific to the Gantt view — driven by this flag rather than a hardcoded
    /// "only .gantt" check, so a future zoomable view only needs to flip this on, not touch the
    /// toolbar code. False for Resources (a plain table), Timeline (always shows the whole project
    /// condensed to fit, same as Microsoft Project's own Timeline bar), and Calendar (a month grid
    /// has a month to page through, not a date-axis scale to zoom — true of all three of its modes,
    /// including Task Usage, which pages by week the same way Team mode already does).
    var supportsZoom: Bool {
        self == .gantt || self == .network
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var viewMode: ViewMode

    /// Only reason this type needs a custom init at all: reading Settings' "Default view when
    /// opening a project" into viewMode's *initial* value. `@State`'s own default-value syntax can't
    /// express "read this from AppStorage," since that default is evaluated once, before any
    /// AppStorage property wrapper on this type would exist to read from.
    init(model: AppModel) {
        self.model = model
        let defaultMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "defaultViewMode") ?? "") ?? .gantt
        _viewMode = State(initialValue: defaultMode)
    }
    /// Shared across every view that draws `isCritical` in red (Gantt, Timeline, Network) and the
    /// task list's row tint — a display preference, not project data, so it's app-wide via
    /// AppStorage rather than living on AppModel; same pattern as predecessorTypeFullNames.
    @AppStorage("showCriticalPath") private var showCriticalPath = true
    /// The outline color around whatever's clicked in the Calendar view — configurable since a
    /// hardcoded accent-color outline didn't read as a deliberate "this is selected" signal there.
    @AppStorage("calendarSelectionColor") private var calendarSelectionColorName = HighlightColor.red.rawValue
    @State private var pixelsPerDay: CGFloat = 12
    @State private var leftPaneWidth: CGFloat = 700
    @State private var scrollSync = GanttScrollSync()
    /// On while "Fit" is active: the Gantt pane's actual pixelsPerDay is derived fresh every render
    /// from the live pane width (see body) instead of read from `pixelsPerDay`, so it keeps fitting
    /// through any later divider drag or window resize — "no matter what the user selects." Turned
    /// back off the moment a manual zoom button is pressed, same as a "Fit" toggle in Preview/Keynote.
    @State private var fitToWindow = false
    /// The Gantt pane's last-known actual width, kept in sync via onChange below. Only the toolbar's
    /// zoom +/- buttons read this (to seed a sane starting pixelsPerDay when exiting Fit) — the Fit
    /// rendering itself uses a freshly-computed width inline, with no lag.
    @State private var ganttPaneWidth: CGFloat = 0
    /// Network Diagram's own zoom state — same roles as pixelsPerDay/fitToWindow/ganttPaneWidth
    /// above, just for a 2D node graph instead of a 1D date axis, so it's a plain scale factor rather
    /// than pixels-per-day. Kept independent of the Gantt view's zoom: switching views shouldn't
    /// change how zoomed-in the *other* view was left.
    @State private var networkScale: CGFloat = 1
    // Starting in Fit to Window (rather than a plain 1:1 scale) isn't just a nicer default — a
    // wide diagram's NSHostingView/Canvas reliably fails to render *anything* the very first time
    // it's shown at native scale (confirmed live: reproduces regardless of diagram size, an
    // NSScrollView/NSHostingView-and-Canvas interaction neither a forced layout pass, an explicit
    // display invalidation, nor a scroll nudge fixed), and only recovers once something changes
    // `contentSize` after the view is actually attached — exactly what toggling Fit does. Starting
    // fitted sidesteps the dead-first-paint entirely rather than trying to force a redraw around it.
    @State private var networkFitToWindow = true
    @State private var networkPaneSize: CGSize = .zero
    /// Bumped only when switching into Network with an existing selection (see networkDiagramView's
    /// onAppear) — not on every selection change, same reasoning as Gantt/Calendar: a plain click
    /// already inside Network shouldn't re-center the view on top of itself.
    @State private var networkScrollTrigger = 0
    @State private var searchText = ""
    @State private var showingBudgetPopover = false
    @State private var showingCalendarsSheet = false
    @State private var showFindReplace = false

    var body: some View {
        // Chained directly onto `mainContent` (already its own fully-resolved `some View`) rather
        // than inline inside one giant VStack-plus-modifier-chain expression — body as a whole, not
        // any one branch or modifier in isolation, was what pushed the type checker over its limit
        // once enough was inlined into it ("unable to type-check this expression in reasonable
        // time"), a real compiler error hit repeatedly this pass, not SourceKit staleness.
        mainContent
            .frame(minWidth: 1100, minHeight: 650)
            // Invisible — its only job is to hold AppKit keyboard focus for arrow-key row
            // navigation. See SelectionKeyCatcher's doc comment for why this can't just be
            // @FocusState.
            .background(SelectionKeyCatcher(selectedTaskId: model.selectedTaskId, onMove: moveSelection))
            .toolbar { mainToolbarItems }
            .navigationTitle(model.title.isEmpty ? "MPP Viewer" : model.title)
            .onAppear { restoreToolbarDisplayMode() }
            // See restoreToolbarDisplayMode's doc comment for why this is hand-rolled instead of
            // relying on AppKit's own toolbar autosave. KVO on `toolbar.displayMode` was tried first,
            // as a true "persist the instant it changes" — didn't fire (confirmed live: switching
            // Icon Only/Icon and Text via the toolbar's right-click menu visibly changed the toolbar
            // but never wrote the observer's UserDefaults key), so this isn't actually a KVO-compliant
            // property to observe on this SDK despite being documented as one. These two notifications
            // between them catch every realistic way a session ends — losing focus (⌘-Tab away,
            // clicking another app) and quitting — without needing a live observation at all.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                persistToolbarDisplayModeNow()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                persistToolbarDisplayModeNow()
            }
            .onDisappear { model.shutdown() }
            .confirmationDialog(
                model.pendingTaskAction?.title ?? "",
                isPresented: Binding(
                    get: { model.pendingTaskAction != nil },
                    set: { if !$0 { model.pendingTaskAction = nil } }),
                titleVisibility: .visible,
                presenting: model.pendingTaskAction
            ) { action in
                Button(action.isDestructive ? "Delete" : "Add", role: action.isDestructive ? .destructive : nil) {
                    model.confirmPendingTaskAction()
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { model.pendingTaskAction = nil }
            } message: { action in
                Text(pendingActionMessage(action))
            }
            .alert("New Project", isPresented: $model.pendingNewProject) {
                Button("New Project", role: .destructive) { model.confirmNewProject() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This discards the current project from memory. Save first if you want to keep it.")
            }
            // Native search field in the toolbar, with ⌘F to focus it for free. Return jumps to the
            // next match (Name, Notes, or WBS code) in the WBS/Gantt view rather than filtering the
            // list in place — "search for text and find it in the WBS," not a live filter, and it
            // rides the same selection-sync machinery scrollToCurrentSelection already provides.
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search tasks")
            .onSubmit(of: .search) { jumpToNextMatch() }
            // Edit menu's Find Next/Previous/Find and Replace… (MPPViewerMacApp.commands) can't call
            // straight into this view's private search state, so they go through this same
            // AppModel-mediated trigger PendingTaskAction already uses — see FindMenuAction's doc
            // comment.
            .onChange(of: model.pendingFindAction) { _, action in
                guard let action else { return }
                switch action {
                case .next: jumpToNextMatch()
                case .previous: jumpToPreviousMatch()
                case .replace: showFindReplace = true
                }
                model.pendingFindAction = nil
            }
            .sheet(isPresented: $showFindReplace) {
                FindReplaceView(model: model, initialFindText: searchText) { taskId in
                    model.selectedTaskId = taskId
                    viewMode = .gantt
                }
            }
    }

    private var matchingTaskIds: [Int] {
        guard !searchText.isEmpty else { return [] }
        let needle = searchText.lowercased()
        return model.tasks
            .filter { $0.name.lowercased().contains(needle) || $0.notes.lowercased().contains(needle) || $0.wbs.lowercased().contains(needle) }
            .map(\.id)
    }

    private var budgetSummary: BudgetCalculator.Summary {
        BudgetCalculator.summary(tasks: model.tasks, resourcesById: model.resourcesById)
    }

    private var budgetStatus: BudgetCalculator.Status {
        BudgetCalculator.status(earnedCost: budgetSummary.earnedCost, budget: model.budgetCost)
    }

    private var budgetStatusIcon: String {
        switch budgetStatus {
        case .noBudget: "dollarsign.circle"
        case .onTrack: "dollarsign.circle.fill"
        case .nearing: "exclamationmark.circle.fill"
        case .overBudget: "exclamationmark.triangle.fill"
        }
    }

    private var budgetStatusColor: Color {
        switch budgetStatus {
        case .noBudget: .secondary
        case .onTrack: .green
        case .nearing: .orange
        case .overBudget: .red
        }
    }

    private var budgetStatusHelp: String {
        switch budgetStatus {
        case .noBudget: "No budget set — click to add one"
        case .onTrack: "On track"
        case .nearing: "Nearing budget"
        case .overBudget: "Over budget"
        }
    }

    private var budgetToolbarButton: some View {
        Button { showingBudgetPopover = true } label: {
            Label("Budget", systemImage: budgetStatusIcon)
        }
        .foregroundStyle(budgetStatusColor)
        .disabled(model.tasks.isEmpty)
        .help(budgetStatusHelp)
        .popover(isPresented: $showingBudgetPopover) {
            BudgetSummaryView(
                budgetCost: model.budgetCost, summary: budgetSummary, resourcesById: model.resourcesById,
                onApply: { model.setBudget(to: $0) })
        }
    }

    /// The view switcher (Gantt/Timeline/Network/Calendar/Resources) and the project's file name,
    /// both moved out of the toolbar into this plain row below it. The title moved first (see
    /// `.windowToolbarStyle` in MPPViewerMacApp) when the toolbar switched to showing text labels
    /// under its icons, leaving no room for it there too. The view switcher moved second, for a
    /// different reason: it needs a `Spacer()` between it and the title to sit at the leading edge
    /// with the title pinned trailing, and every mechanism tried for that *inside* the real
    /// `NSToolbar` (SwiftUI's `ToolbarSpacer`, a custom transparent `ToolbarItem`, even a raw AppKit
    /// `.flexibleSpace` inserted directly into `toolbar.items`) rendered at zero width on this SDK —
    /// a genuine `NSToolbar` layout bug on this build, not fixable from here. A plain SwiftUI
    /// `Spacer()` in an ordinary `HStack`, outside `NSToolbar` entirely, isn't subject to that bug.
    /// The row itself is deliberately not styled as a pill/bubble: a thin background tint for
    /// separation from the content below, the same "subtle band" convention weekdayHeader
    /// (CalendarView) and the Resource Sheet's header row already use.
    private var projectTitleRow: some View {
        HStack(spacing: 12) {
            Picker("View", selection: $viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(model.tasks.isEmpty)

            Spacer(minLength: 12)

            if !model.title.isEmpty {
                Text(model.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
    }

    private func jumpToNextMatch() {
        let matches = matchingTaskIds
        guard !matches.isEmpty else { return }
        if let current = model.selectedTaskId, let currentIndex = matches.firstIndex(of: current) {
            model.selectedTaskId = matches[(currentIndex + 1) % matches.count]
        } else {
            model.selectedTaskId = matches[0]
        }
        viewMode = .gantt
    }

    /// Edit menu's Find Previous (⇧⌘G) — mirrors jumpToNextMatch exactly, just stepping backward
    /// through the same match list.
    private func jumpToPreviousMatch() {
        let matches = matchingTaskIds
        guard !matches.isEmpty else { return }
        if let current = model.selectedTaskId, let currentIndex = matches.firstIndex(of: current) {
            model.selectedTaskId = matches[(currentIndex - 1 + matches.count) % matches.count]
        } else {
            model.selectedTaskId = matches[matches.count - 1]
        }
        viewMode = .gantt
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            ToolbarContentDivider()
            projectTitleRow

            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
            }

            if model.tasks.isEmpty && !model.isLoading {
                noFileOpenView
            } else if let range = model.dateRange {
                switch viewMode {
                case .gantt:
                    ganttSplitView(range: range)
                case .timeline:
                    TimelineOverviewView(
                        tasks: model.tasks, range: range, showCriticalPath: showCriticalPath,
                        selectedTaskId: model.selectedTaskId, onSelect: { model.selectedTaskId = $0 },
                        onJumpToWBS: jumpToWBS,
                        onDeleteRequest: { model.pendingTaskAction = .delete(taskId: $0) },
                        onEditNotes: { model.setNotes(taskId: $0, to: $1) })
                case .network:
                    networkDiagramView()
                case .calendar:
                    calendarView
                case .resources:
                    ResourceSheetView(model: model, onJumpToWBS: jumpToWBS)
                }
            }
        }
    }

    /// Pulled out of body for the same type-checker-timeout reason as mainToolbarItems/ganttSplitView
    /// below — body as a whole, not any one branch in isolation, was the thing pushing the checker
    /// over its limit once enough was inlined into it.
    private var noFileOpenView: some View {
        ContentUnavailableView {
            Label("No File Open", systemImage: "doc.text")
        } description: {
            Text("Open a Microsoft Project, Project XML, GanttProject, or other supported project file — or start a new one from scratch.")
        } actions: {
            Button("New Project") { model.requestNewProject() }
            Button("Open…", action: openPanel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Pulled out of body for the same reason ganttSplitView below was pulled out of body's switch:
    /// inlined, this many ToolbarItems alongside everything else in body pushed the type checker over
    /// its limit again ("unable to type-check this expression in reasonable time") — a real compiler
    /// error, not a SourceKit staleness issue.
    ///
    /// Deliberately a plain, non-customizable toolbar (no `.toolbar(id:)`, no
    /// `CustomizableToolbarContent`) — not a style choice, a crash fix. `.toolbar(id:)` opts into
    /// AppKit's customizable-toolbar system, and on this macOS build that system is broken in a way
    /// that reliably **crashes the app**: right-clicking the toolbar (AppKit's own, automatic context
    /// menu item — not anything this app adds) and choosing "Customize Toolbar…" throws a layout
    /// constraint exception inside `NSToolbarConfigPanel` while it snapshots the `.searchable()`
    /// search field for the palette preview (crash reports 2026-10-28, `-[NSToolbar _showConfigPanel]`
    /// → `NSToolbarCollectionViewItem.snapShotItemWithAvailableSize:isActive:` → constraint engine
    /// exception). This reproduced with `allowsUserCustomization` both on and off, and from both the
    /// native right-click menu and a programmatic `runCustomizationPalette` call — the crash doesn't
    /// depend on how the panel is reached, only on it being reachable at all. The only reliable fix is
    /// to never build a toolbar AppKit considers customizable in the first place, which is what
    /// dropping `id:` here does. The cost: no drag-to-reorder, no remove/restore-defaults, no
    /// draggable Space item — all genuinely unavailable on this OS build, not just hidden.
    @ToolbarContentBuilder
    private var mainToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { model.requestNewProject() } label: {
                Label("New Project", systemImage: "doc.badge.plus")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: openPanel) {
                Label("Open…", systemImage: "folder")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: saveOrPrompt) {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(model.tasks.isEmpty || model.isSaving)
            .help("Writes Project XML — the only format MPXJ.Net can write back out. The first save for a file opened in another format (.mpp, .gan, …) prompts for a new .xml location; Save As… (⇧⌘S) is in the File menu")
        }
        ToolbarItem(placement: .automatic) {
            Menu {
                Button("Add Task Before") { requestAddBeforeSelected() }
                Button("Add Task After") { requestAddAfterSelected() }
            } label: {
                Label("Add Task", systemImage: "plus")
            }
            .disabled(model.selectedTaskId == nil || viewMode != .gantt)
        }
        ToolbarItem(placement: .automatic) {
            Button(action: requestDeleteSelected) {
                Label("Delete Task", systemImage: "trash")
            }
            .disabled(model.selectedTaskId == nil || viewMode != .gantt)
        }
        viewToolbarItems
    }

    /// Split out of mainToolbarItems — adding the Budget item to the single already-large builder
    /// above pushed the type checker over its limit again ("unable to type-check this expression in
    /// reasonable time"), the same class of real compiler issue mainToolbarItems' own doc comment
    /// already describes; two smaller builder chains concatenated back together type-check fine where
    /// one big one didn't.
    @ToolbarContentBuilder
    private var viewToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button(action: zoomOut) {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .disabled(!viewMode.supportsZoom)
        }
        ToolbarItem(placement: .automatic) {
            Button(action: zoomIn) {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .disabled(!viewMode.supportsZoom)
        }
        ToolbarItem(placement: .automatic) {
            // A plain Button with `.tint`/`.buttonStyle` doesn't reliably show a filled "on" state
            // once it's wrapped in the toolbar's own chrome (tried both for Critical Path below —
            // neither painted a visible background). `Toggle` + `.toggleStyle(.button)` is the
            // toolbar-native way to represent this: the system renders the filled state itself
            // instead of us faking it with button styling.
            Toggle(isOn: fitToWindowBinding) {
                Label("Fit to Window", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .toggleStyle(.button)
            .disabled(!viewMode.supportsZoom)
            .help("Fit the full date range (or diagram) to the pane, and keep fitting as it's resized")
        }
        ToolbarItem(placement: .automatic) {
            Toggle(isOn: $showCriticalPath) {
                Label("Critical Path", systemImage: "exclamationmark.triangle")
            }
            .toggleStyle(.button)
            .tint(.green)
            .help("Highlight the critical path in red across every view")
        }
        ToolbarItem(placement: .automatic) {
            budgetToolbarButton
        }
        ToolbarItem(placement: .automatic) {
            Button { showingCalendarsSheet = true } label: {
                Label("Calendars", systemImage: "calendar.badge.clock")
            }
            .disabled(model.tasks.isEmpty)
            .help("Working-time calendars — weekly pattern and holiday exceptions")
            .sheet(isPresented: $showingCalendarsSheet) {
                CalendarsView(model: model)
            }
        }
    }

    @ViewBuilder
    private func ganttSplitView(range: ClosedRange<Date>) -> some View {
        GeometryReader { geo in
            // 12 matches ResizableDivider's own fixed `.frame(width: 12)`.
            let paneWidth = max(0, geo.size.width - leftPaneWidth - 12)
            let effectivePixelsPerDay = fitToWindow
                ? ganttFitPixelsPerDay(range: range, paneWidth: paneWidth) : pixelsPerDay
            HStack(spacing: 0) {
                SyncedScrollHost(
                    content: TaskListPane(
                        title: model.title, tasks: model.tasks, resources: model.resources, tasksVersion: model.tasksVersion,
                        // Selecting a row from the task list also scrolls the Gantt pane to match —
                        // the two panes otherwise scroll independently now (see GanttScrollSync).
                        selectedTaskId: model.selectedTaskId, onSelect: jumpToTask,
                        onEditName: { model.setName(taskId: $0, to: $1) },
                        onEditPercent: { model.setPercent(taskId: $0, to: $1) },
                        onEditDuration: { model.setDurationDays(taskId: $0, to: $1) },
                        onEditDateRange: { model.setDateRange(taskId: $0, start: $1, finish: $2) },
                        onEditPredecessors: { model.setPredecessors(taskId: $0, to: $1) },
                        onEditAssignments: { model.setAssignments(taskId: $0, to: $1) },
                        onEditNotes: { model.setNotes(taskId: $0, to: $1) },
                        onAddTaskBefore: { model.pendingTaskAction = .addBefore(taskId: $0) },
                        onAddTaskAfter: { model.pendingTaskAction = .addAfter(taskId: $0) },
                        onDeleteTask: { model.pendingTaskAction = .delete(taskId: $0) },
                        onJumpToTask: jumpToTask, showCriticalPath: showCriticalPath),
                    contentSize: CGSize(
                        width: TaskListPane.naturalWidth,
                        height: ganttContentHeight(taskCount: model.tasks.count)),
                    allowsHorizontalScroll: true,
                    sync: scrollSync,
                    role: .left
                )
                .frame(width: leftPaneWidth)
                ResizableDivider(
                    width: $leftPaneWidth, minWidth: 250, maxWidth: max(250, geo.size.width - 300))
                GanttChartPane(
                    tasks: model.tasks, tasksVersion: model.tasksVersion, range: range, pixelsPerDay: effectivePixelsPerDay,
                    // Clicking a bar directly selects without re-centering either pane — you're
                    // already looking at it, nothing needs to snap.
                    selectedTaskId: model.selectedTaskId, onSelect: { model.selectedTaskId = $0 },
                    sync: scrollSync, showCriticalPath: showCriticalPath)
                    .frame(maxWidth: .infinity)
            }
            .onAppear {
                ganttPaneWidth = paneWidth
                // Only on appear (switching into Gantt with an existing selection), not on every
                // selection change — that also fired on a plain click already inside this view,
                // which should just highlight the row, not re-center both panes on top of it.
                // Deferred a tick: onAppear can fire before SyncedScrollHost's makeNSView has
                // actually registered this pane's NSScrollViews with scrollSync, so calling
                // scrollToRow synchronously here could silently no-op on a still-nil scroll view —
                // which is exactly what "selected but not scrolled into view, and not in sync with
                // the other pane" looks like.
                DispatchQueue.main.async { scrollToCurrentSelection() }
            }
            .onChange(of: paneWidth) { ganttPaneWidth = paneWidth }
        }
    }

    /// Phase/summary rows excluded — same as the Windows app's default (its "Include summary tasks"
    /// menu item starts unchecked): a summary task's own dates just span its children's, so it adds a
    /// box with no real schedule of its own and no useful links, just clutter in an already-dense
    /// diagram. Computed fresh from model.tasks everywhere Network needs tasks, rather than filtering
    /// once and storing it, so it can never go stale relative to an edit.
    private var networkTasks: [GanttTask] { model.tasks.filter { !$0.isSummary } }

    @ViewBuilder
    private func networkDiagramView() -> some View {
        GeometryReader { geo in
            let tasks = networkTasks
            let nodes = NetworkLayout.nodes(for: tasks)
            let contentSize = NetworkLayout.contentSize(for: nodes)
            let effectiveScale = networkFitToWindow
                ? NetworkLayout.fitScale(contentSize: contentSize, paneSize: geo.size) : networkScale
            NetworkDiagramView(
                tasks: tasks, tasksVersion: model.tasksVersion, scale: effectiveScale,
                selectedTaskId: model.selectedTaskId, onSelect: { model.selectedTaskId = $0 },
                onZoom: applyNetworkZoom, showCriticalPath: showCriticalPath,
                onJumpToWBS: jumpToWBS,
                onDeleteRequest: { model.pendingTaskAction = .delete(taskId: $0) },
                onEditNotes: { model.setNotes(taskId: $0, to: $1) },
                notesText: { id in model.tasks.first(where: { $0.id == id })?.notes ?? "" },
                scrollTrigger: networkScrollTrigger,
                highlightColor: HighlightColor(rawValue: calendarSelectionColorName)?.color ?? .red)
                .onAppear {
                    networkPaneSize = geo.size
                    networkScrollTrigger += 1
                }
                .onChange(of: geo.size) { networkPaneSize = geo.size }
        }
    }

    private var calendarView: some View {
        CalendarView(
            tasks: model.tasks, resources: model.resources, showCriticalPath: showCriticalPath,
            selectedTaskId: model.selectedTaskId, onSelect: { model.selectedTaskId = $0 },
            highlightColor: HighlightColor(rawValue: calendarSelectionColorName)?.color ?? .red,
            onJumpToWBS: jumpToWBS,
            onDeleteRequest: { model.pendingTaskAction = .delete(taskId: $0) },
            onEditNotes: { model.setNotes(taskId: $0, to: $1) },
            onEditAssignments: { model.setAssignments(taskId: $0, to: $1) })
    }

    /// Selects the task and switches to the WBS/Gantt view — used by Calendar's double-click and
    /// right-click "Jump to WBS". The actual scroll-into-view happens in ganttSplitView's onAppear,
    /// not here: this runs before the Gantt view (and its NSScrollViews) exist for this switch, so
    /// scrolling here would race their construction. Also what "anything selected in the WBS should
    /// be focused on when switching to any view" relies on generally, not just for this jump.
    private func jumpToWBS(_ taskId: Int) {
        model.selectedTaskId = taskId
        viewMode = .gantt
    }

    private func jumpToTask(_ taskId: Int) {
        model.selectedTaskId = taskId
        if let index = model.tasks.firstIndex(where: { $0.id == taskId }) {
            scrollSync.scrollToRow(index)
        }
    }

    /// Part of "anything selected in the WBS should be focused on when switching to any view": for
    /// Gantt that means scrolling the selected row into view, same mechanism jumpToTask already uses.
    /// Called only from ganttSplitView's onAppear — i.e. only when *switching into* Gantt with an
    /// existing selection from elsewhere. Deliberately not on every selectedTaskId change: that also
    /// fired on a plain click already inside Gantt, forcing an unwanted re-center on top of a row
    /// that was already visible. A click within Gantt (on either pane) already has its own correct,
    /// narrower scroll behavior — jumpToTask for the task list, no scroll at all for a Gantt bar
    /// click — so this only needs to cover the "just arrived" case.
    private func scrollToCurrentSelection() {
        guard let id = model.selectedTaskId, let index = model.tasks.firstIndex(where: { $0.id == id }) else { return }
        scrollSync.scrollToRow(index)
    }

    /// Explains what a pending Add/Delete will renumber — same wording regardless of whether it was
    /// triggered by right-clicking a row or by the Task menu/keyboard shortcut on the selection.
    private func pendingActionMessage(_ action: PendingTaskAction) -> String {
        guard let task = model.tasks.first(where: { $0.id == action.taskId }) else { return "" }
        let scoped = task.outlineLevel > 1
        let wbsSection = task.wbs.split(separator: ".").first.map(String.init) ?? task.wbs
        switch action {
        case .addBefore, .addAfter:
            return scoped
                ? "This adds a task in WBS section \(wbsSection) and renumbers the other entries in that section. Numbers outside section \(wbsSection) stay the same."
                : "This adds a new top-level task, which renumbers every WBS section after it (2 becomes 3, and so on)."
        case .delete:
            return scoped
                ? "This removes the task and renumbers the remaining entries in WBS section \(wbsSection) to close the gap. Other sections stay the same."
                : "This removes a top-level task, which renumbers every WBS section after it to close the gap."
        }
    }

    /// Arrow-key row navigation, driven by SelectionKeyCatcher below. Clamped at the ends (no
    /// wraparound) and scrolls the moved-to row into view, same as jumping to a predecessor.
    private func moveSelection(by delta: Int) {
        guard !model.tasks.isEmpty else { return }
        let nextIndex: Int
        if let currentIndex = model.tasks.firstIndex(where: { $0.id == model.selectedTaskId }) {
            nextIndex = min(max(0, currentIndex + delta), model.tasks.count - 1)
        } else {
            nextIndex = 0
        }
        model.selectedTaskId = model.tasks[nextIndex].id
        scrollSync.scrollToRow(nextIndex)
    }

    /// These back the toolbar's +/− buttons — same pendingTaskAction + confirmation dialog as a
    /// row's right-click menu or the Task menu's keyboard shortcuts, just one more way in.
    private func requestAddBeforeSelected() {
        guard let id = model.selectedTaskId else { return }
        model.pendingTaskAction = .addBefore(taskId: id)
    }

    private func requestAddAfterSelected() {
        guard let id = model.selectedTaskId else { return }
        model.pendingTaskAction = .addAfter(taskId: id)
    }

    private func requestDeleteSelected() {
        guard let id = model.selectedTaskId else { return }
        model.pendingTaskAction = .delete(taskId: id)
    }

    private var networkContentSize: CGSize {
        NetworkLayout.contentSize(for: NetworkLayout.nodes(for: networkTasks))
    }

    /// Fit to Window is really two independent booleans (fitToWindow for Gantt, networkFitToWindow
    /// for Network) — this presents whichever one matches the active view as a single Bool the
    /// toolbar's Toggle can bind to directly.
    private var fitToWindowBinding: Binding<Bool> {
        Binding(
            get: { viewMode == .gantt ? fitToWindow : networkFitToWindow },
            set: { newValue in
                switch viewMode {
                case .gantt: fitToWindow = newValue
                case .network: networkFitToWindow = newValue
                case .timeline, .calendar, .resources: break
                }
            })
    }

    /// Zooming manually always wins over Fit — same as clicking a manual zoom button in
    /// Preview/Keynote while "Zoom to Fit" is on. Seeds the zoom level from Fit's current value first
    /// so the step feels continuous instead of jumping back to a stale pre-Fit number. One of these
    /// per zoomable view (see ViewMode.supportsZoom); zoomOut/zoomIn/the Fit button below dispatch to
    /// whichever one matches the active view.
    private func exitGanttFitIfNeeded() {
        guard fitToWindow else { return }
        if let range = model.dateRange {
            pixelsPerDay = ganttFitPixelsPerDay(range: range, paneWidth: ganttPaneWidth)
        }
        fitToWindow = false
    }

    private func exitNetworkFitIfNeeded() {
        guard networkFitToWindow else { return }
        networkScale = NetworkLayout.fitScale(contentSize: networkContentSize, paneSize: networkPaneSize)
        networkFitToWindow = false
    }

    private func zoomOut() {
        switch viewMode {
        case .gantt:
            exitGanttFitIfNeeded()
            pixelsPerDay = max(1, pixelsPerDay / 1.4)
        case .network:
            exitNetworkFitIfNeeded()
            networkScale = max(0.2, networkScale / 1.3)
        case .timeline, .calendar, .resources:
            break
        }
    }

    private func zoomIn() {
        switch viewMode {
        case .gantt:
            exitGanttFitIfNeeded()
            pixelsPerDay = min(60, pixelsPerDay * 1.4)
        case .network:
            exitNetworkFitIfNeeded()
            networkScale = min(3, networkScale * 1.3)
        case .timeline, .calendar, .resources:
            break
        }
    }

    /// Scroll wheel/trackpad scroll and pinch both drive this (see NetworkScrollHost) — same clamp
    /// range and fit-exit behavior as the toolbar's Zoom Out/In, just continuous instead of stepped.
    private func applyNetworkZoom(factor: CGFloat) {
        exitNetworkFitIfNeeded()
        networkScale = min(3, max(0.2, networkScale * factor))
    }

    /// Restores whatever Icon Only/Icon and Text choice was last picked (via the toolbar's own
    /// right-click menu — there's no in-app control for this, on purpose: see mainToolbarItems' doc
    /// comment for why nothing here should touch `NSToolbar` customization state).
    ///
    /// Does NOT use AppKit's own autosave (`autosavesConfiguration`/"NSToolbar Configuration
    /// <identifier>" in UserDefaults) — that depends on a *stable* `NSToolbar.identifier`, which
    /// requires `.toolbar(id:)`, which is exactly what mainToolbarItems deliberately stopped using to
    /// kill the customize-panel crash. Without it, SwiftUI assigns a fresh identifier every launch, so
    /// AppKit dutifully saves the display mode under a key that's never the same key twice — it
    /// silently "worked" (no crash, no error) while just never actually persisting anything, which is
    /// exactly as easy to miss as it sounds (caught only when told directly that the setting wasn't
    /// sticking). This keeps its own constant-keyed value instead, independent of whatever identifier
    /// SwiftUI hands out — written by persistToolbarDisplayModeNow, not live here.
    ///
    /// `asyncAfter` rather than acting synchronously in `onAppear`: at that point the window's real
    /// `NSToolbar` isn't reliably attached/findable yet (SwiftUI builds it slightly after the view
    /// itself appears), so an immediate lookup here would just silently find nothing most of the time.
    private func restoreToolbarDisplayMode() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let toolbar = NSApp.windows.compactMap(\.toolbar).first,
                  let savedRaw = UserDefaults.standard.object(forKey: Self.toolbarDisplayModeKey) as? Int,
                  let savedMode = NSToolbar.DisplayMode(rawValue: UInt(savedRaw))
            else { return }
            toolbar.displayMode = savedMode
        }
    }

    /// Writes the toolbar's current Icon Only/Icon and Text choice to our own key — see
    /// restoreToolbarDisplayMode's doc comment for why this exists instead of a live KVO observation.
    private func persistToolbarDisplayModeNow() {
        guard let toolbar = NSApp.windows.compactMap(\.toolbar).first else { return }
        UserDefaults.standard.set(Int(toolbar.displayMode.rawValue), forKey: Self.toolbarDisplayModeKey)
    }

    private static let toolbarDisplayModeKey = "toolbarDisplayModePreference"

    /// Backs both the toolbar's Save button and the File menu's Save item — see
    /// AppModel.needsSaveAsPath for why a plain save sometimes still needs to prompt.
    private func saveOrPrompt() {
        if model.needsSaveAsPath {
            saveAsPanel()
        } else {
            model.save()
        }
    }

    private func saveAsPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xml")].compactMap { $0 }
        panel.nameFieldStringValue = (model.title.isEmpty ? "Untitled" : model.title) + ".xml"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            model.saveAs(to: url.path)
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        // MPXJ's UniversalProjectReader (used by the Helper's Open) auto-detects format from file
        // content, not extension — the extension list here only controls what's selectable in this
        // dialog. Covers every reader MPXJ.Net 16.10.0 actually ships (confirmed from the assembly)
        // that's a plain single file, not a database/server connection (Primavera/SureTrak database
        // readers, PWA web services, etc. are out of scope — those need more than "open a file").
        panel.allowedContentTypes = [
            "mpp", "mpt", "mpx", "xml", // Microsoft Project (binary, template, MPX, Project XML/MSPDI)
            "gan", // GanttProject
            "planner", // Planner
            "pp", // Asta Powerproject
            "xer", // Primavera P6 XER
            "pmxml", // Primavera PM XML
            "ppx", // Phoenix
            "stx", // SureTrak STX
            "pod", // ProjectLibre
            "cdp", // ConceptDraw Project
            "edp", // Edraw Project
        ].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.openFile(at: url.path)
        }
    }
}

/// A zero-size AppKit view that exists only to hold keyboard focus for arrow-key row navigation.
/// Same lesson as FocusedTextField in TaskListPane (SwiftUI's own @FocusState doesn't reliably reach
/// real AppKit first-responder status in this custom NSHostingView-in-NSScrollView setup), but the
/// opposite direction: a text field grabs focus proactively the moment it appears, while this view
/// should only take focus right when the selection changes — and should readily *lose* it the moment
/// something else (a cell's text field, a popover control) claims first responder the normal AppKit
/// way, so arrow keys inside a predecessor/date popover still do whatever that control expects
/// instead of silently moving the row selection underneath it.
private struct SelectionKeyCatcher: NSViewRepresentable {
    let selectedTaskId: Int?
    let onMove: (Int) -> Void

    func makeNSView(context: Context) -> KeyCatcherNSView {
        let view = KeyCatcherNSView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ nsView: KeyCatcherNSView, context: Context) {
        nsView.onMove = onMove
        if context.coordinator.lastSelectedTaskId != selectedTaskId {
            context.coordinator.lastSelectedTaskId = selectedTaskId
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastSelectedTaskId: Int? }
}

private final class KeyCatcherNSView: NSView {
    var onMove: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: onMove?(1) // down arrow
        case 126: onMove?(-1) // up arrow
        default: super.keyDown(with: event)
        }
    }
}
