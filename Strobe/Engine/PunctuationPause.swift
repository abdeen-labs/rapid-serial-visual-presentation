import Foundation

/// The types of pause-worthy punctuation found on a word.
///
/// A word can carry several at once — `word),` holds a bracket and a clause
/// mark — so classification yields a set, and
/// ``PunctuationPauses/multiplier(for:sentenceEnd:)`` resolves it to one pause.
nonisolated struct PunctuationMarks: OptionSet, Hashable, Sendable {
    let rawValue: UInt8

    /// `. ! ?` and their CJK/Arabic equivalents.
    static let sentenceEnd = PunctuationMarks(rawValue: 1 << 0)
    /// `, ; :` and their CJK/Arabic equivalents.
    static let clause = PunctuationMarks(rawValue: 1 << 1)
    /// Em and en dashes, `--`, and a trailing hyphen.
    static let dash = PunctuationMarks(rawValue: 1 << 2)
    /// `…` and runs of three or more periods.
    static let ellipsis = PunctuationMarks(rawValue: 1 << 3)
    /// Closing brackets and quotation marks.
    static let bracket = PunctuationMarks(rawValue: 1 << 4)

    /// Classifies the punctuation on `word`.
    ///
    /// Only the trailing run of marks counts, so the marks inside `3.14`,
    /// `1,000`, and `10:30` never pause, and neither does a leading mark
    /// (`(word`, `—stone`), whose pause belongs to the previous word.
    ///
    /// - A sentence ender counts only while everything to its right is a
    ///   closing quote, bracket, or ellipsis: `home."` ends a sentence, but
    ///   the period in `etc.,` or `U.S.—` belongs to an abbreviation.
    /// - Three or more periods are an ellipsis, not a sentence end.
    /// - Apostrophe-like quotes (`'`, `’`) are looked past but never pause on
    ///   their own — `dogs’` is far more often a possessive than the end of a
    ///   quotation.
    /// - A trailing hyphen is a dash: the tokenizer glues a spaced ` - ` onto
    ///   the preceding word.
    /// - An em dash, `--`, or ellipsis fused between two words
    ///   (`elements—stone`, `wait...what`) counts as if it were trailing. An
    ///   internal en dash or hyphen (`1990–1995`, `well-known`) does not.
    static func marks(in word: String) -> PunctuationMarks {
        let scalars = word.unicodeScalars
        var marks: PunctuationMarks = []
        var canEndSentence = true
        var end = scalars.endIndex

        trailing: while end > scalars.startIndex {
            let index = scalars.index(before: end)
            end = index
            switch kind(of: scalars[index]) {
            case .period:
                var length = 1
                while end > scalars.startIndex {
                    let previous = scalars.index(before: end)
                    guard kind(of: scalars[previous]) == .period else { break }
                    end = previous
                    length += 1
                }
                if length >= 3 {
                    marks.insert(.ellipsis)
                } else if canEndSentence {
                    marks.insert(.sentenceEnd)
                    canEndSentence = false
                }
            case .sentenceEnder:
                if canEndSentence { marks.insert(.sentenceEnd) }
                canEndSentence = false
            case .clause:
                marks.insert(.clause)
                canEndSentence = false
            case .emDash, .enDash, .hyphen:
                marks.insert(.dash)
                canEndSentence = false
            case .ellipsis:
                marks.insert(.ellipsis)
            case .bracket:
                marks.insert(.bracket)
            case .transparent:
                break
            case .other:
                end = scalars.index(after: index)
                break trailing
            }
        }

        var hasWordCharacter = false
        var hyphenRun = 0
        var periodRun = 0
        for scalar in scalars[..<end] {
            let kind = kind(of: scalar)
            hyphenRun = kind == .hyphen ? hyphenRun + 1 : 0
            periodRun = kind == .period ? periodRun + 1 : 0
            if kind == .other {
                hasWordCharacter = hasWordCharacter
                    || scalar.properties.isAlphabetic
                    || scalar.properties.numericType != nil
            } else if hasWordCharacter {
                if kind == .emDash || hyphenRun == 2 { marks.insert(.dash) }
                if kind == .ellipsis || periodRun == 3 { marks.insert(.ellipsis) }
            }
        }

        return marks
    }

    private enum ScalarKind {
        case period, sentenceEnder, clause, emDash, enDash, hyphen, ellipsis, bracket, transparent, other
    }

    private static func kind(of scalar: Unicode.Scalar) -> ScalarKind {
        switch scalar {
        case ".":
            return .period
        case "!", "?",
             "\u{3002}",                          // 。 CJK full stop
             "\u{FF01}", "\u{FF1F}",              // ！ ？ fullwidth
             "\u{061F}",                          // ؟ Arabic question mark
             "\u{06D4}":                          // ۔ Arabic/Urdu full stop
            return .sentenceEnder
        case ",", ";", ":",
             "\u{3001}",                          // 、 CJK enumeration comma
             "\u{FF0C}", "\u{FF1B}", "\u{FF1A}",  // ， ； ： fullwidth
             "\u{060C}", "\u{061B}":              // ، ؛ Arabic comma, semicolon
            return .clause
        case "\u{2014}", "\u{2015}",              // — ―
             "\u{2E3A}", "\u{2E3B}":              // ⸺ ⸻
            return .emDash
        case "\u{2013}":                          // –
            return .enDash
        case "-":
            return .hyphen
        case "\u{2026}":                          // …
            return .ellipsis
        // Any quotation mark at the end of a word closes a quotation there,
        // including “ and «, which close German-style quotations.
        case ")", "]", "}", "\"",
             "\u{201D}", "\u{201C}",              // ” “
             "\u{00BB}", "\u{00AB}",              // » «
             "\u{203A}", "\u{2039}",              // › ‹
             "\u{300D}", "\u{300F}",              // 」 』
             "\u{FF09}", "\u{3011}",              // ） 】
             "\u{300B}", "\u{3009}":              // 》 〉
            return .bracket
        case "'", "\u{2019}", "\u{2018}",         // ' ’ ‘
             "\u{200B}"..."\u{200F}",             // zero-width space/joiners, LRM, RLM
             "\u{2060}", "\u{FEFF}":              // word joiner, zero-width no-break space
            return .transparent
        default:
            return .other
        }
    }
}

/// Pause multipliers for every punctuation type except a sentence end, which
/// keeps its own setting (`sentencePauseMultiplier`). 1.0 means no pause.
nonisolated struct PunctuationPauses: Hashable, Codable, Sendable {
    var clause: Double = 1.3
    var dash: Double = 1.4
    var ellipsis: Double = 1.5
    var bracket: Double = 1.2

    /// The interval multiplier for a word carrying `marks`: the largest
    /// multiplier among its types, never below 1.0. Pauses don't stack, so
    /// `word),` pauses once, for whichever of its two marks pauses longer.
    func multiplier(for marks: PunctuationMarks, sentenceEnd: Double) -> Double {
        var multiplier = 1.0
        if marks.contains(.sentenceEnd) { multiplier = max(multiplier, sentenceEnd) }
        if marks.contains(.clause) { multiplier = max(multiplier, clause) }
        if marks.contains(.dash) { multiplier = max(multiplier, dash) }
        if marks.contains(.ellipsis) { multiplier = max(multiplier, ellipsis) }
        if marks.contains(.bracket) { multiplier = max(multiplier, bracket) }
        return multiplier
    }
}
