import SwiftUI
import AppKit

/// The task list and Gantt chart panes scroll independently — dragging one no longer drags the
/// other, since a permanent lockstep sync between them didn't actually make sense (you often want
/// to look at a date range on the chart far from whatever's scrolled into view on the list, or vice
/// versa). What this still does is the "snap into sync" half: selecting a row (clicking it in the
/// task list, arrow-keying to it, or jumping to a predecessor) explicitly scrolls *both* panes to
/// center that row, via `scrollToRow` — a one-shot command, not a continuous follow.
final class GanttScrollSync {
    private weak var left: NSScrollView?
    private weak var right: NSScrollView?

    func register(left scrollView: NSScrollView) {
        left = scrollView
    }

    func register(right scrollView: NSScrollView) {
        right = scrollView
    }

    /// Centers the given row in both panes at once — the task list (so the selected row is visible
    /// there) and the Gantt chart (so its bar is visible too, "snapping back in sync" with whatever
    /// was just selected).
    func scrollToRow(_ index: Int) {
        guard let anchor = left ?? right else { return }
        let targetY = max(0, CGFloat(index) * ganttRowHeight + ganttHeaderHeight
            - (anchor.contentView.bounds.height - ganttRowHeight) / 2)
        for scrollView in [left, right].compactMap({ $0 }) {
            var origin = scrollView.contentView.bounds.origin
            origin.y = targetY
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

/// Hosts SwiftUI content at a fixed size inside a real, independently-scrolling NSScrollView, and
/// registers it with a GanttScrollSync so its vertical position stays locked to its partner pane.
struct SyncedScrollHost<Content: View & Equatable>: NSViewRepresentable {
    enum Role: Equatable { case left, right }

    let content: Content
    let contentSize: CGSize
    let allowsHorizontalScroll: Bool
    let sync: GanttScrollSync
    let role: Role

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = allowsHorizontalScroll
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let hosting = NSHostingView(rootView: content)
        hosting.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.documentView = hosting
        context.coordinator.hostingView = hosting
        context.coordinator.lastContent = content
        context.coordinator.lastSize = contentSize

        switch role {
        case .left: sync.register(left: scrollView)
        case .right: sync.register(right: scrollView)
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let hosting = context.coordinator.hostingView else { return }
        // Skip the rebuild entirely when neither the data nor the size actually changed — without
        // this, every pixel of an unrelated divider drag re-diffs/redraws the full row list or
        // chart canvas just because ContentView.body re-evaluated, which is what caused the jank.
        if context.coordinator.lastContent != content {
            hosting.rootView = content
            context.coordinator.lastContent = content
        }
        if context.coordinator.lastSize != contentSize {
            hosting.frame = CGRect(origin: hosting.frame.origin, size: contentSize)
            context.coordinator.lastSize = contentSize
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastContent: Content?
        var lastSize: CGSize?
        var hostingView: NSHostingView<Content>?
    }
}
