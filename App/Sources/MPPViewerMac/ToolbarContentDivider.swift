import SwiftUI

/// A faint hairline marking the boundary between a window's toolbar and its content below — the
/// modern "unified"/edge-to-edge toolbar style this app uses has no divider there by default.
///
/// Every top-level pane this app shows in the main window (the Gantt view today; a future Resource
/// Sheet, Network Diagram, etc.) should put this as the very first thing in its body, so the
/// toolbar/content boundary looks and behaves the same no matter which view is active — one shared
/// place to adjust that line, rather than each view drawing its own.
struct ToolbarContentDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(maxWidth: .infinity)
            .frame(height: 1)
    }
}
