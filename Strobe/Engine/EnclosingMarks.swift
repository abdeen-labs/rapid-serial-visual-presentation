import Foundation

/// The quotations and parenthetical asides around each word of a document,
/// so the reader can keep their opening marks in view while the words
/// between the marks play.
///
/// Built once per document in a single pass; ``stack(at:)`` is an array
/// lookup, cheap enough for every word tick and right at any index a seek
/// lands on.
///
/// A span runs from the word carrying its opening mark through the word
/// carrying its closing mark, and both count as inside. Only spans that close
/// are kept, so a stray or misread opening mark never shows.
///
/// - Parentheses, square brackets, and the CJK brackets open and close by
///   character, and `„` and `‚` only ever open. A closing mark closes the
///   innermost open span of its kind; spans still open inside that one never
///   closed and are dropped.
/// - Other quotation marks and guillemets open before a word's letters and
///   close after them, so `“` opens English quotations and closes German ones
///   (`„…“`), and `»` opens German quotations (`»…«`) and closes French
///   ones. A `«` or `‹` after the letters opens a quotation when none of its
///   kind is open: French sets a space inside guillemets, and the tokenizer
///   glues a spaced mark onto the word before it.
/// - `’` and `'` are apostrophes far more often than quotes (`don’t`, `dogs’`,
///   `’90s`, `rock ’n’ roll`). `’` only closes a single quotation that is
///   open, `'` is ignored, and a `‘` before a digit or a common elision
///   (`‘em`, `‘til`) is a misprinted apostrophe.
/// - A quotation that opens again while it is the innermost span continues
///   across a paragraph break when the text before the new mark ends a
///   sentence: each paragraph of a long quotation opens it, and only the last
///   one closes it. Otherwise the earlier mark never closed and is dropped.
/// - Nothing stays open across the start of a chapter.
/// - A span needs at least three words; in one or two, every word shows a
///   mark of its own.
/// - A span closed right after its sentence's or clause's punctuation (`.”`,
///   `,’`, `?)`) or continued across a paragraph break may run
///   ``maximumSpanLength`` words, and any other only
///   ``maximumUnpunctuatedSpanLength``: past those, a pairing is more likely
///   two stray marks, as in a garbled table or caption, than a real aside.
///
/// Each word keeps its ``maximumShownDepth`` outermost spans.
nonisolated struct EnclosingMarks: Sendable {

    /// The opening marks around one word, outermost first.
    struct Stack: Hashable, Sendable {
        /// Opening marks as they appear in the text, outermost first.
        let marks: String
        /// Whether the outermost span is right-to-left text, which mirrors
        /// brackets and guillemets and lines the marks up leftward.
        let isRightToLeft: Bool

        static let empty = Stack(marks: "", isRightToLeft: false)

        var isEmpty: Bool { marks.isEmpty }
    }

    /// Nesting levels shown for one word, counted from the outermost.
    static let maximumShownDepth = 3
    /// Words a span must cover, its opening and closing words included.
    static let minimumSpanLength = 3
    /// The longest span closed after punctuation or continued across a
    /// paragraph break.
    static let maximumSpanLength = 250
    /// The longest span closed any other way.
    static let maximumUnpunctuatedSpanLength = 60
    /// Open spans beyond this depth drop the oldest, keeping a run of stray
    /// opening marks from making each closing mark's search long.
    private static let maximumOpenDepth = 32

    /// Indices into `stacks`. Twenty opening marks, three levels deep, in
    /// two directions make at most 16,840 distinct stacks.
    private let stackIndexByWord: [UInt16]
    private let stacks: [Stack]

    /// The opening marks around the word at `index`; empty outside the
    /// document.
    func stack(at index: Int) -> Stack {
        guard stackIndexByWord.indices.contains(index) else { return .empty }
        return stacks[Int(stackIndexByWord[index])]
    }

    init(words: [String], chapters: [Chapter]) {
        let chapterStarts = ChapterTimeline(chapters).chapters.map(\.wordIndex)
        var spans = Self.closedSpans(in: words, chapterStarts: chapterStarts)
        spans.sort { ($0.start, -$0.end, $0.order) < ($1.start, -$1.end, $1.order) }

        // Kept spans nest, except that one can close on the word where the
        // next opens (`c)(d`), so the spans covering a word stay in opening
        // order, outermost first.
        var stackIndexByWord = [UInt16](repeating: 0, count: words.count)
        var stacks: [Stack] = [.empty]
        var stackIndices: [Stack: UInt16] = [.empty: 0]
        var active: [Span] = []
        var next = 0
        var current: UInt16 = 0
        for index in words.indices {
            let covering = active.count
            active.removeAll { $0.end < index }
            var changed = active.count != covering
            while next < spans.count, spans[next].start == index {
                active.append(spans[next])
                next += 1
                changed = true
            }
            if changed {
                let shown = active.prefix(Self.maximumShownDepth)
                let stack = Stack(
                    marks: String(String.UnicodeScalarView(shown.map(\.mark))),
                    isRightToLeft: shown.first?.isRightToLeft ?? false
                )
                if let existing = stackIndices[stack] {
                    current = existing
                } else {
                    current = UInt16(stacks.count)
                    stackIndices[stack] = current
                    stacks.append(stack)
                }
            }
            stackIndexByWord[index] = current
        }
        self.stackIndexByWord = stackIndexByWord
        self.stacks = stacks
    }

    // MARK: - Pairing

    private enum Kind: Equatable {
        case parenthesis, squareBracket
        case cornerBracket, whiteCornerBracket, doubleAngleBracket, angleBracket, lenticularBracket, tortoiseShellBracket
        case doubleQuote, singleQuote, guillemet, singleGuillemet

        /// Quotations reopen at each paragraph of a long quotation, where
        /// brackets nest in themselves.
        var isQuotation: Bool {
            switch self {
            case .doubleQuote, .singleQuote, .guillemet, .singleGuillemet, .cornerBracket, .whiteCornerBracket:
                return true
            case .parenthesis, .squareBracket, .doubleAngleBracket, .angleBracket, .lenticularBracket, .tortoiseShellBracket:
                return false
            }
        }
    }

    private enum Role {
        case open
        case close
        /// Closes an open span of its kind, or opens one when none is open.
        case closeOrOpen
    }

    /// Where a mark sits relative to its word's letters and digits.
    private enum Placement {
        case before, between, after
    }

    private struct OpenSpan {
        let kind: Kind
        let mark: Unicode.Scalar
        let start: Int
        let order: Int
    }

    private struct Span {
        let start: Int
        let end: Int
        let mark: Unicode.Scalar
        let isRightToLeft: Bool
        /// Opening order, which puts the outer of two spans covering the
        /// same words first.
        let order: Int
    }

    /// Pairs the marks in `words` and returns the spans to show, unsorted.
    private static func closedSpans(in words: [String], chapterStarts: [Int]) -> [Span] {
        var spans: [Span] = []
        var open: [OpenSpan] = []
        var opened = 0
        var nextChapter = 0

        func keep(_ span: OpenSpan, through end: Int, punctuated: Bool) {
            let length = end - span.start + 1
            let limit = punctuated ? maximumSpanLength : maximumUnpunctuatedSpanLength
            guard length >= minimumSpanLength, length <= limit else { return }
            spans.append(Span(
                start: span.start,
                end: end,
                mark: span.mark,
                isRightToLeft: isRightToLeft(words[span.start...end]),
                order: span.order
            ))
        }

        for (index, word) in words.enumerated() {
            while nextChapter < chapterStarts.count, chapterStarts[nextChapter] <= index {
                nextChapter += 1
                open.removeAll()
            }
            guard mayHoldMarks(word) else { continue }

            let scalars = Array(word.unicodeScalars)
            let firstLetter = scalars.firstIndex(where: isWordScalar)
            let lastLetter = scalars.lastIndex(where: isWordScalar)

            for (offset, scalar) in scalars.enumerated() {
                let placement: Placement
                if let firstLetter, let lastLetter {
                    placement = offset < firstLetter ? .before : offset > lastLetter ? .after : .between
                } else {
                    placement = .before
                }
                guard let (kind, role) = classify(scalar, placement, followedBy: scalars[(offset + 1)...]) else {
                    continue
                }

                let opens: Bool
                switch role {
                case .open: opens = true
                case .close: opens = false
                case .closeOrOpen: opens = !open.contains { $0.kind == kind }
                }

                if opens {
                    if kind.isQuotation, let innermost = open.last, innermost.kind == kind, innermost.start < index {
                        open.removeLast()
                        let textBefore = placement == .before
                            ? (index > 0 ? words[index - 1] : "")
                            : String(String.UnicodeScalarView(scalars[..<offset]))
                        if !PunctuationMarks.marks(in: textBefore).isDisjoint(with: [.sentenceEnd, .ellipsis]) {
                            keep(innermost, through: index - 1, punctuated: true)
                        }
                    }
                    if open.count == maximumOpenDepth { open.removeFirst() }
                    open.append(OpenSpan(kind: kind, mark: scalar, start: index, order: opened))
                    opened += 1
                } else if let match = open.lastIndex(where: { $0.kind == kind }) {
                    let span = open[match]
                    open.removeSubrange(match...)
                    guard span.start < index else { continue }
                    let textBefore = String(String.UnicodeScalarView(scalars[..<offset]))
                    let punctuated = !PunctuationMarks.marks(in: textBefore)
                        .isDisjoint(with: [.sentenceEnd, .clause, .ellipsis, .dash])
                    keep(span, through: index, punctuated: punctuated)
                }
            }
        }
        return spans
    }

    /// The kind and role of `scalar` as a quotation or bracket mark, or nil
    /// when it is neither (an apostrophe, a mark inside a word, any other
    /// character).
    private static func classify(
        _ scalar: Unicode.Scalar,
        _ placement: Placement,
        followedBy rest: ArraySlice<Unicode.Scalar>
    ) -> (Kind, Role)? {
        switch scalar {
        case "(", "\u{FF08}":                     // ( （
            return (.parenthesis, .open)
        case ")", "\u{FF09}":                     // ) ）
            return (.parenthesis, .close)
        case "[", "\u{FF3B}":                     // [ ［
            return (.squareBracket, .open)
        case "]", "\u{FF3D}":                     // ] ］
            return (.squareBracket, .close)
        case "\u{300C}": return (.cornerBracket, .open)          // 「
        case "\u{300D}": return (.cornerBracket, .close)         // 」
        case "\u{300E}": return (.whiteCornerBracket, .open)     // 『
        case "\u{300F}": return (.whiteCornerBracket, .close)    // 』
        case "\u{300A}": return (.doubleAngleBracket, .open)     // 《
        case "\u{300B}": return (.doubleAngleBracket, .close)    // 》
        case "\u{3008}": return (.angleBracket, .open)           // 〈
        case "\u{3009}": return (.angleBracket, .close)          // 〉
        case "\u{3010}": return (.lenticularBracket, .open)      // 【
        case "\u{3011}": return (.lenticularBracket, .close)     // 】
        case "\u{3014}": return (.tortoiseShellBracket, .open)   // 〔
        case "\u{3015}": return (.tortoiseShellBracket, .close)  // 〕
        case "\u{201E}":                          // „
            return (.doubleQuote, .open)
        case "\u{201C}", "\u{201D}", "\"":        // “ ” "
            return quote(.doubleQuote, placement)
        case "\u{201A}":                          // ‚
            return placement == .before ? (.singleQuote, .open) : nil
        case "\u{2018}":                          // ‘
            if placement == .before && isElision(rest) { return nil }
            return quote(.singleQuote, placement)
        case "\u{2019}":                          // ’
            return placement == .after ? (.singleQuote, .close) : nil
        case "\u{00AB}", "\u{2039}":              // « ‹
            let kind: Kind = scalar == "\u{00AB}" ? .guillemet : .singleGuillemet
            switch placement {
            case .before: return (kind, .open)
            case .after: return (kind, .closeOrOpen)
            case .between: return nil
            }
        case "\u{00BB}", "\u{203A}":              // » ›
            return quote(scalar == "\u{00BB}" ? .guillemet : .singleGuillemet, placement)
        default:
            return nil
        }
    }

    /// A quote that opens before a word's letters and closes after them.
    private static func quote(_ kind: Kind, _ placement: Placement) -> (Kind, Role)? {
        switch placement {
        case .before: return (kind, .open)
        case .after: return (kind, .close)
        case .between: return nil
        }
    }

    /// Words a `‘` set in place of an apostrophe most often starts.
    private static let elisions: Set<String> = ["em", "n", "til", "tis", "twas", "cause"]

    /// Whether the text after a leading `‘` makes it an apostrophe: a digit
    /// (`‘90s`) or a common elision (`‘em`, `‘n’`).
    private static func isElision(_ rest: ArraySlice<Unicode.Scalar>) -> Bool {
        guard let next = rest.first else { return false }
        if next.properties.numericType != nil { return true }
        let letters = rest.prefix { $0.properties.isAlphabetic }
        return elisions.contains(String(String.UnicodeScalarView(letters)).lowercased())
    }

    /// A fast check for words with no quotation or bracket mark, which is
    /// nearly all of them. Every mark is one of the listed ASCII bytes or
    /// starts with one of the listed UTF-8 lead bytes.
    private static func mayHoldMarks(_ word: String) -> Bool {
        word.utf8.contains { byte in
            switch byte {
            case 0x22, 0x28, 0x29, 0x5B, 0x5D,    // " ( ) [ ]
                 0xC2,                            // « »
                 0xE2,                            // quotes and ‹ › (U+2018–U+203A)
                 0xE3,                            // CJK brackets (U+3008–U+3015)
                 0xEF:                            // fullwidth （ ） ［ ］
                return true
            default:
                return false
            }
        }
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    /// Whether the first letter of `words` belongs to a right-to-left script.
    private static func isRightToLeft(_ words: ArraySlice<String>) -> Bool {
        for word in words {
            for scalar in word.unicodeScalars where scalar.properties.isAlphabetic {
                switch scalar.value {
                case 0x0600...0x08FF,                     // Arabic, Syriac, Thaana, N'Ko, ...
                     0xFB50...0xFDFF, 0xFE70...0xFEFF,    // Arabic presentation forms
                     0x10800...0x10FFF, 0x1E800...0x1EFFF:
                    return true
                default:
                    return false
                }
            }
        }
        return false
    }
}
