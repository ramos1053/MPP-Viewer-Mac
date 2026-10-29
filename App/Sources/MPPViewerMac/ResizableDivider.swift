import SwiftUI
import AppKit

/// SwiftUI's `.onHover` + imperative `NSCursor` calls are unreliable right at a view boundary
/// (cursor can stay stuck as the system arrow). `resetCursorRects` is the AppKit-native, reliable
/// mechanism for "this exact region always shows this cursor while the mouse is over it."
private final class CursorRectView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}

private struct ResizeCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorRectView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

/// HSplitView's built-in divider turned out not to be hit-testable reliably once the adjacent
/// panes are scroll-heavy, so this is a plain, directly-controlled drag handle instead: a visible
/// bar that resizes a width binding, with a resize cursor over its hit area.
struct ResizableDivider: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    @State private var dragStartWidth: CGFloat?
    @State private var liveOffset: CGFloat = 0
    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        ZStack {
            ResizeCursorArea()
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
            Rectangle()
                .fill((isHovering || isDragging) ? Color.accentColor.opacity(0.4) : Color.clear)
                .frame(width: 5)
        }
        .frame(width: 12)
        .contentShape(Rectangle())
        // Live drag feedback: a free-floating line that tracks the cursor with zero relayout cost,
        // decoupled from the real pane width. Actually resizing the two heavy panes (one hosts a
        // multi-thousand-pixel canvas) on every pixel of a fast drag can't keep up — see history —
        // so the real, single resize only commits once, on release.
        .overlay(
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 5)
                .offset(x: liveOffset)
                .opacity(isDragging ? 1 : 0)
                .allowsHitTesting(false)
        )
        .onHover { isHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = width
                        isDragging = true
                    }
                    let base = dragStartWidth ?? width
                    let clamped = min(max(base + value.translation.width, minWidth), maxWidth)
                    liveOffset = clamped - base
                }
                .onEnded { value in
                    let base = dragStartWidth ?? width
                    width = min(max(base + value.translation.width, minWidth), maxWidth)
                    dragStartWidth = nil
                    liveOffset = 0
                    isDragging = false
                }
        )
    }
}
