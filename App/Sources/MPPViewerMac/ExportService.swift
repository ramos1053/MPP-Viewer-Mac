import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Export/print support: a CSV of the raw task list (works regardless of what's on screen); a PDF
/// of the *entire* project (every task, via the real Gantt chart drawer — see
/// `fullProjectSnapshotView` below); and PNG/print of a condensed Timeline snapshot. The PNG/Print
/// snapshot targets `TimelineOverviewView` specifically rather than whatever view happens to be
/// active — it's the one view in this app built to show the whole project at once with no scroll
/// state, no synced dual-NSScrollView machinery (unlike Gantt), and no week-paging (unlike
/// Calendar/Task Usage) to decide a "current page" for. PDF export doesn't have that constraint (a
/// PDF page isn't bound by print-page or raster-image size the way PNG/Print are), so it renders
/// the real, complete Gantt chart instead of the condensed overview.
enum ExportService {
    // ---- CSV ----------------------------------------------------------------------------------

    static func csv(tasks: [GanttTask], resourcesById: [Int: ResourceDto]) -> String {
        var lines = ["WBS,Name,Duration (days),Start,Finish,% Complete,Predecessors,Resources,Notes"]
        for task in tasks {
            let predecessors = task.links.map { link in
                tasks.first(where: { $0.id == link.predecessorId })?.wbs ?? "#\(link.predecessorId)"
            }.joined(separator: "; ")
            let fields = [
                task.wbs, task.name, Self.trimmed(task.durationDays),
                Self.dateString(task.start), Self.dateString(task.finish),
                Self.trimmed(task.percent), predecessors, task.resourceNames, task.notes,
            ]
            lines.append(fields.map(Self.csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n")
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func trimmed(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    private static func dateString(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    // ---- Snapshot rendering ---------------------------------------------------------------------

    /// Width is fixed (a reasonable print/export page width); height grows with the task count so
    /// every lane fits with nothing clipped or scrolled — this is a snapshot, not a live view, so
    /// there's no viewport to fit within.
    private static func snapshotView(tasks: [GanttTask], range: ClosedRange<Date>, showCriticalPath: Bool) -> some View {
        TimelineOverviewView(
            tasks: tasks, range: range, showCriticalPath: showCriticalPath,
            selectedTaskId: nil, onSelect: { _ in }, onJumpToWBS: { _ in },
            onDeleteRequest: { _ in }, onEditNotes: { _, _ in })
            .frame(width: 1400, height: max(500, CGFloat(tasks.filter { $0.outlineLevel == 1 }.count) * 44 + 160))
    }

    @MainActor
    private static func renderer(tasks: [GanttTask], range: ClosedRange<Date>, showCriticalPath: Bool) -> ImageRenderer<some View> {
        let renderer = ImageRenderer(content: snapshotView(tasks: tasks, range: range, showCriticalPath: showCriticalPath))
        renderer.scale = 2
        return renderer
    }

    @MainActor
    static func pngData(tasks: [GanttTask], range: ClosedRange<Date>, showCriticalPath: Bool) -> Data? {
        guard let nsImage = renderer(tasks: tasks, range: range, showCriticalPath: showCriticalPath).nsImage,
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// A single-page PDF sized exactly to the rendered content — simpler and more useful for a
    /// project timeline than forcing a fixed Letter/A4 page and clipping or shrinking to fit.
    /// Unlike the condensed Timeline snapshot above (used for PNG/Print, which have no natural way
    /// to paginate or usefully display a page this large), PDF export renders the *real* Gantt
    /// chart — every task at every outline level, bars/links/critical-path tint and all, via the
    /// same `TimelineCanvas` the live Gantt view itself draws with — at its full natural content
    /// size. A PDF page has no practical size ceiling the way print or a raster image does, so "the
    /// whole project on one page, zoom in a PDF viewer to read it" is a reasonable, simple design,
    /// consistent with this file's existing "size exactly to content, not a fixed page" philosophy.
    private static func fullProjectSnapshotView(tasks: [GanttTask], range: ClosedRange<Date>, showCriticalPath: Bool) -> some View {
        TimelineCanvas(
            tasks: tasks, tasksVersion: 0, range: range, pixelsPerDay: 12, // matches ContentView's own default Gantt zoom
            selectedTaskId: nil, onSelect: { _ in }, showCriticalPath: showCriticalPath)
    }

    @MainActor
    static func pdfData(tasks: [GanttTask], range: ClosedRange<Date>, showCriticalPath: Bool) -> Data? {
        let size = CGSize(
            width: ganttContentWidth(range: range, pixelsPerDay: 12),
            height: ganttContentHeight(taskCount: tasks.count))
        let r = ImageRenderer(content: fullProjectSnapshotView(tasks: tasks, range: range, showCriticalPath: showCriticalPath))
        r.scale = 2
        // `ImageRenderer.proposedSize` is read-write, and `render(renderer:)` uses whatever's
        // currently *set* there to decide the layout size it hands the content — it is never
        // inferred from the view's own `.frame()` modifier. Left unset (as this code originally
        // did, reading it instead of writing it), it stays `.unspecified`, and
        // `replacingUnspecifiedDimensions()` with no argument defaults to a bare 10×10 points —
        // real content rendered correctly, just squeezed into a page smaller than a single screen
        // pixel, which is what "blank" PDF pages actually were. Must be set explicitly, to the same
        // size `TimelineCanvas`/`fullProjectSnapshotView` itself resolves to via
        // `ganttContentWidth`/`ganttContentHeight`.
        r.proposedSize = ProposedViewSize(size)
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return nil }
        r.render { _, renderInContext in
            context.beginPDFPage(nil)
            renderInContext(context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    @MainActor
    static func print(tasks: [GanttTask], range: ClosedRange<Date>, showCriticalPath: Bool) {
        let hosting = NSHostingView(rootView: snapshotView(tasks: tasks, range: range, showCriticalPath: showCriticalPath))
        let size = CGSize(width: 1400, height: max(500, CGFloat(tasks.filter { $0.outlineLevel == 1 }.count) * 44 + 160))
        hosting.frame = CGRect(origin: .zero, size: size)
        let operation = NSPrintOperation(view: hosting)
        operation.printInfo.topMargin = 24
        operation.printInfo.bottomMargin = 24
        operation.printInfo.leftMargin = 24
        operation.printInfo.rightMargin = 24
        operation.run()
    }

    // ---- Save panels ----------------------------------------------------------------------------

    static func presentSavePanel(suggestedName: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
