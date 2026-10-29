import SwiftUI
import AppKit

/// Popover calendar for setting a task's Start/Finish range by clicking days instead of typing a
/// duration number. A plain click resets the selection to that single day; Option-click extends
/// the existing range to include the clicked day, in whichever direction it falls — a task's
/// duration can't have gaps, so the result is always the contiguous span from the earliest to the
/// latest day clicked so far. Opens positioned at the month containing the task's current Start.
struct DateRangePicker: View {
    let onApply: (Date, Date) -> Void
    let onCancel: () -> Void

    @State private var rangeStart: Date
    @State private var rangeFinish: Date
    @State private var visibleMonth: Date

    init(start: Date, finish: Date, onApply: @escaping (Date, Date) -> Void, onCancel: @escaping () -> Void) {
        self.onApply = onApply
        self.onCancel = onCancel
        _rangeStart = State(initialValue: start)
        _rangeFinish = State(initialValue: max(start, finish))
        _visibleMonth = State(initialValue: start)
    }

    /// Matches the app's existing Duration convention (Finish − Start in days, not an inclusive
    /// day count) — see Scheduler/AppModel, which already compute Finish as Start + duration days.
    private var durationDays: Int {
        Calendar.ganttUTC.dateComponents([.day], from: rangeStart, to: rangeFinish).day ?? 0
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: { shiftMonth(-1) }) { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                Spacer()
                Text(Self.monthFormatter.string(from: visibleMonth)).font(.headline)
                Spacer()
                Button(action: { shiftMonth(1) }) { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
            }

            MonthGrid(month: visibleMonth, rangeStart: rangeStart, rangeFinish: rangeFinish) { day in
                if NSEvent.modifierFlags.contains(.option) {
                    rangeStart = min(rangeStart, day)
                    rangeFinish = max(rangeFinish, day)
                } else {
                    rangeStart = day
                    rangeFinish = day
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("\(Self.dateFormatter.string(from: rangeStart))  →  \(Self.dateFormatter.string(from: rangeFinish))")
                    .font(.caption)
                Text("\(durationDays) day\(durationDays == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Apply") { onApply(rangeStart, rangeFinish) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func shiftMonth(_ delta: Int) {
        visibleMonth = Calendar.ganttUTC.date(byAdding: .month, value: delta, to: visibleMonth) ?? visibleMonth
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

/// A single month's day grid. Click handling (plain vs. Option) lives in the parent — this just
/// reports which day was tapped and draws the current range's highlight.
private struct MonthGrid: View {
    let month: Date
    let rangeStart: Date
    let rangeFinish: Date
    let onTapDay: (Date) -> Void

    private static let weekdaySymbols = ["S", "M", "T", "W", "T", "F", "S"]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    private var days: [Date?] {
        let calendar = Calendar.ganttUTC
        guard let monthInterval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let firstOfMonth = monthInterval.start
        let leadingBlanks = calendar.component(.weekday, from: firstOfMonth) - 1 // 1 = Sunday
        let daysInMonth = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        var result: [Date?] = Array(repeating: nil, count: leadingBlanks)
        result.append(contentsOf: (0..<daysInMonth).map { calendar.date(byAdding: .day, value: $0, to: firstOfMonth) })
        return result
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(Array(Self.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(width: 24, height: 24)
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let calendar = Calendar.ganttUTC
        let inRange = day >= rangeStart && day <= rangeFinish
        let isEdge = calendar.isDate(day, inSameDayAs: rangeStart) || calendar.isDate(day, inSameDayAs: rangeFinish)
        return Text("\(calendar.component(.day, from: day))")
            .font(.caption)
            .frame(width: 24, height: 24)
            .background(
                Circle().fill(isEdge ? Color.accentColor : (inRange ? Color.accentColor.opacity(0.3) : Color.clear)))
            .foregroundStyle(isEdge ? Color.white : Color.primary)
            .contentShape(Circle())
            .onTapGesture { onTapDay(day) }
    }
}
