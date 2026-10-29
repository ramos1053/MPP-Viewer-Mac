import SwiftUI

/// The Resource Sheet: every resource in the project, in the same column set Microsoft Project's own
/// default Resource Sheet view shows. Everything is editable except Base Calendar — this app has no
/// calendar-management UI to guarantee a typed name actually matches a calendar that exists in the
/// file, so that one stays read-only. Max Units/Std Rate/Ovt Rate/Cost per Use write a single flat
/// CostRateTable/AvailabilityTable entry spanning MPXJ's own "NA" date range (see Helper's
/// ApplyResourceFields) — this app doesn't support a rate that changes over time, just one flat value.
///
/// Built on SwiftUI's native `Table` (sortable, resizable columns, alternating rows, selection) rather
/// than a hand-rolled HStack grid — a plain text table reads as a debug dump, and this is meant to
/// read as an actual Resource Sheet: a colored initials avatar per resource, a type icon, and an
/// allocation bar for Max Units instead of a bare percentage.
///
/// No ToolbarContentDivider of its own: this view is swapped in as *content* under ContentView's
/// single shared toolbar (see ContentView's view-mode switch), which already draws that divider once
/// for whichever pane is showing. A pane that owned its own separate window/toolbar would draw one.
/// Add/Delete Resource live in this view's own header row rather than in that shared toolbar — unlike
/// Add/Delete Task, which needs to work identically from a row's context menu, the Task menu, and the
/// toolbar all at once, this has exactly one entry point, so the cross-view PendingTaskAction-style
/// machinery would be pure overhead here.
struct ResourceSheetView: View {
    @ObservedObject var model: AppModel
    /// Double-click-the-avatar → "Jump to WBS" inside the detail sheet's engagement list routes
    /// through here, same callback shape Calendar/Network already use.
    let onJumpToWBS: (Int) -> Void

    @State private var sortOrder = [KeyPathComparator(\ResourceDto.name)]
    @State private var selection: Set<Int> = []
    @State private var pendingDelete = false
    /// Which resource's detail sheet is open, if any — looked up fresh from `model.resources` each
    /// render (not a captured snapshot), so edits made inside the sheet show up immediately both
    /// there and in the table behind it.
    @State private var detailResourceId: Int?

    private var resources: [ResourceDto] { model.resources }
    private var sorted: [ResourceDto] { resources.sorted(using: sortOrder) }

