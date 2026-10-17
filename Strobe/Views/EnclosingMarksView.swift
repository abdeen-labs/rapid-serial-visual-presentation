import SwiftUI

/// Sizes, places, and fades the opening marks kept above the word.
nonisolated enum EnclosingMarksLayout {
    struct Metrics: Equatable {
        let fontSize: CGFloat
        /// Distance from the word's center up to the center of the marks'
        /// slot.
        let offset: CGFloat

        /// Height of the slot the marks are centered in.
        var slotHeight: CGFloat { fontSize * EnclosingMarksLayout.slotHeightRatio }

        /// Distance from the word's center to the top of the marks' slot.
        var reach: CGFloat { offset + slotHeight / 2 }
    }

    /// Mark size as a fraction of the word's: a lone mark carries far less
    /// ink than a word.
    static let fontSizeRatio: CGFloat = 0.6
    /// Keeps the marks legible above the smallest word sizes, at the
    /// standard size.
    static let preferredMinimumFontSize: CGFloat = 14
    /// Below this the marks hide rather than shrinking further.
    static let minimumFontSize: CGFloat = 12
    /// Slot height as a multiple of the marks' font size: room for every
    /// reader font's line box and for marks that overhang it.
    static let slotHeightRatio: CGFloat = 1.5
    /// Space between the end of the word's guide line and the slot, as a
    /// fraction of the word's font size.
    static let gapRatio: CGFloat = 0.1
    /// Space kept between the slot and the top bar.
    static let barMargin: CGFloat = 8
    /// The size setting's range, as a multiple of the standard size.
    static let sizeRange: ClosedRange<Double> = 0.5...2

    /// The marks' font size wherever there is room for it, at `scale` times
    /// the standard size (the size setting). Never below `minimumFontSize`,
    /// so the smallest setting shrinks the marks without hiding them.
    static func preferredFontSize(wordFontSize: CGFloat, scale: CGFloat = 1) -> CGFloat {
        max(minimumFontSize, max(preferredMinimumFontSize, wordFontSize * fontSizeRatio) * scale)
    }

    /// Distance from the word's center to the bottom of the slot, just past
    /// the end of the word's guide line.
    static func innerEdge(wordFontSize: CGFloat) -> CGFloat {
        wordFontSize * (WordView.guideLineHeightRatio / 2 + gapRatio)
    }

    /// Sizes the marks' slot for a word set at `wordFontSize`, given how far
    /// the room around the word's center reaches before a bar.
    ///
    /// The slot sits right above the word. It depends on settings and layout
    /// only, never on the words, so the marks hold still from word to word.
    /// Where the preferred size doesn't fit, the marks shrink; below
    /// `minimumFontSize` there are none (nil). The slot's bottom depends on
    /// the word's size alone and its top on the room, so `scale` changes how
    /// big the marks are but never moves them onto the word or a bar, and
    /// never decides whether they show.
    static func metrics(wordFontSize: CGFloat, clearHalfHeight: CGFloat, scale: CGFloat = 1) -> Metrics? {
        let inner = innerEdge(wordFontSize: wordFontSize)
        let fitting = (clearHalfHeight - barMargin - inner) / slotHeightRatio
        let fontSize = min(preferredFontSize(wordFontSize: wordFontSize, scale: scale), fitting)
        guard fontSize >= minimumFontSize else { return nil }
        return Metrics(fontSize: fontSize, offset: inner + fontSize * slotHeightRatio / 2)
    }

    /// The marks' opacity, as a fraction of the tone's text color, at an
    /// opacity setting of `level`, from 0 to 1.
    ///
    /// The setting's default is the tone's faded text, the marks' original
    /// look. Below it they fade linearly toward the tone's dim text, faint
    /// but still visible, and above it toward the full text color, the
    /// word's own. Each tone tunes its faded and dim opacities to the same
    /// contrast, so the default and everything below it look about as quiet
    /// in every tone.
    static func opacity(level: Double, tone: ReaderTextTone) -> Double {
        let middle = ReaderSettings.Defaults.enclosingMarksOpacity
        let level = min(max(level, 0), 1)
        // Weighted rather than offset, so the ends of each half are exact.
        if level <= middle {
            let t = level / middle
            return tone.dimTextOpacity * (1 - t) + tone.fadedTextOpacity * t
        }
        let t = (level - middle) / (1 - middle)
        return tone.fadedTextOpacity * (1 - t) + t
    }
}

