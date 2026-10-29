import SwiftUI

/// The Resource Sheet's double-click inspector: a single resource's full profile, editable in place
/// (reuses the exact same cell types as the sheet's own table — ResourceTextCell/ResourceNumberCell/
/// TypeCell/RateCell — so editing here and editing in the table row behave identically, just one
/// editor, two entry points, same convention as AssignmentEditor's reuse between TaskListPane and
/// ResourceTimelineView), plus read-only rollups this app actually has real data for: hours scheduled
/// vs. completed, cost to date, a progress breakdown by WBS section, and the resource's full list of
/// task assignments ("scheduled engagements").
struct ResourceDetailView: View {
    let resource: ResourceDto
    let tasks: [GanttTask]
    let budgetCost: Double
    let onEditName: (String) -> Void
    let onEditType: (String) -> Void
    let onEditInitials: (String) -> Void
    let onEditGroup: (String) -> Void
    let onEditCode: (String) -> Void
    let onEditAccrueAt: (String) -> Void
    let onEditMaxUnits: (Double) -> Void
    let onEditStandardRate: (Double, String) -> Void
    let onEditOvertimeRate: (Double, String) -> Void
    let onEditCostPerUse: (Double) -> Void
    let onJumpToWBS: (Int) -> Void
    let onClose: () -> Void

    private static let accrueTypes = ["Start", "End", "Prorated"]

    private var cost: BudgetCalculator.ResourceCost {
        BudgetCalculator.resourceCost(for: resource.uniqueId, tasks: tasks, resourcesById: [resource.uniqueId: resource])
    }

    private var hourlyRate: Double {
        BudgetCalculator.hourlyEquivalent(amount: resource.standardRateAmount, unit: resource.standardRateUnit)
    }

