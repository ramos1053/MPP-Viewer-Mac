import SwiftUI

/// A small curated palette rather than a full color picker — "pick one of these" is enough for a
/// selection-highlight preference and avoids needing to persist an arbitrary Color through
/// AppStorage (which has no native Color support), while still giving a real choice beyond a single
/// hardcoded color.
enum HighlightColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple

    var id: Self { self }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }

    var label: String { rawValue.capitalized }
}