    /// `.sheet(item:)` needs a `Binding<ResourceDto?>`, not just the `Int?` id this view actually
    /// tracks — re-resolved from `model.resources` on every access (via `get`) rather than capturing
    /// the resource once, so the sheet keeps reflecting live edits instead of showing a stale copy.
    private var detailResourceBinding: Binding<ResourceDto?> {
        Binding(
            get: { detailResourceId.flatMap { id in resources.first { $0.uniqueId == id } } },
            set: { detailResourceId = $0?.uniqueId })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if resources.isEmpty {
                ContentUnavailableView {
                    Label("No Resources", systemImage: "person.2")
                } description: {
                    Text("This project has no resources defined.")
                } actions: {
                    Button("Add Resource") { model.addResource() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(sorted, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { resource in
                        HStack(spacing: 8) {
                            avatar(for: resource)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { detailResourceId = resource.uniqueId }
                                .help("Double-click for details")
                            editableText(resource.name, width: 140) { model.setResourceName(id: resource.uniqueId, to: $0) }
                        }
                    }
                    .width(min: 170, ideal: 210)

                    TableColumn("Type", value: \.type) { resource in
                        typePicker(for: resource)
                    }
                    .width(min: 110, ideal: 130)

                    TableColumn("Group", value: \.group) { resource in
                        editableText(resource.group, width: 90, placeholder: "—") { model.setResourceGroup(id: resource.uniqueId, to: $0) }
                    }
                    .width(min: 90, ideal: 120)

                    TableColumn("Max Units", value: \.maxUnits) { resource in
                        maxUnitsBar(resource)
                    }
                    .width(min: 100, ideal: 130)

                    TableColumn("Std Rate", value: \.standardRateAmount) { resource in
                        rateCell(
                            amount: resource.standardRateAmount, unit: resource.standardRateUnit,
                            onApply: { model.setResourceStandardRate(id: resource.uniqueId, amount: $0, unit: $1) })
                    }
                    .width(min: 80, ideal: 95)

                    TableColumn("Ovt Rate", value: \.overtimeRateAmount) { resource in
                        rateCell(
                            amount: resource.overtimeRateAmount, unit: resource.overtimeRateUnit,
                            onApply: { model.setResourceOvertimeRate(id: resource.uniqueId, amount: $0, unit: $1) })
                    }
                    .width(min: 80, ideal: 95)

                    TableColumn("Cost/Use", value: \.costPerUse) { resource in
                        editableNumber(resource.costPerUse, width: 60, format: "$%.2f") {
                            model.setResourceCostPerUse(id: resource.uniqueId, to: $0)
                        }
                    }
                    .width(min: 70, ideal: 85)

                    TableColumn("Accrue At", value: \.accrueAt) { resource in
                        accruePicker(for: resource)
                    }
                    .width(min: 90, ideal: 100)

                    TableColumn("Base Calendar", value: \.baseCalendar)
                        .width(min: 90, ideal: 120)

                    TableColumn("Code", value: \.code) { resource in
                        editableText(resource.code, width: 50, placeholder: "—") { model.setResourceCode(id: resource.uniqueId, to: $0) }
                    }
                    .width(min: 55, ideal: 70)
                }
                .alternatingRowBackgrounds(.enabled)
            }
        }
        .alert("Delete Resource", isPresented: $pendingDelete) {
            Button("Delete", role: .destructive) {
                for id in selection { model.deleteResource(id) }
                selection.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(selection.count == 1
                ? "This removes the resource and unassigns it from every task."
                : "This removes \(selection.count) resources and unassigns them from every task.")
        }
        .sheet(item: detailResourceBinding) { resource in
            ResourceDetailView(
                resource: resource, tasks: model.tasks, budgetCost: model.budgetCost,
                onEditName: { model.setResourceName(id: resource.uniqueId, to: $0) },
                onEditType: { model.setResourceType(id: resource.uniqueId, to: $0) },
                onEditInitials: { model.setResourceInitials(id: resource.uniqueId, to: $0) },
                onEditGroup: { model.setResourceGroup(id: resource.uniqueId, to: $0) },
                onEditCode: { model.setResourceCode(id: resource.uniqueId, to: $0) },
                onEditAccrueAt: { model.setResourceAccrueAt(id: resource.uniqueId, to: $0) },
                onEditMaxUnits: { model.setResourceMaxUnits(id: resource.uniqueId, to: $0) },
                onEditStandardRate: { model.setResourceStandardRate(id: resource.uniqueId, amount: $0, unit: $1) },
                onEditOvertimeRate: { model.setResourceOvertimeRate(id: resource.uniqueId, amount: $0, unit: $1) },
                onEditCostPerUse: { model.setResourceCostPerUse(id: resource.uniqueId, to: $0) },
                onJumpToWBS: { taskId in
                    detailResourceId = nil
                    onJumpToWBS(taskId)
                },
                onClose: { detailResourceId = nil })
        }
    }

    // ---- header -------------------------------------------------------------------------------

    private var header: some View {
        HStack {
            Text("\(resources.count) resource\(resources.count == 1 ? "" : "s")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button { model.addResource() } label: {
                Label("Add Resource", systemImage: "person.badge.plus")
            }
            Button(role: .destructive) { pendingDelete = true } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.gray.opacity(0.2)).frame(height: 0.5)
        }
    }

    // ---- editable cells -------------------------------------------------------------------------

    /// Double-click-to-edit, same convention as every editable cell in TaskListPane — a plain label
    /// until double-clicked, then a text field; Return or focus-loss commits, Escape cancels.
    private func editableText(_ text: String, width: CGFloat, placeholder: String = "", onCommit: @escaping (String) -> Void) -> some View {
        ResourceTextCell(text: text, width: width, placeholder: placeholder, onCommit: onCommit)
    }

    /// Double-click-to-edit, numeric sibling of `editableText` — same shape (plain label until
    /// double-clicked, then a field; Return/focus-loss commits), formatted with `format` for display.
    private func editableNumber(_ value: Double, width: CGFloat, format: String, onCommit: @escaping (Double) -> Void) -> some View {
        ResourceNumberCell(value: value, width: width, format: format, onCommit: onCommit)
    }

    /// A rate's amount and unit are edited together, not as two separate cells — double-click opens a
    /// small popover (same convention as PredecessorEditor/AssignmentEditor: local state, Apply/Cancel)
    /// with an amount field and a unit picker, since "$85.50" alone is meaningless without its unit
    /// and a narrow table column has no room for both an inline text field and a menu at once.
    private func rateCell(amount: Double, unit: String, onApply: @escaping (Double, String) -> Void) -> some View {
        RateCell(amount: amount, unit: unit, onApply: onApply)
    }

    private func typePicker(for resource: ResourceDto) -> some View {
        TypeCell(type: resource.type, onApply: { model.setResourceType(id: resource.uniqueId, to: $0) })
    }

    private func accruePicker(for resource: ResourceDto) -> some View {
        Menu {
            ForEach(Self.accrueTypes, id: \.self) { accrueAt in
                Button(accrueAt) { model.setResourceAccrueAt(id: resource.uniqueId, to: accrueAt) }
            }
        } label: {
            Text(resource.accrueAt.isEmpty ? "—" : resource.accrueAt)
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private static let accrueTypes = ["Start", "End", "Prorated"]

    // ---- cell styling -----------------------------------------------------------------------------

    private func avatar(for resource: ResourceDto) -> some View {
        let color = Self.color(for: resource.name)
        let gradient = LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        let circle = Circle().fill(gradient).frame(width: 24, height: 24)
        let initialsText = Text(initials(for: resource)).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white)
        return circle
            .overlay(initialsText)
            .shadow(color: color.opacity(0.35), radius: 1.5, x: 0, y: 1)
    }

    private func initials(for resource: ResourceDto) -> String {
        if !resource.initials.isEmpty { return String(resource.initials.prefix(2)).uppercased() }
        let parts = resource.name.split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first).map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    /// The bar is still a pure visual (not itself a drag/slider control — a 0-200%+ range doesn't map
    /// cleanly onto a short bar's width for dragging); double-clicking the percentage number next to
    /// it opens the same numeric edit field every other numeric cell here uses.
    private func maxUnitsBar(_ resource: ResourceDto) -> some View {
        let value = resource.maxUnits
        let fraction = max(0, value / 100)
        let overAllocated = fraction > 1
        let barColor: Color = overAllocated ? .orange : .accentColor
        let track = Capsule().fill(Color.primary.opacity(0.08))
        let fillBar = GeometryReader { geo in
            ZStack(alignment: .leading) {
                track
                Capsule()
                    .fill(barColor.gradient)
                    .frame(width: geo.size.width * min(fraction, 1))
            }
        }
        .frame(height: 6)
        return HStack(spacing: 7) {
            fillBar
            editableNumber(value, width: 38, format: "%.0f%%") {
                model.setResourceMaxUnits(id: resource.uniqueId, to: $0)
            }
            .foregroundStyle(overAllocated ? .orange : .secondary)
        }
    }

    private static let avatarPalette: [Color] = [.blue, .purple, .teal, .indigo, .pink, .brown, .cyan, .mint, .orange]

    private static func color(for name: String) -> Color {
        guard !name.isEmpty else { return .accentColor }
        var hasher = Hasher()
        hasher.combine(name)
        return avatarPalette[abs(hasher.finalize()) % avatarPalette.count]
    }

    private static func trimmed(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }
}

/// Double-click-to-edit text cell for the Resource Sheet's Table — same shape as TaskListPane's
/// EditableCell, kept as its own small type here since Table cells have no access to that one
/// (private to TaskListPane) and the selection/row-click handling a plain table row already gives
/// for free means this needs none of EditableCell's onSelect plumbing.
struct ResourceTextCell: View {
    let text: String
    let width: CGFloat
    var placeholder: String = ""
    let onCommit: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .onExitCommand { isEditing = false }
                    .onAppear { isFocused = true }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commit() }
                    }
            } else {
                Text(text.isEmpty ? placeholder : text)
                    .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        draft = text
                        isEditing = true
                    }
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        onCommit(draft)
    }
}

