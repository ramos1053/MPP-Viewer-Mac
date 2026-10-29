import SwiftUI

/// The app's Preferences window (⌘,), reachable like any standard macOS app. Consolidates every
/// cross-cutting, document-independent preference in the app into one place — things that used to be
/// (or still also are) reachable only via a one-off control elsewhere, like the View menu's checkboxes
/// or the Calendar view's own mode toggle. Each setting here is backed by the same AppStorage key its
/// other entry point(s) use, so they all stay in sync automatically; this is never a second source of
/// truth. Deliberately does NOT include toolbar display style (Icon Only/Icon and Text) — that's
/// AppKit's own autosaved `NSToolbar` state, and after this session's toolbar customization crash saga
/// (see ContentView.mainToolbarItems), it's not worth adding another code path that pokes at live
/// `NSToolbar` state for what right-click already covers.
struct SettingsView: View {
    @AppStorage("defaultViewMode") private var defaultViewModeRaw = ViewMode.gantt.rawValue
    /// Same raw-string convention and the same key as CalendarView's own (private) `Mode` enum — kept
    /// as a plain String here rather than importing that type, since CalendarView.Mode has no reason
    /// to be anything but private to the one view that actually switches on it.
    @AppStorage("calendarMode") private var defaultCalendarModeRaw = "Month"
    @AppStorage("predecessorTypeFullNames") private var fullRelationshipNames = false
    @AppStorage("showCriticalPath") private var showCriticalPath = true
    @AppStorage("calendarSelectionColor") private var calendarSelectionColorName = HighlightColor.red.rawValue

    var body: some View {
        Form {
            Section("General") {
                Picker("Default view when opening a project", selection: $defaultViewModeRaw) {
                    ForEach(ViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode.rawValue)
                    }
                }
                .help("Which view (Gantt, Timeline, Network, Calendar, Resources) a project opens into")
                Picker("Default calendar display", selection: $defaultCalendarModeRaw) {
                    Text("Month").tag("Month")
                    Text("Team").tag("Team")
                    Text("Task Usage").tag("Task Usage")
                }
                .help("Month shows a traditional grid; Team shows a per-resource weekly timeline; Task Usage shows each task's timephased work. Switching inside the Calendar view updates this too.")
            }

            Section("Display") {
                Toggle("Show relationship types as full words", isOn: $fullRelationshipNames)
                    .help("FS/SS/FF/SF become Finish-to-Start, Start-to-Start, etc. in the Predecessors editor")
                Toggle("Highlight critical path", isOn: $showCriticalPath)
                    .help("Colors critical tasks, bars, and links red across the Gantt, Timeline, and Network views")
                // Deliberately not a Picker with colored Label rows: a Picker's closed/open rows are
                // backed by real NSMenuItems, and AppKit forces any SF Symbol inside a menu item into
                // template (monochrome) rendering, discarding whatever .foregroundStyle color SwiftUI
                // gave it — exactly why these dots were rendering solid black regardless of selection.
                // Plain buttons in the Form's own content area aren't menu items, so the color renders
                // for real.
                LabeledContent("Selection highlight color") {
                    HStack(spacing: 10) {
                        ForEach(HighlightColor.allCases) { option in
                            colorSwatch(option)
                        }
                    }
                }
                .help("The outline/highlight color around the task you click on, in Calendar (all three modes) and Network")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
    }

    private func colorSwatch(_ option: HighlightColor) -> some View {
        let isSelected = calendarSelectionColorName == option.rawValue
        return Button {
            calendarSelectionColorName = option.rawValue
        } label: {
            Circle()
                .fill(option.color.gradient)
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .shadow(color: option.color.opacity(isSelected ? 0.5 : 0), radius: 3, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .help(option.label)
    }
}
