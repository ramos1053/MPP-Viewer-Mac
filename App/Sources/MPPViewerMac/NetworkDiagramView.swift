import SwiftUI

/// The Network Diagram (PERT chart): every task as a box, positioned by NetworkLayout into columns
/// (dependency depth) and rows, connected by curved links showing predecessor → successor relations —
/// ported to match the Windows app's look (MPP-Viewer/src/MppViewer/Controls/NetworkChart.cs): a box
/// per task with duration/percent/date lines and a progress bar, curved (not blocky) connectors, and
/// the selected task's direct neighbours tinted so a chain is easy to trace by eye. Unlike
/// TimelineCanvas's split (content Equatable-excluding-selection, selection drawn as a cheap separate
/// overlay), selection here is baked into the one Canvas pass, same as the Windows app's single
/// OnRender: a project's task count is bounded (tens to a couple hundred), so redrawing the whole
/// diagram on every selection change is cheap, and neighbour-highlighting needs every box to be
/// selection-aware anyway, not just one.
///
/// No ToolbarContentDivider of its own — see ResourceSheetView's doc comment for why.
struct NetworkDiagramView: View {
    let tasks: [GanttTask]
    let tasksVersion: Int
    let scale: CGFloat
    let selectedTaskId: Int?
    let onSelect: (Int) -> Void
    let onZoom: (CGFloat) -> Void
    let showCriticalPath: Bool
    /// Double-click, or right-click → "Jump to WBS" / "Notes…" / "Delete Task" — same three actions
    /// Calendar's context menu offers, routed through NetworkScrollHost's AppKit overlay since this
    /// view's clicks aren't plain SwiftUI gestures. See NetworkScrollHost's doc comments.
    let onJumpToWBS: (Int) -> Void
    let onDeleteRequest: (Int) -> Void
    let onEditNotes: (Int, String) -> Void
    let notesText: (Int) -> String
    /// Bump to request "scroll the current selection into view now" — see NetworkScrollHost's doc
    /// comment for why this is a separate trigger rather than just reacting to scrollTarget changing.
    let scrollTrigger: Int
    /// The same user-configurable selection color Calendar's every mode already honors (see
    /// Settings) — previously hardcoded to the system accent color here, the one place in the app
    /// that didn't read the preference despite it existing.
    let highlightColor: Color

    private var nodes: [NetworkNode] { NetworkLayout.nodes(for: tasks) }
    private var contentSize: CGSize { NetworkLayout.contentSize(for: nodes) }

    /// The selected node's center, in the same scaled coordinates the Canvas draws in — nil when
    /// nothing's selected, or the selected task isn't in this diagram at all (shouldn't normally
    /// happen, every task gets a node). Drives NetworkScrollHost's "bring selection into view."
    private var scrollTarget: CGPoint? {
        guard let selectedTaskId, let node = nodes.first(where: { $0.id == selectedTaskId }) else { return nil }
        let origin = NetworkLayout.position(node)
        return CGPoint(
            x: (origin.x + NetworkLayout.nodeWidth / 2) * scale,
            y: (origin.y + NetworkLayout.nodeHeight / 2) * scale)
    }

    var body: some View {
        if nodes.isEmpty {
            ContentUnavailableView(
                "No Tasks",
                systemImage: "point.3.filled.connected.trianglepath.dotted",
                description: Text("Network Diagram shows every task as a box, connected by its predecessor links.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NetworkScrollHost(
                content: NetworkCanvasContent(
                    nodes: nodes, tasksVersion: tasksVersion, scale: scale, selectedTaskId: selectedTaskId,
                    showCriticalPath: showCriticalPath, highlightColor: highlightColor),
                contentSize: CGSize(width: contentSize.width * scale, height: contentSize.height * scale),
                hitTest: { point in NetworkLayout.node(at: point, in: nodes, scale: scale)?.id },
                onSelect: onSelect,
                onZoom: onZoom,
                onJumpToWBS: onJumpToWBS,
                onDeleteRequest: onDeleteRequest,
                onEditNotes: onEditNotes,
                notesText: notesText,
                scrollTarget: scrollTarget,
                scrollTrigger: scrollTrigger)
        }
    }
}

/// One predecessor → successor connection, resolved from a task's links against the node array —
/// hoisted to file scope (rather than a type nested in a single method) since both edge-drawing
/// methods below need to share it.
private struct NetworkEdge {
    let from: NetworkNode
    let to: NetworkNode
    let type: String
    let lagDays: Double
}

/// The whole diagram in one Canvas pass: links first (so boxes draw on top of their own connector
/// ends), then every box. See the doc comment on NetworkDiagramView for why selection is included in
/// Equatable here, unlike TimelineCanvas's content/selection split.
private struct NetworkCanvasContent: View, Equatable {
    let nodes: [NetworkNode]
    let tasksVersion: Int
    let scale: CGFloat
    let selectedTaskId: Int?
    let showCriticalPath: Bool
    let highlightColor: Color

