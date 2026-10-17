import SwiftUI

// The reader and the passage view draw their own bars on the reading surface
// instead of using a navigation bar, which would move the word as it showed
// and hid. These pieces make those bars look like the system's: Liquid Glass
// on iOS and macOS 26 and later, the elevated surface before that.

extension View {
    /// Backs the view with the reader's glass in `shape`, for a group of
    /// controls that share one piece of it. Buttons on their own use
    /// ``ReaderGlassButtonStyle``, which reacts to touch.
    @ViewBuilder
    func readerGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(StrobeTheme.elevatedSurface, in: shape)
        }
    }
}

/// A button on the reading surface, its label on a piece of the reader's
/// glass in `shape`. The glass reacts to touch where it's available;
/// before that, the surface lightens while pressed.
struct ReaderGlassButtonStyle<S: Shape>: ButtonStyle {
    let shape: S
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .opacity(isEnabled ? 1 : 0.3)
            .contentShape(shape)
        if #available(iOS 26.0, macOS 26.0, *) {
            label.glassEffect(.regular.interactive(), in: shape)
        } else {
            label
                .background(StrobeTheme.elevatedSurface, in: shape)
                .overlay {
                    shape.fill(.white.opacity(configuration.isPressed ? 0.08 : 0))
                }
        }
    }
}

/// A button inside a shared piece of reader glass (see `readerGlass(in:)`):
/// its label alone, dimmed while pressed or disabled.
struct ReaderGlassItemButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.45 : 1) : 0.3)
    }
}

/// A 44 pt round icon button on the reading surface, like a bar button.
/// The icon keeps the bar size at every text size, as the system's do.
struct ReaderGlassButton: View {
    let systemImage: String
    let accessibilityLabel: String
    /// The icon's color; the primary text color when nil.
    var tint: Color? = nil
    var diameter: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .frame(width: diameter, height: diameter)
        }
        .buttonStyle(ReaderGlassButtonStyle(shape: Circle()))
        .accessibilityLabel(accessibilityLabel)
    }
}