    private var engagements: [ResourceTimelineLayout.Bar] {
        ResourceTimelineLayout.bars(for: resource.uniqueId, in: tasks)
            .sorted { ($0.task.start ?? .distantPast) < ($1.task.start ?? .distantPast) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    profileFields
                    statsRow
                    progressSection
                    engagementsSection
                }
                .padding(20)
            }
        }
        .frame(width: 480, height: 620)
    }

    // ---- header -----------------------------------------------------------------------------------

    private var header: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(resource.name.isEmpty ? "Unnamed Resource" : resource.name)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text(resource.group.isEmpty ? resource.type : "\(resource.type) · \(resource.group)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    private var avatar: some View {
        let color = Self.avatarColor(for: resource.name)
        let gradient = LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        let letters = initials
        return Circle().fill(gradient).frame(width: 48, height: 48)
            .overlay(Text(letters).font(.system(size: 17, weight: .bold)).foregroundStyle(.white))
            .shadow(color: color.opacity(0.4), radius: 3, x: 0, y: 2)
    }

    private var initials: String {
        if !resource.initials.isEmpty { return String(resource.initials.prefix(2)).uppercased() }
        let parts = resource.name.split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first).map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    // ---- editable profile fields --------------------------------------------------------------------

    private var profileFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Profile")
            fieldRow("Name") { ResourceTextCell(text: resource.name, width: 220, onCommit: onEditName) }
            fieldRow("Type") { TypeCell(type: resource.type, onApply: onEditType) }
            fieldRow("Initials") { ResourceTextCell(text: resource.initials, width: 220, placeholder: "—", onCommit: onEditInitials) }
            fieldRow("Group") { ResourceTextCell(text: resource.group, width: 220, placeholder: "—", onCommit: onEditGroup) }
            fieldRow("Code") { ResourceTextCell(text: resource.code, width: 220, placeholder: "—", onCommit: onEditCode) }
            fieldRow("Accrue At") {
                Menu {
                    ForEach(Self.accrueTypes, id: \.self) { accrueAt in
                        Button(accrueAt) { onEditAccrueAt(accrueAt) }
                    }
                } label: {
                    Text(resource.accrueAt.isEmpty ? "—" : resource.accrueAt).font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            fieldRow("Max Units") { ResourceNumberCell(value: resource.maxUnits, width: 220, format: "%.0f%%", onCommit: onEditMaxUnits) }
            fieldRow("Std Rate") { RateCell(amount: resource.standardRateAmount, unit: resource.standardRateUnit, onApply: onEditStandardRate) }
            fieldRow("Ovt Rate") { RateCell(amount: resource.overtimeRateAmount, unit: resource.overtimeRateUnit, onApply: onEditOvertimeRate) }
            fieldRow("Cost/Use") { ResourceNumberCell(value: resource.costPerUse, width: 220, format: "$%.2f", onCommit: onEditCostPerUse) }
        }
    }

    private func fieldRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
    }

    // ---- stats --------------------------------------------------------------------------------------

    private var statsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Time & Cost")
            HStack(spacing: 10) {
                statTile("Scheduled Hours", Self.trimmedHours(cost.scheduledHours), icon: "clock", tint: .blue)
                statTile("Completed Hours", Self.trimmedHours(cost.completedHours), icon: "checkmark.circle", tint: .green)
                statTile("Hourly Rate", Self.currency(hourlyRate) + "/h", icon: "dollarsign.circle", tint: .purple)
            }
            HStack(spacing: 10) {
                statTile("Cost to Date", Self.currency(cost.earnedCost), icon: "chart.line.uptrend.xyaxis", tint: .orange)
                statTile("Planned Cost", Self.currency(cost.plannedCost), icon: "flag.checkered", tint: .secondary)
                if budgetCost > 0 {
                    statTile("Of Project Budget", String(format: "%.1f%%", cost.earnedCost / budgetCost * 100), icon: "chart.pie", tint: .indigo)
                }
            }
        }
    }

    private func statTile(_ label: String, _ value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint)
            Text(value).font(.system(size: 14, weight: .bold, design: .rounded))
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.08)))
    }

    // ---- progress by section --------------------------------------------------------------------------

    /// What fraction of this resource's scheduled hours falls under each top-level WBS section —
    /// same hashed-color convention Calendar/Team mode already use for section color, so a section
    /// reads the same color here as it does everywhere else bars are colored by WBS.
    private var progressBySection: [(section: String, hours: Double, color: Color)] {
        var hoursBySection: [String: Double] = [:]
        for bar in engagements {
            let section = bar.task.wbs.split(separator: ".").first.map(String.init) ?? bar.task.wbs
            let hours = bar.task.durationDays * 8 * (bar.assignment.units / 100)
            hoursBySection[section, default: 0] += hours
        }
        return hoursBySection
            .map { (section: $0.key, hours: $0.value, color: Self.sectionColor(for: $0.key)) }
            .sorted { $0.hours > $1.hours }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Overall Progress")
            let total = max(0.001, progressBySection.reduce(0) { $0 + $1.hours })
            if progressBySection.isEmpty {
                Text("No scheduled hours yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(progressBySection, id: \.section) { entry in
                            entry.color.frame(width: geo.size.width * (entry.hours / total))
                        }
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())

                ForEach(progressBySection.prefix(5), id: \.section) { entry in
                    HStack(spacing: 6) {
                        Circle().fill(entry.color).frame(width: 7, height: 7)
                        Text("WBS \(entry.section)").font(.caption)
                        Spacer()
                        Text(String(format: "%.0f%%", entry.hours / total * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // ---- scheduled engagements --------------------------------------------------------------------

    private var engagementsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Scheduled Engagements (\(engagements.count))")
            if engagements.isEmpty {
                Text("Not assigned to any tasks.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(engagements) { bar in
                        engagementRow(bar)
                        if bar.id != engagements.last?.id {
                            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5)
                        }
                    }
                }
            }
        }
    }

    private func engagementRow(_ bar: ResourceTimelineLayout.Bar) -> some View {
        let task = bar.task
        let unitsSuffix = abs(bar.assignment.units - 100) > 0.001 ? " · \(Self.trimmedPercent(bar.assignment.units))%" : ""
        return Button { onJumpToWBS(task.id) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name).font(.system(size: 12)).lineLimit(1)
                    Text("WBS \(task.wbs)\(unitsSuffix)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.dateRangeText(task.start, task.finish)).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("\(Int(task.percent))% done").font(.system(size: 10)).foregroundStyle(task.percent >= 100 ? .green : .secondary)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // ---- shared styling -------------------------------------------------------------------------------

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
    }

    private static let avatarPalette: [Color] = [.blue, .purple, .teal, .indigo, .pink, .brown, .cyan, .mint, .orange]

    private static func avatarColor(for name: String) -> Color {
        guard !name.isEmpty else { return .accentColor }
        var hasher = Hasher()
        hasher.combine(name)
        return avatarPalette[abs(hasher.finalize()) % avatarPalette.count]
    }

    private static let sectionPalette: [Color] = [.blue, .purple, .teal, .indigo, .pink, .brown, .cyan, .mint]

    private static func sectionColor(for section: String) -> Color {
        guard !section.isEmpty else { return .accentColor }
        var hasher = Hasher()
        hasher.combine(section)
        return sectionPalette[abs(hasher.finalize()) % sectionPalette.count]
    }

    private static func currency(_ value: Double) -> String {
        "$" + String(format: value.rounded() == value ? "%.0f" : "%.2f", value)
    }

    private static func trimmedHours(_ value: Double) -> String {
        String(format: "%.1fh", value)
    }

    private static func trimmedPercent(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func dateRangeText(_ start: Date?, _ finish: Date?) -> String {
        guard let start else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let finish else { return formatter.string(from: start) }
        return "\(formatter.string(from: start)) – \(formatter.string(from: finish))"
    }
}
