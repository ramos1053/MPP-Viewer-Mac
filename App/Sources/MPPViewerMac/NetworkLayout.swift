import Foundation

/// A task placed into the Network Diagram's grid by NetworkLayout.nodes(for:): `layer` is its column
/// (dependency depth, left to right), `order` is its row within that layer. `x`/`y` are the final,
/// already-resolved layout position — not a pure function of layer/order alone, since unlinked tasks
/// are placed in their own grid below the network rather than on the layer/order axes at all — so
/// drawing code should always read `x`/`y` via `NetworkLayout.position(_:)`, never recompute a
/// position from layer/order.
struct NetworkNode: Identifiable {
    let task: GanttTask
    let layer: Int
    let order: Int
    let x: CGFloat
    let y: CGFloat
    var id: Int { task.id }
}

/// Pure layout math for the Network Diagram (PERT chart) — no drawing here, see
/// NetworkDiagramView/NetworkCanvasContent for that. Kept separate so the layering/ordering can be
/// reasoned about (and if needed, unit-tested) without any SwiftUI involved.
///
/// Ported from the Windows app's layered (Sugiyama-style) layout
/// (MPP-Viewer/src/MppViewer/Services/NetworkLayout.cs): a task sits one column to the right of its
/// right-most predecessor (longest-path layering), and within a column, tasks are reordered across
/// several sweeps to minimize link crossings (barycenter heuristic). A first cut here just used
/// dependency depth for the column and start-date order for the row, with no crossing minimization —
/// it worked, but the diagram read as a tangle rather than a flow; this port is what makes it read the
/// way the Windows app's does.
enum NetworkLayout {
    static let nodeWidth: CGFloat = 204
    static let nodeHeight: CGFloat = 68
    static let columnGap: CGFloat = 64
    static let rowGap: CGFloat = 24
    static let margin: CGFloat = 28

    /// One task's position in the dependency graph while layout is being computed — a reference type
    /// since layering/ordering mutate nodes in place as the algorithm converges, unlike the finished
    /// value-type NetworkNode this function returns.
    private final class WorkingNode {
        let task: GanttTask
        /// Position in the input array — used as the tie-break when ordering a layer or the loose-task
        /// grid, so layout is deterministic and roughly tracks WBS/display order (same role as the
        /// Windows app's `Row.Id`, which this app has no equivalent row-number field for).
        let originalIndex: Int
        var layer = 0
        var order = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var inEdges: [(from: WorkingNode, type: String, lagDays: Double)] = []
        var outEdges: [(to: WorkingNode, type: String, lagDays: Double)] = []
        init(_ task: GanttTask, originalIndex: Int) {
            self.task = task
            self.originalIndex = originalIndex
        }
    }

    static func nodes(for tasks: [GanttTask]) -> [NetworkNode] {
        guard !tasks.isEmpty else { return [] }

        var byId: [Int: WorkingNode] = [:]
        var working: [WorkingNode] = []
        for (index, task) in tasks.enumerated() {
            let node = WorkingNode(task, originalIndex: index)
            working.append(node)
            byId[task.id] = node
        }
        for node in working {
            for link in node.task.links {
                guard let predecessor = byId[link.predecessorId], predecessor !== node else { continue }
                predecessor.outEdges.append((to: node, type: link.type, lagDays: link.lagDays))
                node.inEdges.append((from: predecessor, type: link.type, lagDays: link.lagDays))
            }
        }

        assignLayers(working)
        let layers = orderLayers(working)
        place(layers: layers, loose: working.filter { $0.layer < 0 })

        return working.map { NetworkNode(task: $0.task, layer: $0.layer, order: $0.order, x: $0.x, y: $0.y) }
    }

