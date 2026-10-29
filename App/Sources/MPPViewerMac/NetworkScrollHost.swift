import SwiftUI
import AppKit

/// Hosts the Network Diagram's SwiftUI content in a real NSScrollView rather than a plain SwiftUI
/// ScrollView, so this view can own AppKit-level gestures SwiftUI has no public API for: click-and-
/// drag anywhere pans (open-hand cursor at rest, closed-hand mid-drag — same gesture as Preview or
/// Photos panning a zoomed image); a plain two-finger scroll/mouse wheel pans too, the ordinary way;
/// Command+scroll or a pinch zooms, anchored under the cursor so whatever you're looking at is what
/// stays put.
struct NetworkScrollHost<Content: View & Equatable>: NSViewRepresentable {
    let content: Content
    let contentSize: CGSize
    let hitTest: (CGPoint) -> Int?
    let onSelect: (Int) -> Void
    let onZoom: (CGFloat) -> Void
    /// Double-click, or right-click → "Jump to WBS" — same destination as Calendar's.
    let onJumpToWBS: (Int) -> Void
    /// Right-click → "Delete Task" — routes through AppModel.pendingTaskAction like every other
    /// delete entry point, same as Calendar's.
    let onDeleteRequest: (Int) -> Void
    /// Right-click → "Notes…" — edits the same field, shown in an NSPopover (not a SwiftUI
    /// `.popover`, since this click comes from the AppKit overlay below, not a SwiftUI view).
    let onEditNotes: (Int, String) -> Void
    /// Current Notes text for a task id, to prefill the "Notes…" popover.
    let notesText: (Int) -> String
    /// The scaled-content-coordinate point (a selected node's center) to scroll into view when
    /// `scrollTrigger` changes — nil skips it. Scrolling is driven by `scrollTrigger`, not by
    /// `scrollTarget` itself changing: `scrollTarget` tracks the current selection continuously (so
    /// it's always accurate whenever a scroll *is* requested), but selecting something with a plain
    /// click inside Network shouldn't itself re-center the view — only an explicit "bring the
    /// selection into view" request (switching into Network from elsewhere) should, same as Gantt's
    /// onAppear-only scrollToCurrentSelection and Calendar's onAppear-only navigateToSelection.
    let scrollTarget: CGPoint?
    let scrollTrigger: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.documentView = hosting

        let overlay = PanZoomOverlayView(frame: hosting.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.scrollView = scrollView
        hosting.addSubview(overlay)

        context.coordinator.hostingView = hosting
        context.coordinator.overlay = overlay
        context.coordinator.lastContent = content
        context.coordinator.lastSize = contentSize
        updateCallbacks(overlay, coordinator: context.coordinator)
        return scrollView
    }

    /// The content-space fraction (0...1 in each axis) at the current viewport's center, plus a
    /// zero viewport offset — i.e. "keep whatever's in the middle of the view in the middle,"
    /// the fallback anchor for any resize that didn't come with a more specific cursor/pinch
    /// location (the toolbar's Zoom In/Out, or a content-size change from something other than a
    /// zoom at all).
    private static func viewportCenterAnchor(oldSize: CGSize, clipView: NSClipView) -> (fraction: CGPoint, viewportOffset: CGPoint)? {
        guard oldSize.width > 0, oldSize.height > 0 else { return nil }
        let viewport = clipView.bounds
        let center = CGPoint(x: viewport.midX, y: viewport.midY)
        return (
            fraction: CGPoint(x: center.x / oldSize.width, y: center.y / oldSize.height),
            viewportOffset: CGPoint(x: viewport.width / 2, y: viewport.height / 2))
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let hosting = context.coordinator.hostingView, let overlay = context.coordinator.overlay else { return }
        updateCallbacks(overlay, coordinator: context.coordinator)

        if context.coordinator.lastContent != content {
            hosting.rootView = content
            context.coordinator.lastContent = content
        }
        if context.coordinator.lastSize != contentSize {
            let oldSize = context.coordinator.lastSize
            let clipView = nsView.contentView
            // Whatever content point the zoom should hold fixed on screen — the real cursor/pinch
            // location when the overlay just captured one, otherwise the current viewport center,
            // so even the toolbar's Zoom In/Out (no cursor event to anchor on) keeps showing
            // roughly the same region instead of drifting toward the content's top-left corner.
            // Applying this on every resize (not just zoom) is deliberate too: it's what keeps an
            // edit that changes the diagram's size (e.g. adding a task) from silently resetting
            // the scroll position either.
            let anchor = context.coordinator.pendingZoomAnchor
                ?? Self.viewportCenterAnchor(oldSize: oldSize, clipView: clipView)
            context.coordinator.pendingZoomAnchor = nil

            hosting.frame = CGRect(origin: .zero, size: contentSize)
            context.coordinator.lastSize = contentSize

            if let anchor, oldSize.width > 0, oldSize.height > 0 {
                let newContentPoint = CGPoint(
                    x: anchor.fraction.x * contentSize.width, y: anchor.fraction.y * contentSize.height)
                var origin = CGPoint(
                    x: newContentPoint.x - anchor.viewportOffset.x, y: newContentPoint.y - anchor.viewportOffset.y)
                origin.x = max(0, min(origin.x, max(0, contentSize.width - clipView.bounds.width)))
                origin.y = max(0, min(origin.y, max(0, contentSize.height - clipView.bounds.height)))
                clipView.scroll(to: origin)
                nsView.reflectScrolledClipView(clipView)
            }
        }
        if let target = scrollTarget, context.coordinator.lastScrollTrigger != scrollTrigger {
            context.coordinator.lastScrollTrigger = scrollTrigger
            let clipView = nsView.contentView
            var origin = CGPoint(x: target.x - clipView.bounds.width / 2, y: target.y - clipView.bounds.height / 2)
            origin.x = max(0, origin.x)
            origin.y = max(0, origin.y)
            clipView.scroll(to: origin)
            nsView.reflectScrolledClipView(clipView)
        }
    }

