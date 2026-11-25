import SwiftUI

/// The vertical line that marks where the anchor letter sits, and the
/// choices Settings gives for it: its style, opacity (`guideLineOpacity`),
/// and thickness (`guideLineWidth`). Its color follows the anchor letter's,
/// and its height the word's size (``WordView/guideLineHeightRatio``).
nonisolated enum GuideLine {
    enum Style: String, CaseIterable, Identifiable {
        /// The UserDefaults key used to persist the choice.
        static let storageKey = "guideLineStyle"
        static let defaultValue: Style = .line

        /// One line behind the word, through the anchor letter.
        case line
        /// A tick above the word and one below, clear of its letters, so
        /// they stay out of the anchor letter's way at any opacity.
        case ticks

        var id: String { rawValue }

        /// Resolves a stored raw value to a case, falling back to the default.
        static func resolve(_ rawValue: String) -> Style {
            Style(rawValue: rawValue) ?? defaultValue
        }

        var displayName: String {
            switch self {
            case .line: "Line"
            case .ticks: "Ticks"
            }
        }
    }

    /// From hidden to the anchor letter's full color.
    static let opacityRange: ClosedRange<Double> = 0...1
    static let opacityStep = 0.05
    /// In points.
    static let widthRange: ClosedRange<Double> = 0.5...5
    static let widthStep = 0.5

    /// The room the ticks leave the word between them, as a multiple of the
    /// font size: past the ascenders and descenders of every reader font.
    static let tickGapRatio: CGFloat = 1.16

    /// The value one press of − or + moves `value` to: the next whole
    /// `step` below or above it, held to `range`, or nil at the range's
    /// end. A value between two steps, as the default opacity is, lands on
    /// the nearer one in that direction.
    static func stepped(
        _ value: Double,
        by step: Double,
        up: Bool,
        in range: ClosedRange<Double>
    ) -> Double? {
        guard step > 0 else { return nil }
        // Wide enough to take a value a hair off a step for that step.
        let tolerance = 1e-6
        let position = value / step
        let target = up
            ? (position + tolerance).rounded(.down) + 1
            : (position - tolerance).rounded(.up) - 1
        let next = min(range.upperBound, max(range.lowerBound, target * step))
        return abs(next - value) < step * tolerance ? nil : next
    }
}

/// The guide line as the word view draws it, centered on the anchor letter.
struct GuideLineView: View {
    let style: GuideLine.Style
    /// The anchor letter's color.
    let color: Color
    let opacity: Double
    let width: CGFloat
    /// The word's size as drawn.
    let fontSize: CGFloat

    var body: some View {
        let height = fontSize * WordView.guideLineHeightRatio
        switch style {
        case .line:
            Rectangle()
                .fill(color.opacity(opacity))
                .frame(width: width, height: height)
        case .ticks:
            let gap = fontSize * GuideLine.tickGapRatio
            VStack(spacing: gap) {
                tick(height: (height - gap) / 2)
                tick(height: (height - gap) / 2)
            }
        }
    }

    private func tick(height: CGFloat) -> some View {
        Rectangle()
            .fill(color.opacity(opacity))
            .frame(width: width, height: max(0, height))
    }
}