/// The opening marks of the quotations and parentheses the current word is
/// inside, faded, above it on the anchor's column. Opt-in from Settings,
/// which also sets their size and opacity.
///
/// Above because nothing else there moves: ORP centering moves the word's
/// left and right edges every tick, so a mark beside it would either jump
/// with them or, at a fixed spot, be run into by long words. The word's line
/// never reaches the slot above it.
///
/// Takes the `fixationSurround` stage role: the height it is proposed is the
/// room the bars leave around the word, and the marks shrink or hide to fit
/// it.
struct EnclosingMarksView: View {
    let engine: RSVPEngine
    /// Nil until the document's marks are paired.
    let marks: EnclosingMarks?
    /// The reader's text size setting; a long word may display smaller.
    let fontSize: CGFloat
    let isEnabled: Bool

    @AppStorage(ReaderFont.storageKey) private var readerFontSelection = ReaderFont.defaultValue.rawValue
    @AppStorage(ReaderTextTone.storageKey) private var readerTextToneSelection = ReaderTextTone.defaultValue.rawValue
    @AppStorage(ReaderSettings.Keys.enclosingMarksSize) private var enclosingMarksSize: Double = ReaderSettings.Defaults.enclosingMarksSize
    @AppStorage(ReaderSettings.Keys.enclosingMarksOpacity) private var enclosingMarksOpacity: Double = ReaderSettings.Defaults.enclosingMarksOpacity