/// Numeric sibling of `ResourceTextCell` — same double-click-to-edit shape, but the displayed label
/// is a `format`-ted number (e.g. "100%", "$0.50") and the committed draft is parsed back to a Double,
/// silently ignoring an unparseable edit (reverting to the last real value) rather than writing NaN.
struct ResourceNumberCell: View {
    let value: Double
    let width: CGFloat
    let format: String
    let onCommit: (Double) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .onExitCommand { isEditing = false }
                    .onAppear { isFocused = true }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commit() }
                    }
            } else {
                Text(String(format: format, value))
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        draft = Self.trimmed(value)
                        isEditing = true
                    }
            }
        }
        .frame(width: width, alignment: .trailing)
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        if let parsed = Double(draft.trimmingCharacters(in: .whitespaces)) {
            onCommit(parsed)
        }
    }

    private static func trimmed(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }
}

/// A rate's amount + unit, edited together in a small popover — double-click the formatted "$X/unit"
/// label to open it. Local state until Apply, same rationale as every other popover editor in this
/// app (PredecessorEditor, AssignmentEditor): a half-typed amount shouldn't push through AppModel on
/// every keystroke.
/// The Type menu button + badge, plus a "Custom…" item that opens a small text-entry popover for a
/// type not in the standard four — MS Project (and MPXJ's Resource.Type) only has Work/Material/
/// Cost/NonLabor as real categories, so a custom label is stored separately (Helper's Text1, see
/// ApplyResourceFields) and shown here in place of the enum name whenever it's set.
struct TypeCell: View {
    let type: String
    let onApply: (String) -> Void