    private func updateCallbacks(_ overlay: PanZoomOverlayView, coordinator: Coordinator) {
        overlay.hitTest = hitTest
        overlay.onSelect = onSelect
        overlay.onZoom = onZoom
        overlay.onJumpToWBS = onJumpToWBS
        overlay.onDeleteRequest = onDeleteRequest
        overlay.onEditNotes = onEditNotes
        overlay.notesText = notesText
        overlay.captureZoomAnchor = { [weak coordinator] fraction, viewportOffset in
            coordinator?.pendingZoomAnchor = (fraction, viewportOffset)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastContent: Content?
        var lastSize: CGSize = .zero
        var lastScrollTrigger = 0
        var hostingView: NSHostingView<Content>?
        fileprivate var overlay: PanZoomOverlayView?
        /// Set by the overlay just before it calls `onZoom` for a cursor- or pinch-anchored zoom —
        /// consumed (and cleared) the next time `updateNSView` sees `contentSize` actually change,
        /// since that's the only point a new scroll origin can be computed/applied. `fraction` is
        /// the anchor's position as a 0...1 fraction of the *old* content size; `viewportOffset` is
        /// where that point sat within the visible viewport, which has to stay put after the resize.
        fileprivate var pendingZoomAnchor: (fraction: CGPoint, viewportOffset: CGPoint)?
    }
}

/// Sits as the frontmost subview over the hosted content, so it sees every mouse/scroll event
/// before SwiftUI's own internal view tree does. Panning is handled directly against `scrollView`
/// here (a pure AppKit concern); click-to-select and zoom call back out via closures, since those
/// need to change state that lives on the Swift side (`selectedTaskId`, `networkScale`).
fileprivate final class PanZoomOverlayView: NSView {
    weak var scrollView: NSScrollView?
    var hitTest: ((CGPoint) -> Int?)?
    var onSelect: ((Int) -> Void)?
    var onJumpToWBS: ((Int) -> Void)?
    var onDeleteRequest: ((Int) -> Void)?
    var onEditNotes: ((Int, String) -> Void)?
    var notesText: ((Int) -> String)?
    /// Multiplicative zoom factor: >1 zooms in, <1 zooms out.
    var onZoom: ((CGFloat) -> Void)?
    /// Called with (fraction-of-content, offset-within-viewport) just before `onZoom`, for a zoom
    /// that has a real anchor point (Cmd+scroll, pinch) to hold fixed on screen — NetworkScrollHost
    /// stashes it and applies the matching scroll correction once the resulting `contentSize`
    /// change actually lands. Not called for a zoom with no such point (there isn't one for the
    /// toolbar's Zoom In/Out); NetworkScrollHost falls back to the viewport center for those.
    var captureZoomAnchor: ((CGPoint, CGPoint) -> Void)?

    private var mouseDownPoint: NSPoint?
    private var lastDragPoint: NSPoint?
    private var didDrag = false
    private var isDoubleClick = false
    private var notesPopover: NSPopover?
    private var lastContextMenuPoint: NSPoint = .zero

    /// Matches NSHostingView's own coordinate convention (top-left origin, y increasing downward) —
    /// needed so points this view converts/reports line up with NetworkLayout's same convention.
    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        lastDragPoint = event.locationInWindow
        didDrag = false
        isDoubleClick = event.clickCount >= 2
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downPoint = mouseDownPoint, let last = lastDragPoint, let clipView = scrollView?.contentView else { return }
        let dx = event.locationInWindow.x - last.x
        let dy = event.locationInWindow.y - last.y
        lastDragPoint = event.locationInWindow

        if !didDrag, abs(event.locationInWindow.x - downPoint.x) > 3 || abs(event.locationInWindow.y - downPoint.y) > 3 {
            didDrag = true
        }

        // event.locationInWindow is AppKit's unflipped window space (y increases upward); the clip
        // view's bounds.origin is flipped document space (y increases downward, same as
        // NetworkLayout) — dragging the mouse up therefore means scrolling further down (origin.y
        // increases), and dragging right means scrolling left (origin.x decreases): content follows
        // the cursor, like grabbing a piece of paper.
        var origin = clipView.bounds.origin
        origin.x = max(0, origin.x - dx)
        origin.y = max(0, origin.y + dy)
        clipView.scroll(to: origin)
        scrollView?.reflectScrolledClipView(clipView)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.openHand.set()
        if !didDrag {
            let point = convert(event.locationInWindow, from: nil)
            if let id = hitTest?(point) {
                if isDoubleClick {
                    onJumpToWBS?(id)
                } else {
                    onSelect?(id)
                }
            }
        }
        mouseDownPoint = nil
        lastDragPoint = nil
    }

