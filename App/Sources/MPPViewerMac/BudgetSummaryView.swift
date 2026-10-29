import SwiftUI

/// The toolbar Budget button's popover: set/edit the one project-wide budget, see planned vs.
/// progress-weighted cost against it, and a per-resource cost breakdown. See BudgetCalculator for the
/// actual math and ContentView's budgetStatus* computed properties for the toolbar icon/color this
/// popover is reached from.
struct BudgetSummaryView: View {
    let budgetCost: Double
    let summary: BudgetCalculator.Summary
    let resourcesById: [Int: ResourceDto]
    let onApply: (Double) -> Void

    @State private var draftBudget = ""

    private var status: BudgetCalculator.Status {
        BudgetCalculator.status(earnedCost: summary.earnedCost, budget: budgetCost)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project Budget").font(.headline)

            HStack(spacing: 6) {
                Text("$")
                TextField("Amount", text: $draftBudget)
                    .frame(width: 110)
                    .onSubmit(apply)
                Button("Set", action: apply)
                    .disabled(Double(draftBudget.trimmingCharacters(in: .whitespaces)) == nil)
            }

            if budgetCost > 0 {
                Divider()
                progressSection
                if !summary.perResource.isEmpty {
                    Divider()
                    breakdownSection
                }
            } else {
                Text("Set a budget to track planned and earned cost against it, with a warning when nearing or over.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(minWidth: 300)
        .onAppear { draftBudget = budgetCost > 0 ? Self.trimmed(budgetCost) : "" }
    }

    private var progressSection: some View {
        let fraction = budgetCost > 0 ? summary.earnedCost / budgetCost : 0
        let barColor: Color = switch status {
        case .noBudget: .secondary
        case .onTrack: .green
        case .nearing: .orange
        case .overBudget: .red
        }
        let statusLine: String = switch status {
        case .noBudget: ""
        case .onTrack: "On track"
        case .nearing: "Nearing budget"
        case .overBudget: "Over budget"
        }

        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(barColor.gradient)
                        .frame(width: geo.size.width * min(1, max(0, fraction)))
                }
            }
            .frame(height: 8)

            if !statusLine.isEmpty {
                Label(statusLine, systemImage: status == .overBudget ? "exclamationmark.triangle.fill" : "circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(barColor)
            }

            statRow("Spent to date", Self.currency(summary.earnedCost), detail: "\(Self.percent(fraction)) of budget")
            statRow("Remaining", Self.currency(max(0, budgetCost - summary.earnedCost)))
            statRow("Planned total", Self.currency(summary.plannedCost), detail: "if completed as scheduled")
        }
    }

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By Resource").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(summary.perResource.sorted { $0.plannedCost > $1.plannedCost }.prefix(6)) { cost in
                HStack {
                    Text(resourcesById[cost.resourceId]?.name ?? "#\(cost.resourceId)")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text(Self.currency(cost.earnedCost))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statRow(_ label: String, _ value: String, detail: String? = nil) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(value).font(.caption.monospacedDigit().weight(.medium))
                if let detail {
                    Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func apply() {
        guard let parsed = Double(draftBudget.trimmingCharacters(in: .whitespaces)) else { return }
        onApply(parsed)
    }

    private static func trimmed(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    private static func currency(_ value: Double) -> String {
        "$" + String(format: value.rounded() == value ? "%.0f" : "%.2f", value)
    }

    private static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }
}