    @State private var showingCustomEditor = false
    @State private var draftCustom = ""

    private static let types = ["Work", "Material", "Cost", "NonLabor"]

    var body: some View {
        Menu {
            ForEach(Self.types, id: \.self) { t in
                Button(t) { onApply(t) }
            }
            Divider()
            Button("Custom…") {
                draftCustom = Self.types.contains(type) ? "" : type
                showingCustomEditor = true
            }
        } label: {
            badge
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .popover(isPresented: $showingCustomEditor) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Custom Type").font(.headline)
                TextField("e.g. Contractor", text: $draftCustom)
                    .frame(width: 180)
                    .onSubmit(applyCustom)
                HStack {
                    Button("Cancel", role: .cancel) { showingCustomEditor = false }
                    Spacer()
                    Button("Apply", action: applyCustom)
                        .keyboardShortcut(.defaultAction)
                        .disabled(draftCustom.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
            .frame(minWidth: 220)
        }
    }

    private var badge: some View {
        let lower = type.lowercased()
        let isKnown = Self.types.contains(type)
        let icon = !isKnown ? "sparkles"
            : lower.contains("cost") ? "dollarsign.circle.fill"
            : lower.contains("material") ? "shippingbox.fill"
            : "person.fill"
        let tint: Color = !isKnown ? .purple : lower.contains("cost") ? .green : lower.contains("material") ? .orange : .accentColor
        return Label(type.isEmpty ? "—" : type, systemImage: icon)
            .font(.system(size: 11))
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
    }

    private func applyCustom() {
        let trimmed = draftCustom.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onApply(trimmed)
        showingCustomEditor = false
    }
}

struct RateCell: View {
    let amount: Double
    let unit: String
    let onApply: (Double, String) -> Void

    @State private var showingEditor = false
    @State private var draftAmount = ""
    @State private var draftUnit = "Hours"

    private static let units = ["Hours", "Days", "Weeks", "Months", "Years"]
    private static let unitAbbreviations: [String: String] = [
        "Hours": "h", "Days": "d", "Weeks": "wk", "Months": "mo", "Years": "yr",
    ]

    var body: some View {
        Text("$\(Self.trimmed(amount))/\(Self.unitAbbreviations[unit] ?? "h")")
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                draftAmount = Self.trimmed(amount)
                draftUnit = unit
                showingEditor = true
            }
            .popover(isPresented: $showingEditor) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Rate").font(.headline)
                    HStack(spacing: 6) {
                        Text("$")
                        TextField("Amount", text: $draftAmount)
                            .frame(width: 70)
                        Text("per")
                        Picker("", selection: $draftUnit) {
                            ForEach(Self.units, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    }
                    HStack {
                        Button("Cancel", role: .cancel) { showingEditor = false }
                        Spacer()
                        Button("Apply") {
                            if let parsed = Double(draftAmount.trimmingCharacters(in: .whitespaces)) {
                                onApply(parsed, draftUnit)
                            }
                            showingEditor = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(12)
                .frame(minWidth: 240)
            }
    }

    private static func trimmed(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }
}