    var body: some View {
        GeometryReader { geo in
            if isEnabled, let marks,
               let metrics = EnclosingMarksLayout.metrics(
                   wordFontSize: fontSize,
                   clearHalfHeight: geo.size.height / 2,
                   scale: CGFloat(enclosingMarksSize)
               ) {
                let tone = ReaderTextTone.resolve(readerTextToneSelection)
                EnclosingMarksSlot(
                    engine: engine,
                    marks: marks,
                    metrics: metrics,
                    font: ReaderFont.resolve(readerFontSelection),
                    tone: tone,
                    opacity: EnclosingMarksLayout.opacity(level: enclosingMarksOpacity, tone: tone)
                )
                .frame(width: geo.size.width, height: geo.size.height)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
        .animation(.easeInOut(duration: 0.2), value: marks != nil)
        // The hold-to-read gesture layer lies underneath.
        .allowsHitTesting(false)
        // The current word is the reader's one VoiceOver element.
        .accessibilityHidden(true)
    }
}

/// Isolates the per-tick `engine.currentIndex` read: one array lookup; the
/// marks below re-render only when they change.
private struct EnclosingMarksSlot: View {
    let engine: RSVPEngine
    let marks: EnclosingMarks
    let metrics: EnclosingMarksLayout.Metrics
    let font: ReaderFont
    let tone: ReaderTextTone
    let opacity: Double

    /// A chapter announcement takes the word's place and runs taller than
    /// it, and a sentence break empties the screen; the marks leave and
    /// return with the word.
    private var isShowingWord: Bool {
        engine.chapterAnnouncement == nil && !engine.isInSentenceBreak
    }

    var body: some View {
        EnclosingMarksText(stack: marks.stack(at: engine.currentIndex), metrics: metrics, font: font, tone: tone, opacity: opacity)
            .equatable()
            .offset(y: -metrics.offset)
            .opacity(isShowingWord ? 1 : 0)
            // The engine can move in an animated transaction, such as a scrub
            // that pauses playback and so runs the stage's play/pause fade.
            // Nothing here may animate between words.
            .transaction { $0.animation = nil }
    }
}

/// The marks around one word. The outermost stays centered on the anchor's
/// column while inner ones open and close beside it, on the side the text
/// reads toward.
private struct EnclosingMarksText: View, Equatable {
    let stack: EnclosingMarks.Stack
    let metrics: EnclosingMarksLayout.Metrics
    let font: ReaderFont
    let tone: ReaderTextTone
    /// A fraction of the tone's text color; see
    /// `EnclosingMarksLayout.opacity(level:tone:)`.
    let opacity: Double

    var body: some View {
        let outermost = stack.marks.first.map(String.init) ?? ""
        let inner = String(stack.marks.dropFirst())
        let rightToLeft = stack.isRightToLeft

        mark(outermost)
            .overlay(alignment: rightToLeft ? .leading : .trailing) {
                mark(inner)
                    .alignmentGuide(rightToLeft ? .leading : .trailing) { d in
                        rightToLeft ? d[.trailing] : d[.leading]
                    }
            }
            .frame(maxWidth: .infinity)
            .frame(height: metrics.slotHeight)
            // Sides follow the text's direction, not the app's.
            .environment(\.layoutDirection, .leftToRight)
    }

    /// Marks set as the text sets them. The leading direction mark makes
    /// brackets and guillemets mirror in right-to-left text, as they do on
    /// the word, and keeps them unmirrored in left-to-right text whatever the
    /// app's language.
    private func mark(_ marks: String) -> some View {
        Text((stack.isRightToLeft ? "\u{200F}" : "\u{200E}") + marks)
            .font(font.regularFont(size: metrics.fontSize, relativeTo: nil))
            .foregroundStyle(tone.textColor.opacity(opacity))
            .lineLimit(1)
            .fixedSize()
    }
}

/// The marks as the reader draws them, at the reader's text size and the
/// marks' size and opacity settings, on the reader background, so changes
/// show as they're made. Always at the full size the setting asks for: in
/// the reader, a screen without room for that shrinks them.
struct EnclosingMarksPreview: View {
    @AppStorage(ReaderSettings.Keys.fontSize) private var fontSize: Int = ReaderSettings.Defaults.fontSize
    @AppStorage(ReaderSettings.Keys.enclosingMarksSize) private var enclosingMarksSize: Double = ReaderSettings.Defaults.enclosingMarksSize
    @AppStorage(ReaderSettings.Keys.enclosingMarksOpacity) private var enclosingMarksOpacity: Double = ReaderSettings.Defaults.enclosingMarksOpacity
    @AppStorage(ReaderFont.storageKey) private var readerFontSelection = ReaderFont.defaultValue.rawValue
    @AppStorage(ReaderTextTone.storageKey) private var readerTextToneSelection = ReaderTextTone.defaultValue.rawValue

    /// A quotation with a parenthesis open inside it.
    private static let stack = EnclosingMarks.Stack(marks: "\u{201C}(", isRightToLeft: false)

    var body: some View {
        let wordFontSize = CGFloat(fontSize)
        let tone = ReaderTextTone.resolve(readerTextToneSelection)
        let opacity = EnclosingMarksLayout.opacity(level: enclosingMarksOpacity, tone: tone)
        let metrics = EnclosingMarksLayout.Metrics(
            fontSize: EnclosingMarksLayout.preferredFontSize(wordFontSize: wordFontSize, scale: CGFloat(enclosingMarksSize)),
            offset: 0
        )
        // Room for the largest setting, so the row holds its height while
        // the size slider moves.
        let largest = EnclosingMarksLayout.preferredFontSize(
            wordFontSize: wordFontSize,
            scale: CGFloat(EnclosingMarksLayout.sizeRange.upperBound)
        )

        EnclosingMarksText(
            stack: Self.stack,
            metrics: metrics,
            font: ReaderFont.resolve(readerFontSelection),
            tone: tone,
            opacity: opacity
        )
        .frame(height: largest * EnclosingMarksLayout.slotHeightRatio)
        .background { ReaderBackdrop() }
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .padding(.vertical, 4)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview")
        .accessibilityValue(
            "Quote and parenthesis, \(Int(metrics.fontSize.rounded())) points, \(Int((opacity * 100).rounded())) percent opacity"
        )
    }
}
