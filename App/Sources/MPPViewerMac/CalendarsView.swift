import SwiftUI

/// The toolbar Calendars button's sheet: working-time calendar definitions (weekly working pattern
/// + holiday/makeup-day exceptions) — a sidebar list of calendars on the left, the selected one's
/// detail on the right, same master-detail shape as a lightweight Settings pane. Reaches into
/// `model` directly (several small mutations, not one) rather than a closure per field, same
/// convention ResourceSheetView already uses for the same reason.
///
/// Honest about scope: editable and saved for real, but Scheduler.swift's calendar-day arithmetic
/// doesn't consume this data yet (see `scopeNote`) — building the editor ahead of the scheduling
/// engine catching up is the same order this app already shipped Budget and custom Resource Types
/// in.
struct CalendarsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedCalendarId: Int?
    @State private var draftExceptionName = ""
    @State private var draftExceptionFrom = Calendar.ganttUTC.startOfDay(for: Date())
    @State private var draftExceptionTo = Calendar.ganttUTC.startOfDay(for: Date())
    @State private var draftExceptionWorking = false

    private var sortedCalendars: [CalendarDto] {
        model.calendars.sorted { $0.isDefault && !$1.isDefault || ($0.isDefault == $1.isDefault && $0.name < $1.name) }
    }

    private var selected: CalendarDto? {
        guard let selectedCalendarId else { return sortedCalendars.first }
        return model.calendars.first { $0.uniqueId == selectedCalendarId } ?? sortedCalendars.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                if let selected {
                    detail(for: selected)
                } else {
                    ContentUnavailableView(
                        "No Calendars", systemImage: "calendar.badge.clock",
                        description: Text("Add a calendar to define a working week and holidays."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 620, height: 520)
        .onAppear { selectedCalendarId = sortedCalendars.first?.uniqueId }
    }

    // ---- header / sidebar --------------------------------------------------------------------------

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 18))
                .foregroundStyle(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 1) {
                Text("Calendars").font(.system(size: 16, weight: .bold, design: .rounded))
                Text("Working days and holiday exceptions").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(sortedCalendars, selection: Binding(
                get: { selectedCalendarId ?? sortedCalendars.first?.uniqueId },
                set: { selectedCalendarId = $0 })
            ) { cal in
                HStack(spacing: 6) {
                    Text(cal.name.isEmpty ? "Untitled" : cal.name).lineLimit(1)
                    if cal.isDefault {
                        // A translucent accent-tinted capsule reads fine on the row's normal white
                        // background, but all but disappears once the row is selected (solid accent-
                        // blue beneath a same-hue translucent fill and same-hue text) — opaque white
                        // behind accent-colored text stays legible either way, confirmed by
                        // screenshotting both states.
                        Text("Default")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.95)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .tag(cal.uniqueId)
            }
            .listStyle(.sidebar)
            Divider()
            Button {
                model.addCalendar()
                selectedCalendarId = model.calendars.map(\.uniqueId).max()
            } label: {
                Label("Add Calendar", systemImage: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 200)
    }

    // ---- detail ---------------------------------------------------------------------------------

    @ViewBuilder
    private func detail(for cal: CalendarDto) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                nameRow(cal)
                weeklyPattern(cal)
                exceptionsSection(cal)
                scopeNote
            }
            .padding(18)
        }
    }

    private func nameRow(_ cal: CalendarDto) -> some View {
        HStack {
            TextField("Calendar Name", text: Binding(
                get: { cal.name },
                set: { model.renameCalendar(calendarId: cal.uniqueId, to: $0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if !cal.isDefault {
                Button(role: .destructive) {
                    let remaining = sortedCalendars.filter { $0.uniqueId != cal.uniqueId }
                    model.deleteCalendar(cal.uniqueId)
                    selectedCalendarId = remaining.first?.uniqueId
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .font(.system(size: 11))
            }
        }
    }

    private func weeklyPattern(_ cal: CalendarDto) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Working Week").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(0..<7, id: \.self) { i in
                    dayToggle(cal, dayIndex: i)
                }
            }
        }
    }

    private func dayToggle(_ cal: CalendarDto, dayIndex: Int) -> some View {
        let isWorking = cal.workingDays.indices.contains(dayIndex) ? cal.workingDays[dayIndex] : false
        return Button {
            model.setCalendarWorkingDay(calendarId: cal.uniqueId, dayIndex: dayIndex, working: !isWorking)
        } label: {
            VStack(spacing: 4) {
                Text(CalendarDto.weekdaySymbols[dayIndex])
                    .font(.system(size: 10, weight: .bold))
                Image(systemName: isWorking ? "checkmark" : "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .frame(width: 42, height: 42)
            .foregroundStyle(isWorking ? .white : .secondary)
            .background(
                isWorking
                    ? AnyView(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                        .shadow(color: .accentColor.opacity(0.35), radius: 3, x: 0, y: 1))
                    : AnyView(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06))))
        }
        .buttonStyle(.plain)
    }

    private func exceptionsSection(_ cal: CalendarDto) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exceptions").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)

            if cal.exceptions.isEmpty {
                Text("No holidays or makeup days yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(cal.exceptions.enumerated()), id: \.element.id) { index, ex in
                        exceptionRow(cal, exception: ex, index: index)
                        if index < cal.exceptions.count - 1 {
                            Divider()
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.03)))
            }

            addExceptionForm(cal)
        }
    }

    private func exceptionRow(_ cal: CalendarDto, exception: CalendarExceptionDto, index: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: exception.working ? "calendar.badge.checkmark" : "calendar.badge.minus")
                .foregroundStyle(exception.working ? .green : .orange)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 1) {
                Text(exception.name.isEmpty ? "Untitled" : exception.name).font(.system(size: 12, weight: .medium))
                Text(Self.exceptionDateLabel(exception)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                var updated = cal.exceptions
                updated.remove(at: index)
                model.setCalendarExceptions(calendarId: cal.uniqueId, to: updated)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func addExceptionForm(_ cal: CalendarDto) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Holiday name", text: $draftExceptionName).textFieldStyle(.roundedBorder)
                DatePicker("From", selection: $draftExceptionFrom, displayedComponents: .date)
                    .labelsHidden()
                DatePicker("To", selection: $draftExceptionTo, displayedComponents: .date)
                    .labelsHidden()
            }
            HStack {
                Toggle("Working (makeup day)", isOn: $draftExceptionWorking)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Spacer()
                Button("Add") {
                    var updated = cal.exceptions
                    updated.append(CalendarExceptionDto(
                        name: draftExceptionName.isEmpty ? "Holiday" : draftExceptionName,
                        fromDate: Self.isoDate(draftExceptionFrom),
                        toDate: Self.isoDate(max(draftExceptionFrom, draftExceptionTo)),
                        working: draftExceptionWorking))
                    model.setCalendarExceptions(calendarId: cal.uniqueId, to: updated)
                    draftExceptionName = ""
                    draftExceptionWorking = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.03)))
    }

    private var scopeNote: some View {
        Label(
            "Task dates use calendar-day arithmetic and don't yet account for these working-time rules — a known simplification, not a bug.",
            systemImage: "info.circle")
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    // ---- formatting -------------------------------------------------------------------------------

    private static func exceptionDateLabel(_ ex: CalendarExceptionDto) -> String {
        ex.fromDate == ex.toDate ? ex.fromDate : "\(ex.fromDate) – \(ex.toDate)"
    }

    private static func isoDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
