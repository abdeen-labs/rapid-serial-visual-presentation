import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Word view

/// Displays a single word with Optimal Recognition Point (ORP) highlighting.
///
/// The ORP anchor letter (approximately at the 1/3 position of the word's letters)
/// is displayed in the chosen highlight color and centered on screen. The rest of the word is offset
/// so the reader's eye stays fixed at the center. Font size scales down
/// automatically for very long words.
///
/// Uses `AttributedString` to render the word as a single text run, which
/// preserves cursive shaping for Arabic and correct glyph order for all scripts.
struct WordView: View, Equatable {
    let word: String
    let fontSize: CGFloat
    /// The words before and after this one, shown faded beside it in reading
    /// order. Nil shows the word alone.
    var context: ContextWords.Neighbors? = nil
    /// Whether the document reads right to left, which puts the previous word
    /// on the right.
    var contextIsRightToLeft = false
    /// Whether the neighbours fade nearly into the background, as during
    /// playback, rather than staying readable.
    var contextIsDimmed = false
    @AppStorage(ReaderFont.storageKey) private var readerFontSelection = ReaderFont.defaultValue.rawValue
    @AppStorage(ReaderTextTone.storageKey) private var readerTextToneSelection = ReaderTextTone.defaultValue.rawValue
    @AppStorage(ReaderHighlightColor.storageKey) private var readerHighlightColorSelection = ReaderHighlightColor.defaultValue.rawValue

    static func == (lhs: WordView, rhs: WordView) -> Bool {
        lhs.word == rhs.word && lhs.fontSize == rhs.fontSize
            && lhs.context == rhs.context && lhs.contextIsRightToLeft == rhs.contextIsRightToLeft
            && lhs.contextIsDimmed == rhs.contextIsDimmed
            && lhs.readerFontSelection == rhs.readerFontSelection
            && lhs.readerTextToneSelection == rhs.readerTextToneSelection
            && lhs.readerHighlightColorSelection == rhs.readerHighlightColorSelection
    }

    private var readerFont: ReaderFont {
        ReaderFont.resolve(readerFontSelection)
    }

    private var textTone: ReaderTextTone {
        ReaderTextTone.resolve(readerTextToneSelection)
    }

    private var highlightColor: ReaderHighlightColor {
        ReaderHighlightColor.resolve(readerHighlightColorSelection)
    }

    /// Everything derived from `word` that the body needs, computed once per
    /// evaluation — as separate computed properties, `redIndex` alone was
    /// recomputed four times per word tick (by `before`/`after`/`anchor`/
    /// `attributedWord`) on the playback hot path.
    private struct WordParts {
        let redIndex: Int
        let isArabic: Bool
        let before: String
        let anchor: String
        let after: String
    }

    private func makeParts() -> WordParts {
        let redIndex = Self.redIndex(of: word)
        let before = String(word.prefix(redIndex))
        let anchor: String
        let after: String
        if redIndex < word.count {
            anchor = String(word[word.index(word.startIndex, offsetBy: redIndex)])
            after = redIndex + 1 < word.count
                ? String(word.suffix(word.count - redIndex - 1))
                : ""
        } else {
            anchor = ""
            after = ""
        }
        return WordParts(
            redIndex: redIndex,
            isArabic: Self.isArabic(word),
            before: before,
            anchor: anchor,
            after: after
        )
    }

    /// The character index of the ORP anchor letter (the highlighted letter).
    /// Calculated from the positions of letters and digits, skipping
    /// punctuation and the space inside a number unit (`2000 BCE`), so a
    /// number or unit is anchored like a word of the same length.
    /// For short CJK words (≤3 characters), centers the anchor instead.
    nonisolated static func redIndex(of word: String) -> Int {
        // Collect indices of letters and digits only (skip punctuation like apostrophes)
        let letterIndices = word.enumerated().compactMap { offset, char in
            char.isLetter || isDigit(char) ? offset : nil
        }

        guard !letterIndices.isEmpty else {
            // Pure punctuation fallback
            return word.count / 2
        }

        let letterCount = letterIndices.count

        // Short CJK words look better with the anchor centered rather than
        // at the 1/3 position used for longer Latin words.
        if letterCount <= 3, word.unicodeScalars.contains(where: { CJKUtilities.isHanIdeograph($0) }) {
            return letterIndices[letterCount / 2]
        }

        return letterIndices[Self.orpLetterPosition(letterCount: letterCount)]
    }

