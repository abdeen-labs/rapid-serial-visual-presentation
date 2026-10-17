import SwiftUI

/// Vertical arrangement of the reader: the chrome bars pin to the top and
/// bottom of the safe area, and the word centers on a fixation line fixed to
/// the whole screen or window — not to the space the bars leave, which
/// varies with chapter navigation, Dynamic Type, and safe-area insets.
///
/// The bars keep their layout size while faded out, so nothing here changes
/// when playback starts or stops and the word holds still. The line only
/// yields when the word would run into a bar (see `fixationCenterY`).
///
/// A layout inside the safe area can't see the insets around it, so the
/// caller passes them in from a `GeometryReader`.
struct ReaderStageLayout: Layout {
    nonisolated enum Role {
        case topBar
        case bottomBar
        /// Centered on the fixation line. The default for untagged subviews.
        case fixation
        /// Centered with the fixation subview and proposed the tallest
        /// height around that center that stays clear of both bars. For
        /// content around the word that fits itself to that room instead of
        /// moving the word.
        case fixationSurround
        /// Centered in the space the bars leave. For content that only ever
        /// appears alongside visible bars, where the bars are what it has to
        /// look balanced against.
        case betweenBars
    }

    /// Where the fixation line sits, as a fraction of the full container
    /// height (safe-area insets included). Higher on screen than the midpoint
    /// on purpose: the eye places the middle of a vertical extent a few
    /// percent above its geometric midpoint, so a word at exactly 0.5 reads
    /// as low. A fraction rather than a point offset so the bias scales from
    /// a landscape phone to a 13" iPad.
    nonisolated static let fixationFraction: CGFloat = 0.47

    var topInset: CGFloat
    var bottomInset: CGFloat
    /// The band a folding screen's crease takes across the stage, measured
    /// from the top of the bounds, while the system asks content to stay off
    /// it (see `ReaderFold`). The word moves the least distance that clears it.
    var foldBand: ClosedRange<CGFloat>? = nil
    /// The height of the word itself, which is what has to clear the fold.
    /// The fixation subview's frame is taller.
    var wordHeight: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let fitting = ProposedViewSize(width: bounds.width, height: nil)
        var topBarHeight: CGFloat = 0
        var bottomBarHeight: CGFloat = 0

