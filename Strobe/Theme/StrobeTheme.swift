import SwiftUI

/// Centralized design tokens for the Strobe app — colors, gradients, and typography.
struct StrobeTheme {
    static let background = Color(hex: "050505") // Deep, almost black
    static let surface = Color(hex: "121212") // Slightly lighter for cards/sheets
    /// Grouped rows and cards on the library's near-black canvas; matches
    /// the system's dark grouped-row color.
    static let elevatedSurface = Color(hex: "1C1C1E")
    static let accent = Color(hex: "FF3B30") // Vibrant Red/Orange - "Strobe Red"
    static let textPrimary = Color(hex: "FAFAFA") // Off-white
    static let textSecondary = Color(hex: "A0A0A0") // Grey

    struct Gradients {
        static let mainBackground = LinearGradient(
            colors: [Color(hex: "050505"), Color(hex: "0A0A0A")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Typography

    /// Fraunces SemiBold for book titles and headlines outside the reader,
    /// scaling with Dynamic Type relative to `style`.
    static func displayFont(size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom("Fraunces-SemiBold", size: size, relativeTo: style)
    }

    /// Fraunces SemiBold at a fixed size, for type drawn as part of an image
    /// such as a generated cover.
    static func displayFont(fixedSize size: CGFloat) -> Font {
        .custom("Fraunces-SemiBold", fixedSize: size)
    }

    /// Small secondary text such as reading status and word counts. macOS's
    /// footnote style (10pt) is too small for it.
    static var metadataFont: Font {
        #if os(macOS)
        .callout
        #else
        .footnote
        #endif
    }
}

extension Color {
    /// Initializes a Color from a hex string (supports 3, 6, and 8 character formats).
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

/// A button style with a subtle scale-down press animation for card-style buttons.
struct StrobeCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

extension View {
    /// Constrains the view's width to `maxWidth` (typically a readable column on
    /// iPad/Mac) and horizontally centers it in the parent. When `maxWidth` is
    /// `.infinity` the view simply fills the available width.
    @ViewBuilder
    func constrainedAndCentered(maxWidth: CGFloat) -> some View {
        if maxWidth == .infinity {
            self.frame(maxWidth: .infinity)
        } else {
            self
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
        }
    }
}