    /// Returns `true` for a decimal digit in any script. Superscripts and
    /// subscripts (the `²` of `m²`, the `₂` of `H₂O`) are not digits here.
    nonisolated private static func isDigit(_ character: Character) -> Bool {
        character.unicodeScalars.first?.properties.generalCategory == .decimalNumber
    }

    /// Letter position (index into the word's letters) of the ORP anchor.
    ///
    /// The classic RSVP mapping: the eye's optimal fixation point sits left of
    /// center, around the 1/3 mark — 2nd letter for short words, drifting one
    /// letter rightward as words get longer (1 → 1st, 2–5 → 2nd, 6–9 → 3rd,
    /// 10–13 → 4th, 14+ → 5th).
    nonisolated static func orpLetterPosition(letterCount: Int) -> Int {
        switch letterCount {
        case ..<2: return 0
        case 2...5: return 1
        case 6...9: return 2
        case 10...13: return 3
        default: return 4
        }
    }

    /// Whether the word contains Arabic script. Arabic is cursive — changing
    /// the font weight on individual characters breaks glyph connections,
    /// so only color is changed for the anchor letter.
    nonisolated private static func isArabic(_ word: String) -> Bool {
        word.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (v >= 0x0600 && v <= 0x06FF)
                || (v >= 0x0750 && v <= 0x077F)
                || (v >= 0x08A0 && v <= 0x08FF)
                || (v >= 0xFB50 && v <= 0xFDFF)
                || (v >= 0xFE70 && v <= 0xFEFF)
        }
    }

    /// Builds an `AttributedString` with the anchor letter in `anchorColor`.
    /// For non-Arabic scripts the anchor is also bolded. For Arabic, only
    /// color is changed to avoid breaking cursive glyph connections.
    private func attributedWord(fontSize: CGFloat, parts: WordParts, anchorColor: Color) -> AttributedString {
        var attributed = AttributedString(word)
        // The reader's font size is user-controlled via a slider, so we opt out
        // of Dynamic Type scaling here — otherwise accessibility sizes would
        // compound with the chosen size and overflow the fitted layout.
        attributed.font = readerFont.regularFont(size: fontSize, relativeTo: nil)
        attributed.foregroundColor = textTone.textColor

        guard parts.redIndex < word.count else { return attributed }

        let start = word.index(word.startIndex, offsetBy: parts.redIndex)
        let end = word.index(after: start)
        if let attrStart = AttributedString.Index(start, within: attributed),
           let attrEnd = AttributedString.Index(end, within: attributed) {
            attributed[attrStart..<attrEnd].foregroundColor = anchorColor
            // Bold breaks Arabic cursive shaping — only apply for non-Arabic.
            if !parts.isArabic {
                attributed[attrStart..<attrEnd].font = readerFont.boldFont(size: fontSize, relativeTo: nil)
            }
        }

        return attributed
    }

    /// Horizontal breathing room kept between the word and the view edges.
    /// Must match the `Text`'s horizontal padding below.
    private static let horizontalTextMargin: CGFloat = 6

    /// Space between the word and each neighbour, as a fraction of the
    /// word's size, so the gap looks the same in every font.
    private static let contextGapRatio: CGFloat = 0.75

    /// Hard floor for the fitted font size. Below this, the clamped offset
    /// falls back to plain centering and `minimumScaleFactor` takes over.
    private static let minimumDisplayFontSize: CGFloat = 12

    /// The guide line's height as a multiple of the font size. The open quote
    /// and parenthesis marks are laid out past its top end.
    nonisolated static let guideLineHeightRatio: CGFloat = 1.6

    var body: some View {
        let parts = makeParts()
        let anchorColor = textTone.anchorColor(for: highlightColor)
        GeometryReader { geo in
            let metrics = layoutMetrics(for: geo.size.width, parts: parts)

            ZStack {
                ZStack {
                    // Subtle vertical guide line at the anchor position
                    Rectangle()
                        .fill(anchorColor.opacity(0.12))
                        .frame(width: 1.5, height: metrics.fontSize * Self.guideLineHeightRatio)

                    let gap = metrics.fontSize * Self.contextGapRatio

                    Text(attributedWord(fontSize: metrics.fontSize, parts: parts, anchorColor: anchorColor))
                        // Overlays, so the neighbours never change the word's
                        // own layout. The guides must sit on unconditional
                        // views: an alignment guide inside an `if` is dropped.
                        .overlay(alignment: .leadingFirstTextBaseline) {
                            contextWord(contextIsRightToLeft ? context?.next : context?.previous,
                                        fontSize: metrics.fontSize)
                                .alignmentGuide(.leading) { $0.width + gap }
                        }
                        .overlay(alignment: .trailingFirstTextBaseline) {
                            contextWord(contextIsRightToLeft ? context?.previous : context?.next,
                                        fontSize: metrics.fontSize)
                                .alignmentGuide(.trailing) { _ in -gap }
                        }
                        .offset(x: metrics.anchorOffset)
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                        .padding(.horizontal, Self.horizontalTextMargin)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: max(120, fontSize * 2.3))
        .accessibilityElement()
        .accessibilityLabel(word)
    }

    /// A neighbouring word at the word's size, in the reader's regular face
    /// and the tone's faded color, or its dim one while `contextIsDimmed`;
    /// empty when there is none. Never proposed a width, so a long neighbour
    /// runs past the screen edge rather than shrinking.
    private func contextWord(_ text: String?, fontSize: CGFloat) -> some View {
        Text(text ?? "")
            .font(readerFont.regularFont(size: fontSize, relativeTo: nil))
            .foregroundStyle(textTone.textColor)
            .opacity(contextIsDimmed ? textTone.dimTextOpacity : textTone.fadedTextOpacity)
            .fixedSize()
    }

    private struct LayoutMetrics {
        let fontSize: CGFloat
        let anchorOffset: CGFloat
    }

    /// Computes the fitted font size and the ORP centering offset together.
    ///
    /// The anchor letter sits at screen center, so each half of the word must
    /// fit within half the available width — fitting the *total* width isn't
    /// enough, because the centering offset shifts the wider (usually
    /// trailing) half toward the edge. The offset is then clamped so the
    /// shifted word can never extend past the view bounds.
    private func layoutMetrics(for availableWidth: CGFloat, parts: WordParts) -> LayoutMetrics {
        let textAreaWidth = availableWidth - 2 * Self.horizontalTextMargin
        guard textAreaWidth > 0, !word.isEmpty else {
            return LayoutMetrics(fontSize: fontSize, anchorOffset: 0)
        }

        // Measure once at the base size; glyph widths scale linearly with
        // font size. The anchor is measured bold to match its rendering.
        let beforeWidth = textWidth(parts.before, fontSize: fontSize)
        let afterWidth = textWidth(parts.after, fontSize: fontSize)
        let anchorWidth = textWidth(parts.anchor, fontSize: fontSize, bold: !parts.isArabic)

        let neededHalfWidth = max(beforeWidth, afterWidth) + anchorWidth / 2
        let availableHalfWidth = textAreaWidth / 2

        var scale: CGFloat = 1
        if neededHalfWidth > availableHalfWidth {
            scale = availableHalfWidth / neededHalfWidth
        }
        let displayFontSize = max(Self.minimumDisplayFontSize, fontSize * scale)
        let appliedScale = displayFontSize / fontSize

        let idealOffset = (afterWidth - beforeWidth) / 2 * appliedScale
        let wordWidth = (beforeWidth + anchorWidth + afterWidth) * appliedScale
        let anchorOffset = Self.clampedAnchorOffset(
            idealOffset: parts.isArabic ? -idealOffset : idealOffset,
            wordWidth: wordWidth,
            availableWidth: textAreaWidth
        )

        return LayoutMetrics(fontSize: displayFontSize, anchorOffset: anchorOffset)
    }

    /// Clamps the ORP centering offset so the shifted word stays inside the
    /// available width. When the word is at least as wide as the space (the
    /// minimum font size was reached), falls back to plain centering.
    nonisolated static func clampedAnchorOffset(
        idealOffset: CGFloat,
        wordWidth: CGFloat,
        availableWidth: CGFloat
    ) -> CGFloat {
        let slack = (availableWidth - wordWidth) / 2
        guard slack > 0 else { return 0 }
        return min(max(idealOffset, -slack), slack)
    }

    /// Measures the rendered width of a text string using the current reader font.
    private func textWidth(_ text: String, fontSize: CGFloat, bold: Bool = false) -> CGFloat {
        guard !text.isEmpty else { return 0 }

        let font = readerFont.platformFont(size: fontSize, bold: bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((text as NSString).size(withAttributes: attributes).width)
    }
}