    /// Longest-path layering: a task's layer is one past its latest (highest-layer) predecessor. A
    /// cycle — which shouldn't exist in a valid project, but this app's own predecessor editor can
    /// only reject a cycle it's told about, so one introduced any other way must not hang layout
    /// forever — is broken by treating a node already on the current recursion path as having no
    /// predecessors.
    private static func assignLayers(_ working: [WorkingNode]) {
        enum VisitState { case inProgress, done }
        var state: [ObjectIdentifier: VisitState] = [:]

        func visit(_ node: WorkingNode) -> Int {
            let key = ObjectIdentifier(node)
            if let existing = state[key] { return existing == .done ? node.layer : 0 }
            state[key] = .inProgress
            var layer = 0
            for edge in node.inEdges {
                if state[ObjectIdentifier(edge.from)] == .inProgress { continue }
                layer = max(layer, visit(edge.from) + 1)
            }
            node.layer = layer
            state[key] = .done
            return layer
        }

        // Tasks with no links at all go in their own block below the network, not column 0.
        for node in working where node.inEdges.isEmpty && node.outEdges.isEmpty { node.layer = -1 }
        let linked = working.filter { !$0.inEdges.isEmpty || !$0.outEdges.isEmpty }
        for node in linked { _ = visit(node) }
        // A start task sits just before its earliest successor instead of piling up in column 0.
        for node in linked where node.inEdges.isEmpty {
            if let earliestSuccessorLayer = node.outEdges.map({ $0.to.layer }).min() {
                node.layer = earliestSuccessorLayer - 1
            }
        }
    }

    /// Barycenter crossing-minimization: 6 sweeps alternating left-to-right and right-to-left, each
    /// reordering every layer by the average position of its already-ordered neighbours in the
    /// adjacent layer. Nodes with no neighbours in that direction (e.g. the very first/last layer, or
    /// a node with only successors when sweeping left-to-right) keep their current slot.
    private static func orderLayers(_ working: [WorkingNode]) -> [[WorkingNode]] {
        let layerCount = (working.filter { $0.layer >= 0 }.map(\.layer).max() ?? -1) + 1
        guard layerCount > 0 else { return [] }

        var layers: [[WorkingNode]] = Array(repeating: [], count: layerCount)
        for node in working where node.layer >= 0 {
            layers[node.layer].append(node)
        }
        for i in layers.indices {
            layers[i].sort { $0.originalIndex < $1.originalIndex }
            for (order, node) in layers[i].enumerated() { node.order = order }
        }

        for sweep in 0..<6 {
            let down = sweep % 2 == 0
            let range: [Int] = down
                ? Array(1..<max(layerCount, 1))
                : Array((0..<max(layerCount - 1, 0)).reversed())
            for layerIndex in range {
                let layer = layers[layerIndex]
                let keyed: [(node: WorkingNode, key: Double?)] = layer.map { node in
                    let neighbours = down ? node.inEdges.map(\.from) : node.outEdges.map(\.to)
                    guard !neighbours.isEmpty else { return (node, nil) }
                    let average = Double(neighbours.reduce(0) { $0 + $1.order }) / Double(neighbours.count)
                    return (node, average)
                }
                // Nodes without neighbours in this direction keep their current slot; the rest fill the
                // remaining positions, ordered by their neighbours' average position.
                let movable = keyed
                    .filter { $0.key != nil }
                    .sorted { ($0.key!, $0.node.order) < ($1.key!, $1.node.order) }
                    .map(\.node)
                var result = [WorkingNode?](repeating: nil, count: layer.count)
                for entry in keyed where entry.key == nil { result[entry.node.order] = entry.node }
                var movableIndex = 0
                for i in result.indices where result[i] == nil {
                    result[i] = movable[movableIndex]
                    movableIndex += 1
                }
                layers[layerIndex] = result.compactMap { $0 }
                for (order, node) in layers[layerIndex].enumerated() { node.order = order }
            }
        }
        return layers
    }

