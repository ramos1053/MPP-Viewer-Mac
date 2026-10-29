import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct MPPViewerMacApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("predecessorTypeFullNames") private var fullRelationshipNames = false
    @AppStorage("showCriticalPath") private var showCriticalPath = true
    @Environment(\.openWindow) private var openWindow

    init() {
        // There's exactly one AppModel for the whole app, not one per window — a "new tab" would
        // just be a second window pointing at the same shared project, not a new document, and
        // closing one wouldn't close anything. macOS opts every window-based app into tabbing by
        // default; this one has no use for it, hence turning it off process-wide here.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        // The project title still exists (ContentView's `.navigationTitle`, needed for the Window
        // menu/Mission Control/etc.) but no longer renders inside the toolbar itself — with the
        // toolbar's "Text Only"/labeled display mode, the title and the item labels were competing
        // for the same cramped space. It now shows in its own plain row below the toolbar instead
        // (see ContentView.projectTitleRow).
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { model.requestNewProject() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            // MPXJ.Net can write Project XML (MSPDI) reliably regardless of what format the file was
            // opened from — it can't write most of the formats it reads (GanttProject, Primavera,
            // SureTrak, ...), so Save/Save As always targets .xml rather than round-tripping the
            // original format.
            CommandGroup(replacing: .saveItem) {
                // See AppModel.needsSaveAsPath: a plain save still prompts the first time for a file
                // that wasn't opened from Project XML, since that's the only format the Helper can
                // write — this must not silently overwrite the original .mpp/.gan/etc. with XML.
                Button("Save") { model.needsSaveAsPath ? presentSaveAsPanel() : model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.tasks.isEmpty || model.isSaving)
                Button("Save As…") { presentSaveAsPanel() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.tasks.isEmpty || model.isSaving)
            }
            // CSV works off the raw task list regardless of what's on screen; PDF/PNG/Print all
            // render a TimelineOverviewView snapshot — see ExportService's doc comment for why that
            // one view, specifically, rather than whatever's currently active.
            CommandGroup(after: .saveItem) {
                Divider()
                Button("Export as CSV…") { exportCSV() }
                    .disabled(model.tasks.isEmpty)
                Button("Export Timeline as PDF…") { exportPDF() }
                    .disabled(model.tasks.isEmpty || model.dateRange == nil)
                Button("Export Timeline as PNG…") { exportPNG() }
                    .disabled(model.tasks.isEmpty || model.dateRange == nil)
            }
            CommandGroup(after: .printItem) {
                Button("Print Timeline…") { printTimeline() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(model.tasks.isEmpty || model.dateRange == nil)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo \(model.undoManager.undoActionName)") { model.undoManager.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.undoManager.canUndo)
                Button("Redo \(model.undoManager.redoActionName)") { model.undoManager.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.undoManager.canRedo)
            }
            // "Find" itself isn't listed here — `.searchable()` already wires ⌘F to focus the toolbar
            // search field for free (see ContentView.mainContent). These are everything that was
            // actually missing: stepping through matches without touching the mouse, and replacing
            // text in bulk. Disabled together with no file open, same as the other task-dependent
            // commands in this file.
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Find Next") { model.pendingFindAction = .next }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(model.tasks.isEmpty)
                Button("Find Previous") { model.pendingFindAction = .previous }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(model.tasks.isEmpty)
                Divider()
                Button("Find and Replace…") { model.pendingFindAction = .replace }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(model.tasks.isEmpty)
            }
            // Mirrors a row's right-click context menu, but acts on the current selection — so Add
            // Before/After/Delete are reachable entirely from the keyboard, not just by right-click.
            CommandMenu("Task") {
                Button("Add Task Before") { model.pendingTaskAction = .addBefore(taskId: model.selectedTaskId!) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                    .disabled(model.selectedTaskId == nil)
                Button("Add Task After") { model.pendingTaskAction = .addAfter(taskId: model.selectedTaskId!) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
                    .disabled(model.selectedTaskId == nil)
                Divider()
                Button("Delete Task") { model.pendingTaskAction = .delete(taskId: model.selectedTaskId!) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selectedTaskId == nil)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Full Relationship Names", isOn: $fullRelationshipNames)
                Toggle("Highlight Critical Path", isOn: $showCriticalPath)
                // No "Customize Toolbar…" command, and the toolbar itself (ContentView.mainToolbarItems)
                // is deliberately built without `.toolbar(id:)` — see that property's doc comment for
                // why: any toolbar AppKit considers customizable reliably crashes this app when that
                // panel opens, on this macOS build, regardless of how it's reached (native right-click
                // menu or a programmatic call). There's no "disabled but present" middle ground that's
                // actually safe, so the capability is gone, not hidden.
            }
            // Replaces the default placeholder Help menu item with one that actually opens something —
            // see HelpView's doc comment for why this is a plain window rather than a real, indexed
            // Apple Help Book (the `hiutil`-indexed `.help` bundle approach needs build-time tooling
            // this project's hand-built .app doesn't have, and packaging is explicitly deferred).
            CommandGroup(replacing: .help) {
                Button("MPP Viewer Help") { openWindow(id: "help") }
                    .keyboardShortcut("?", modifiers: .command)
            }
        }
        // `Window`, not `WindowGroup` — a single-instance scene, so reopening Help while it's already
        // open brings the existing window forward instead of spawning a second one (WindowGroup would
        // allow multiple).
        Window("MPP Viewer Help", id: "help") {
            HelpView()
        }
        Settings {
            SettingsView()
        }
    }

    private func presentSaveAsPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xml")].compactMap { $0 }
        panel.nameFieldStringValue = (model.title.isEmpty ? "Untitled" : model.title) + ".xml"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            model.saveAs(to: url.path)
        }
    }

    private var exportBaseName: String { model.title.isEmpty ? "Untitled" : model.title }

    private func exportCSV() {
        guard let url = ExportService.presentSavePanel(suggestedName: exportBaseName + ".csv", type: .commaSeparatedText) else { return }
        let text = ExportService.csv(tasks: model.tasks, resourcesById: model.resourcesById)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func exportPDF() {
        guard let range = model.dateRange,
              let url = ExportService.presentSavePanel(suggestedName: exportBaseName + ".pdf", type: .pdf)
        else { return }
        guard let data = ExportService.pdfData(tasks: model.tasks, range: range, showCriticalPath: showCriticalPath) else { return }
        try? data.write(to: url)
    }

    private func exportPNG() {
        guard let range = model.dateRange,
              let url = ExportService.presentSavePanel(suggestedName: exportBaseName + ".png", type: .png)
        else { return }
        guard let data = ExportService.pngData(tasks: model.tasks, range: range, showCriticalPath: showCriticalPath) else { return }
        try? data.write(to: url)
    }

    private func printTimeline() {
        guard let range = model.dateRange else { return }
        ExportService.print(tasks: model.tasks, range: range, showCriticalPath: showCriticalPath)
    }
}