        for subview in subviews {
            switch subview[ReaderStageRoleKey.self] {
            case .topBar:
                topBarHeight = max(topBarHeight, subview.sizeThatFits(fitting).height)
                subview.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: fitting)
            case .bottomBar:
                bottomBarHeight = max(bottomBarHeight, subview.sizeThatFits(fitting).height)
                subview.place(at: CGPoint(x: bounds.midX, y: bounds.maxY), anchor: .bottom, proposal: fitting)
            case .fixation, .fixationSurround, .betweenBars:
                break
            }
        }

        // Each remaining subview is resolved on its own, so the word holds
        // its place while it cross-fades with the completion card.
        for subview in subviews {
            let centerY: CGFloat
            var proposal = fitting
            switch subview[ReaderStageRoleKey.self] {
            case .topBar, .bottomBar:
                continue
            case .fixation:
                centerY = Self.fixationCenterY(
                    boundsHeight: bounds.height,
                    topInset: topInset,
                    bottomInset: bottomInset,
                    contentHeight: subview.sizeThatFits(fitting).height,
                    topBarHeight: topBarHeight,
                    bottomBarHeight: bottomBarHeight,
                    foldBand: foldBand,
                    wordHeight: wordHeight
                )
            case .fixationSurround:
                let fixation = subviews.first { $0[ReaderStageRoleKey.self] == .fixation }
                centerY = Self.fixationCenterY(
                    boundsHeight: bounds.height,
                    topInset: topInset,
                    bottomInset: bottomInset,
                    contentHeight: fixation?.sizeThatFits(fitting).height ?? 0,
                    topBarHeight: topBarHeight,
                    bottomBarHeight: bottomBarHeight,
                    foldBand: foldBand,
                    wordHeight: wordHeight
                )
                proposal = ProposedViewSize(
                    width: bounds.width,
                    height: 2 * Self.clearHalfHeight(
                        centerY: centerY,
                        boundsHeight: bounds.height,
                        topBarHeight: topBarHeight,
                        bottomBarHeight: bottomBarHeight
                    )
                )
            case .betweenBars:
                centerY = Self.centerBetweenBars(
                    boundsHeight: bounds.height,
                    topBarHeight: topBarHeight,
                    bottomBarHeight: bottomBarHeight
                )
            }
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.minY + centerY), anchor: .center, proposal: proposal)
        }
    }

    /// The y of a fixation subview's center, measured from the top of the
    /// layout's bounds (the safe area).
    ///
    /// Ideally that is the fixation line. If the content would overlap a bar
    /// there, it moves the minimum distance that clears it; if it can't fit
    /// between the bars at all, it centers between them so the overlap is
    /// split evenly.
    ///
    /// A word of `wordHeight` that would sit on `foldBand` moves just above
    /// or below it, whichever is nearer (above on a tie), as long as the
    /// content still clears the bars there.
    nonisolated static func fixationCenterY(
        boundsHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        contentHeight: CGFloat,
        topBarHeight: CGFloat,
        bottomBarHeight: CGFloat,
        foldBand: ClosedRange<CGFloat>? = nil,
        wordHeight: CGFloat = 0
    ) -> CGFloat {
        let containerHeight = topInset + boundsHeight + bottomInset
        let line = containerHeight * fixationFraction - topInset
        let highest = topBarHeight + contentHeight / 2
        let lowest = boundsHeight - bottomBarHeight - contentHeight / 2
        guard highest <= lowest else {
            return centerBetweenBars(
                boundsHeight: boundsHeight,
                topBarHeight: topBarHeight,
                bottomBarHeight: bottomBarHeight
            )
        }
        let center = min(max(line, highest), lowest)
        let half = wordHeight / 2
        guard let foldBand, half > 0,
              center + half > foldBand.lowerBound, center - half < foldBand.upperBound else {
            return center
        }
        return [foldBand.lowerBound - half, foldBand.upperBound + half]
            .filter { (highest...lowest).contains($0) }
            .min { abs($0 - center) < abs($1 - center) } ?? center
    }

    /// How far content centered at `centerY` can reach both up and down
    /// before it meets a bar. Zero when the center is already inside one.
    nonisolated static func clearHalfHeight(
        centerY: CGFloat,
        boundsHeight: CGFloat,
        topBarHeight: CGFloat,
        bottomBarHeight: CGFloat
    ) -> CGFloat {
        max(0, min(centerY - topBarHeight, boundsHeight - bottomBarHeight - centerY))
    }

    /// The midpoint of the space the bars leave, measured from the top of
    /// the layout's bounds.
    nonisolated static func centerBetweenBars(
        boundsHeight: CGFloat,
        topBarHeight: CGFloat,
        bottomBarHeight: CGFloat
    ) -> CGFloat {
        (topBarHeight + boundsHeight - bottomBarHeight) / 2
    }
}

/// Where a folding screen's crease crosses the reader while the system asks
/// content to stay off it: the iPhone Duo's inner screen, half open. Open
/// flat, the fold is inactive and the reader spans it like any screen.
struct ReaderFold {
    /// The narrowest page the reader moves onto rather than span the fold.
    static let minimumPageWidth: CGFloat = 320

    /// A crease running down the screen: the reader keeps to the leading
    /// page, this wide.
    var pageWidth: CGFloat?
    /// A crease running across the screen: the band it takes, measured from
    /// the top of the proxy's frame.
    var band: ClosedRange<CGFloat>?

    init(_ geo: GeometryProxy) {
        guard let fold = ScreenFold.crossing(geo) else { return }
        if fold.runsDown {
            if fold.frame.minX >= Self.minimumPageWidth {
                pageWidth = fold.frame.minX
            }
        } else {
            band = fold.frame.minY...fold.frame.maxY
        }
    }
}

nonisolated private struct ReaderStageRoleKey: LayoutValueKey {
    static let defaultValue: ReaderStageLayout.Role = .fixation
}

extension View {
    func readerStageRole(_ role: ReaderStageLayout.Role) -> some View {
        layoutValue(key: ReaderStageRoleKey.self, value: role)
    }
}