    /// Resolves every node's final x/y: laid-out tasks sit on the layer/order grid; tasks with no
    /// links at all (never assigned a layer) are placed in a tidy grid of their own below the network,
    /// as wide as the network itself (at least 4 across) — same convention as the Windows app's, so an
    /// unscheduled or orphaned task doesn't just vanish into column 0 mixed in with real chains.
    private static func place(layers: [[WorkingNode]], loose: [WorkingNode]) {
        for layer in layers {
            for node in layer {
                node.x = margin + CGFloat(node.layer) * (nodeWidth + columnGap)
                node.y = margin + CGFloat(node.order) * (nodeHeight + rowGap)
            }
        }
        let layerCount = layers.count
        let maxRows = layers.map(\.count).max() ?? 0
        let width = margin * 2 + CGFloat(max(layerCount, 1)) * (nodeWidth + columnGap) - columnGap
        let height = maxRows == 0 ? margin : margin + CGFloat(maxRows) * (nodeHeight + rowGap) - rowGap + rowGap * 2

        let sortedLoose = loose.sorted { $0.originalIndex < $1.originalIndex }
        guard !sortedLoose.isEmpty else { return }
        var perRow = max(4, max(layerCount, 1))
        if width < margin * 2 + CGFloat(perRow) * (nodeWidth + columnGap) - columnGap {
            perRow = max(4, Int((width - margin * 2 + columnGap) / (nodeWidth + columnGap)))
        }
        for (i, node) in sortedLoose.enumerated() {
            node.order = i
            node.x = margin + CGFloat(i % perRow) * (nodeWidth + columnGap)
            node.y = height + CGFloat(i / perRow) * (nodeHeight + rowGap)
        }
    }

    /// Where to draw a node — already resolved by `place`, not a function of layer/order alone (loose
    /// tasks don't sit on that grid at all), so this is just a thin accessor, not a computation.
    static func position(_ node: NetworkNode) -> CGPoint { CGPoint(x: node.x, y: node.y) }

    /// The unscaled size of the whole diagram — callers multiply by the current zoom scale. Derived
    /// from the actual resolved bounds of every node (rather than threading width/height out of
    /// `place` separately) so this can never drift out of sync with where nodes are actually drawn.
    static func contentSize(for nodes: [NetworkNode]) -> CGSize {
        guard !nodes.isEmpty else { return CGSize(width: 1, height: 1) }
        let maxX = nodes.map(\.x).max() ?? 0
        let maxY = nodes.map(\.y).max() ?? 0
        return CGSize(width: maxX + nodeWidth + margin, height: maxY + nodeHeight + margin)
    }

    /// The scale that fits the whole diagram inside `paneSize` — same role as ganttFitPixelsPerDay,
    /// but 2D since a diagram has both a width and a height to fit, not just a date span.
    static func fitScale(contentSize: CGSize, paneSize: CGSize) -> CGFloat {
        guard contentSize.width > 0, contentSize.height > 0, paneSize.width > 0, paneSize.height > 0 else { return 1 }
        let scale = min(paneSize.width / contentSize.width, paneSize.height / contentSize.height)
        return min(max(scale, 0.1), 3)
    }

    /// Which node (if any) contains `point`, given in the same scaled coordinate space the Canvas
    /// draws in — shared by both the SwiftUI selection overlay and the AppKit pan/zoom overlay
    /// (NetworkScrollHost) so there's one definition of "what's under the cursor," not two.
    static func node(at point: CGPoint, in nodes: [NetworkNode], scale: CGFloat) -> NetworkNode? {
        nodes.first { node in
            let rect = CGRect(x: node.x * scale, y: node.y * scale, width: nodeWidth * scale, height: nodeHeight * scale)
            return rect.contains(point)
        }
    }

    /// "FS+1d", "SS-2d", "FF" — same convention the Windows app uses for its predecessor column and
    /// edge labels. Empty for the (unlabeled) default: plain finish-to-start, no lag.
    static func relationLabel(type: String, lagDays: Double) -> String {
        var text = type == "FS" ? "" : type
        guard lagDays != 0 else { return text }
        if text.isEmpty { text = "FS" }
        let rounded = (lagDays * 100).rounded() / 100
        let magnitude = rounded.rounded() == rounded ? String(Int(abs(rounded))) : String(format: "%.2f", abs(rounded))
        return text + (rounded > 0 ? "+" : "-") + magnitude + "d"
    }
}