    nonisolated static func == (lhs: NetworkCanvasContent, rhs: NetworkCanvasContent) -> Bool {
        lhs.tasksVersion == rhs.tasksVersion && lhs.scale == rhs.scale && lhs.selectedTaskId == rhs.selectedTaskId
            && lhs.showCriticalPath == rhs.showCriticalPath && lhs.highlightColor == rhs.highlightColor
    }

    private var nodesById: [Int: NetworkNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }

    /// Predecessors and successors of the selected task, among the visible nodes — drawn with a
    /// highlighted fill, same as the Windows app, so the chain immediately around a selection is easy
    /// to trace without following every line by eye.
    private func neighbourIds(byId: [Int: NetworkNode]) -> Set<Int> {
        guard let selectedTaskId, let selected = byId[selectedTaskId] else { return [] }
        var result = Set(selected.task.links.map(\.predecessorId))
        for node in nodes where node.task.links.contains(where: { $0.predecessorId == selectedTaskId }) {
            result.insert(node.id)
        }
        return result
    }

    private func edges(byId: [Int: NetworkNode]) -> [NetworkEdge] {
        var edges: [NetworkEdge] = []
        for node in nodes {
            for link in node.task.links {
                guard let predecessor = byId[link.predecessorId] else { continue }
                edges.append(NetworkEdge(from: predecessor, to: node, type: link.type, lagDays: link.lagDays))
            }
        }
        return edges
    }

    var body: some View {
        let byId = nodesById
        let neighbours = neighbourIds(byId: byId)
        Canvas { context, _ in
            drawLinks(context: context, edges: edges(byId: byId))
            for node in nodes {
                drawBox(context: context, node: node, isSelected: node.id == selectedTaskId, isNeighbour: neighbours.contains(node.id))
            }
        }
    }

    // ---- boxes ------------------------------------------------------------------------------------

    private func drawBox(context: GraphicsContext, node: NetworkNode, isSelected: Bool, isNeighbour: Bool) {
        let origin = NetworkLayout.position(node)
        let rect = CGRect(
            x: origin.x * scale, y: origin.y * scale,
            width: NetworkLayout.nodeWidth * scale, height: NetworkLayout.nodeHeight * scale)
        let task = node.task
        let isCritical = showCriticalPath && task.isCritical
        let isDone = task.percent >= 99.99

        // Neighbour fill wins over critical/done — matches the Windows app: a critical task that's
        // also a neighbour of the current selection reads as "part of this chain" first.
        let tint: Color = isNeighbour ? .yellow : isCritical ? .red : isDone ? .green : .accentColor
        let borderColor: Color = isSelected ? highlightColor : isCritical ? .red : isDone ? .green : tint
        let shape = task.isMilestone ? Self.milestonePath(in: rect) : Path(roundedRect: rect, cornerRadius: 6 * scale)

        context.fill(shape, with: .color(tint.opacity(isNeighbour ? 0.22 : task.isMilestone ? 0.3 : 0.12)))
        context.stroke(
            shape, with: .color(borderColor.opacity(isSelected ? 1 : 0.75)),
            lineWidth: (isSelected ? 2.5 : isCritical ? 1.8 : 1.1) * scale)

        let padding: CGFloat = 7 * scale
        context.draw(
            Text(task.wbs).font(.system(size: 9 * scale)).foregroundStyle(.secondary),
            at: CGPoint(x: rect.minX + padding, y: rect.minY + padding), anchor: .topLeading)
        context.draw(
            Text(task.name).font(.system(size: 11.5 * scale)).bold(),
            in: CGRect(x: rect.minX + padding, y: rect.minY + padding + 11 * scale,
                       width: rect.width - padding * 2, height: 16 * scale))
        context.draw(
            Text("\(task.durationText)   \(Int(task.percent.rounded()))%")
                .font(.system(size: 9.5 * scale)).foregroundStyle(.secondary),
            at: CGPoint(x: rect.minX + padding, y: rect.minY + padding + 29 * scale), anchor: .topLeading)
        context.draw(
            Text("\(Self.dateText(task.start)) → \(Self.dateText(task.finish))")
                .font(.system(size: 9.5 * scale)).foregroundStyle(.secondary),
            at: CGPoint(x: rect.minX + padding, y: rect.minY + padding + 43 * scale), anchor: .topLeading)

        // Progress bar along the bottom.
        let bar = CGRect(x: rect.minX + padding, y: rect.maxY - 8 * scale, width: rect.width - padding * 2, height: 3 * scale)
        context.fill(Path(roundedRect: bar, cornerRadius: 1.5 * scale), with: .color(Color.secondary.opacity(0.25)))
        let pct = min(max(task.percent / 100, 0), 1)
        if pct > 0 {
            let filled = CGRect(x: bar.minX, y: bar.minY, width: bar.width * pct, height: bar.height)
            context.fill(Path(roundedRect: filled, cornerRadius: 1.5 * scale), with: .color(.accentColor.opacity(0.85)))
        }
    }

