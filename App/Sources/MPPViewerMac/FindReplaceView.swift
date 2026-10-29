import SwiftUI

/// Edit menu's "Find and Replace…" sheet (ContentView, reached via AppModel.pendingFindAction). Scope
/// is Task Name and Notes only — the same two fields the toolbar's own Search already searches,  minus
/// WBS code (not something you'd ever want to overwrite). Matches are per-field, not per-occurrence: a
/// task whose Name *and* Notes both contain the find text counts as two matches, stepped through
/// independently, but "Replace" rewrites every occurrence within that one field at once rather than
/// one character range at a time — there's no live text-selection view backing this to track finer
/// ranges against, and replace-all-in-field is still far more useful than nothing.
struct FindReplaceView: View {
    @ObservedObject var model: AppModel
    let initialFindText: String
    /// Selects the task and switches to the Gantt view, matching ContentView.jumpToNextMatch's own
    /// behavior — so stepping through matches here visibly shows which task is about to be changed.
    let onNavigate: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var findText: String
    @State private var replaceText = ""
    @State private var currentIndex = 0
    @State private var lastReplacedCount: Int?
    @FocusState private var findFieldFocused: Bool

    private enum MatchField: String { case name = "Name", notes = "Notes" }
    private struct Match { let taskId: Int; let field: MatchField }

    init(model: AppModel, initialFindText: String, onNavigate: @escaping (Int) -> Void) {
        self.model = model
        self.initialFindText = initialFindText
        self.onNavigate = onNavigate
        _findText = State(initialValue: initialFindText)
    }

    private var matches: [Match] {
        guard !findText.isEmpty else { return [] }
        var result: [Match] = []
        for task in model.tasks {
            if task.name.range(of: findText, options: .caseInsensitive) != nil {
                result.append(Match(taskId: task.id, field: .name))
            }
            if task.notes.range(of: findText, options: .caseInsensitive) != nil {
                result.append(Match(taskId: task.id, field: .notes))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find and Replace").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Find").foregroundStyle(.secondary)
                    TextField("", text: $findText)
                        .focused($findFieldFocused)
                        .onChange(of: findText) { currentIndex = 0; lastReplacedCount = nil }
                }
                GridRow {
                    Text("Replace").foregroundStyle(.secondary)
                    TextField("", text: $replaceText)
                }
            }
            .frame(width: 340)

            Text("Searches Task Name and Notes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            statusLine

            HStack(spacing: 8) {
                Button("Previous", action: previous)
                    .disabled(matches.isEmpty)
                Button("Next", action: next)
                    .disabled(matches.isEmpty)
                Spacer()
                Button("Replace", action: replaceCurrent)
                    .disabled(matches.isEmpty)
                Button("Replace All", action: replaceAll)
                    .disabled(matches.isEmpty)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { findFieldFocused = true; navigateToCurrent() }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let count = lastReplacedCount {
            Text(count == 1 ? "Replaced 1 occurrence." : "Replaced \(count) occurrences.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if findText.isEmpty {
            Text(" ").font(.caption)
        } else if matches.isEmpty {
            Text("No matches.").font(.caption).foregroundStyle(.secondary)
        } else {
            let clamped = min(currentIndex, matches.count - 1)
            let match = matches[clamped]
            Text("Match \(clamped + 1) of \(matches.count) — \(match.field.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func next() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + 1) % matches.count
        navigateToCurrent()
    }

    private func previous() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex - 1 + matches.count) % matches.count
        navigateToCurrent()
    }

    private func navigateToCurrent() {
        guard !matches.isEmpty else { return }
        let clamped = min(currentIndex, matches.count - 1)
        onNavigate(matches[clamped].taskId)
    }

    private func replaceCurrent() {
        guard !matches.isEmpty else { return }
        lastReplacedCount = nil
        let clamped = min(currentIndex, matches.count - 1)
        let match = matches[clamped]
        applyReplacement(for: match)
        // currentIndex stays put — the list shifted under it, so it now points at what was the next
        // match (or wraps via the clamp above on the next render if this was the last one).
        navigateToCurrent()
    }

    private func replaceAll() {
        let all = matches
        guard !all.isEmpty else { return }
        for match in all {
            applyReplacement(for: match)
        }
        lastReplacedCount = all.count
        currentIndex = 0
    }

    private func applyReplacement(for match: Match) {
        guard let task = model.tasks.first(where: { $0.id == match.taskId }) else { return }
        switch match.field {
        case .name:
            model.setName(taskId: match.taskId, to: Self.replacingAll(in: task.name, find: findText, with: replaceText))
        case .notes:
            model.setNotes(taskId: match.taskId, to: Self.replacingAll(in: task.notes, find: findText, with: replaceText))
        }
    }

    /// Case-insensitive replace-all. Resumes each search right after the just-inserted replacement
    /// text rather than from its start, so a find/replace pair like "a"/"aa" can't loop forever
    /// rescanning its own output.
    private static func replacingAll(in text: String, find: String, with replacement: String) -> String {
        guard !find.isEmpty else { return text }
        var result = text
        var searchRange = result.startIndex..<result.endIndex
        while let range = result.range(of: find, options: .caseInsensitive, range: searchRange) {
            result.replaceSubrange(range, with: replacement)
            let resumeIndex = result.index(range.lowerBound, offsetBy: replacement.count, limitedBy: result.endIndex) ?? result.endIndex
            searchRange = resumeIndex..<result.endIndex
        }
        return result
    }
}