    /// AppKit's standard right-click-context-menu hook — same three actions as Calendar's
    /// `.contextMenu`: Jump to WBS, Notes…, and Delete Task.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let id = hitTest?(point) else { return nil }
        lastContextMenuPoint = point

        let menu = NSMenu()
        let jump = NSMenuItem(title: "Jump to WBS", action: #selector(menuJumpToWBS(_:)), keyEquivalent: "")
        jump.representedObject = id
        jump.target = self
        menu.addItem(jump)

        let notes = NSMenuItem(title: "Notes…", action: #selector(menuEditNotes(_:)), keyEquivalent: "")
        notes.representedObject = id
        notes.target = self
        menu.addItem(notes)

        menu.addItem(.separator())

        let delete = NSMenuItem(title: "Delete Task", action: #selector(menuDeleteTask(_:)), keyEquivalent: "")
        delete.representedObject = id
        delete.target = self
        menu.addItem(delete)

        return menu
    }

    @objc private func menuJumpToWBS(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int else { return }
        onJumpToWBS?(id)
    }

    @objc private func menuDeleteTask(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int else { return }
        onDeleteRequest?(id)
    }

    @objc private func menuEditNotes(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int else { return }
        showNotesPopover(taskId: id, near: lastContextMenuPoint)
    }

    /// Hosts the shared SwiftUI NotesEditor (same one the WBS table's Notes cell and Calendar's
    /// right-click use) inside a plain NSPopover anchored near the clicked box, since this click
    /// comes from the AppKit overlay rather than a SwiftUI view that could use `.popover` directly.
    private func showNotesPopover(taskId: Int, near point: CGPoint) {
        let initial = notesText?(taskId) ?? ""
        let popover = NSPopover()
        let editor = NotesEditor(
            initialNotes: initial,
            onApply: { [weak self] text in
                self?.onEditNotes?(taskId, text)
                popover.close()
            },
            onCancel: { popover.close() })
        popover.contentViewController = NSHostingController(rootView: editor)
        popover.behavior = .transient
        notesPopover = popover
        let anchorRect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        popover.show(relativeTo: anchorRect, of: self, preferredEdge: .maxY)
    }

    /// A plain two-finger scroll/mouse wheel pans natively (handing the event up to the enclosing
    /// NSScrollView, same as any ordinary scrolling document) — click-and-drag already covers
    /// panning, so this is a second, more familiar way to do the same thing. Only Command+scroll
    /// zooms, the standard modifier for it elsewhere on the Mac (Maps, Xcode's minimap, Figma),
    /// anchored under the cursor so the spot you're looking at is what stays put — not the diagram
    /// recentering on you, you staying put over the diagram.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        // Trackpad two-finger scroll arrives with many small precise deltas per gesture; a physical
        // mouse wheel arrives as a few larger, imprecise ones — scaled differently so either one
        // feels like a comparably-paced zoom. Both tunable if the feel is off in practice.
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.004 : 0.04
        let factor = 1 + (event.scrollingDeltaY * sensitivity)
        guard factor > 0 else { return }
        performZoom(factor: factor, atWindowPoint: event.locationInWindow)
    }

    /// Pinch-to-zoom — anchored at the pinch location for the same reason Command+scroll is
    /// anchored at the cursor.
    override func magnify(with event: NSEvent) {
        performZoom(factor: 1 + event.magnification, atWindowPoint: event.locationInWindow)
    }

    /// Captures where `windowPoint` sits — both as a fraction of the current (pre-zoom) content
    /// size, and as an offset within the currently visible viewport — so NetworkScrollHost can hold
    /// that exact spot fixed on screen once the resulting content-size change lands. Falls back to
    /// an un-anchored zoom if there's no clip view yet (shouldn't normally happen).
    private func performZoom(factor: CGFloat, atWindowPoint windowPoint: NSPoint) {
        guard let clipView = scrollView?.contentView else {
            onZoom?(factor)
            return
        }
        let oldSize = bounds.size
        guard oldSize.width > 0, oldSize.height > 0 else {
            onZoom?(factor)
            return
        }
        let contentPoint = convert(windowPoint, from: nil)
        let fraction = CGPoint(x: contentPoint.x / oldSize.width, y: contentPoint.y / oldSize.height)
        let viewportOffset = CGPoint(
            x: contentPoint.x - clipView.bounds.origin.x, y: contentPoint.y - clipView.bounds.origin.y)
        captureZoomAnchor?(fraction, viewportOffset)
        onZoom?(factor)
    }
}
