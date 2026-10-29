import SwiftUI

/// A scrollable notes editor, shared by the WBS table's Notes cell and the Calendar view's right-
/// click "Notes…" — one popover definition so editing a task's notes looks and behaves the same
/// regardless of which view you opened it from. Same Apply/Cancel-with-local-state convention as
/// DateRangePicker/PredecessorEditor: typing doesn't push anything through AppModel until Apply.
struct NotesEditor: View {
    let initialNotes: String
    let onApply: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String

    init(initialNotes: String, onApply: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.initialNotes = initialNotes
        self.onApply = onApply
        self.onCancel = onCancel
        _draft = State(initialValue: initialNotes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes").font(.headline)
            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                .frame(minWidth: 320, idealWidth: 360, minHeight: 160, idealHeight: 220, maxHeight: 320)
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Apply") { onApply(draft) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }
}