    /// A diamond-cut hexagon, same convention the Windows app uses to set a milestone box apart from
    /// an ordinary task's plain rounded rectangle.
    private static func milestonePath(in rect: CGRect) -> Path {
        var path = Path()
        let cut = min(14, rect.width * 0.12)
        path.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + cut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }

    // ---- links --------------------------------------------------------------------------------------

    /// Ordinary links first, critical ones next, then anything touching the current selection drawn
    /// last (on top, in the accent color) — same layering the Windows app uses so a selected task's
    /// own connections are never obscured by an unrelated line crossing over them.
    private func drawLinks(context: GraphicsContext, edges: [NetworkEdge]) {
        func isCritical(_ edge: NetworkEdge) -> Bool { showCriticalPath && edge.from.task.isCritical && edge.to.task.isCritical }
        func touchesSelection(_ edge: NetworkEdge) -> Bool {
            guard let selectedTaskId else { return false }
            return edge.from.id == selectedTaskId || edge.to.id == selectedTaskId
        }

        for edge in edges where !isCritical(edge) && !touchesSelection(edge) {
            drawEdge(context: context, edge: edge, color: .secondary, lineWidth: 1)
        }
        for edge in edges where isCritical(edge) && !touchesSelection(edge) {
            drawEdge(context: context, edge: edge, color: .red, lineWidth: 1.6)
        }
        for edge in edges where touchesSelection(edge) {
            drawEdge(context: context, edge: edge, color: highlightColor, lineWidth: 2.2)
        }
    }

    private func drawEdge(context: GraphicsContext, edge: NetworkEdge, color: Color, lineWidth: CGFloat) {
        let fromOrigin = NetworkLayout.position(edge.from)
        let toOrigin = NetworkLayout.position(edge.to)
        let fromRect = CGRect(
            x: fromOrigin.x * scale, y: fromOrigin.y * scale,
            width: NetworkLayout.nodeWidth * scale, height: NetworkLayout.nodeHeight * scale)
        let toRect = CGRect(
            x: toOrigin.x * scale, y: toOrigin.y * scale,
            width: NetworkLayout.nodeWidth * scale, height: NetworkLayout.nodeHeight * scale)

        // Which side of each box the link attaches to depends on the relation type — a Start-Start or
        // Start-Finish link leaves/enters from the left (the task's start), not the right (its finish).
        let leaveRight = !(edge.type == "SS" || edge.type == "SF")
        let enterLeft = !(edge.type == "FF" || edge.type == "SF")
        let a = CGPoint(x: leaveRight ? fromRect.maxX : fromRect.minX, y: fromRect.midY)
        let b = CGPoint(x: enterLeft ? toRect.minX : toRect.maxX, y: toRect.midY)
        let reach = max(30 * scale, abs(b.x - a.x) * 0.45)
        let c1 = CGPoint(x: a.x + (leaveRight ? reach : -reach), y: a.y)
        let c2 = CGPoint(x: b.x + (enterLeft ? -reach : reach), y: b.y)

        var path = Path()
        path.move(to: a)
        path.addCurve(to: b, control1: c1, control2: c2)
        context.stroke(path, with: .color(color.opacity(0.75)), lineWidth: lineWidth * scale)

        let dir: CGFloat = enterLeft ? 1 : -1
        let arrowSize: CGFloat = 5 * scale
        var arrow = Path()
        arrow.move(to: CGPoint(x: b.x - dir * arrowSize, y: b.y - arrowSize * 0.7))
        arrow.addLine(to: b)
        arrow.addLine(to: CGPoint(x: b.x - dir * arrowSize, y: b.y + arrowSize * 0.7))
        context.stroke(arrow, with: .color(color.opacity(0.75)), lineWidth: lineWidth * scale)

        let label = NetworkLayout.relationLabel(type: edge.type, lagDays: edge.lagDays)
        if !label.isEmpty {
            context.draw(
                Text(label).font(.system(size: 8.5 * scale)).foregroundStyle(.secondary),
                at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 10 * scale), anchor: .center)
        }
    }

    private static func dateText(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
