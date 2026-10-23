import Foundation

/// The text a voice reads for a run of words, with the part of it that
/// reads each word.
///
/// A voice reports its progress as UTF-16 ranges of the text it was given,
/// so the script records each word's range while writing the text from the
/// stored words, and never looks for the words in the text afterwards. Words
/// are written as stored, apart from a few changes for speech:
///
/// - A dash between words (an em dash, horizontal bar, `--`, or a doubled or
///   spaced en dash) reads as a comma: `elements—`, `stone` becomes
///   `elements, stone`, so the voice pauses there; a dash can run the words
///   together, or be read out as a symbol. A single
///   hyphen stays (`well-known`, `pre-`, `-5`), and so does a single en dash
///   inside a word (`1990–2000`). The tokenizer leaves a spaced en dash on
///   the word before it, so one at the end of a word reads as a comma.
/// - Decorative marks are left out. A word of nothing else (`***`, `•`, `|`,
///   `#`) isn't read and gets an empty range; at the edges of a word they are
///   dropped from it (`end.***`, `*note*`, `item•`).
/// - A number unit keeps its space (`2000 BCE`, `10:30 PM`), so its range
///   covers both halves.
/// - CJK words are joined without spaces, as their text was written.
nonisolated struct SpeechScript: Equatable, Sendable {

    /// What the voice is given.
    let text: String

    /// The document indices of the words read; empty for a chapter title.
    let wordIndices: Range<Int>

    /// The words read, as stored: `words[i]` is the document's word at
    /// `wordIndices.lowerBound + i`.
    let words: [String]

    /// The UTF-16 range of ``text`` that reads each of ``words``. A word that
    /// isn't read has an empty range where the text stood when it came up.
    let wordRanges: [Range<Int>]

    /// The script for the words of `words` in `range`, which is clamped to
    /// the document.
    init(words: [String], range: Range<Int>) {
        let range = range.clamped(to: words.indices)
        var writer = ScriptWriter(joinsCJKWords: true)
        for word in words[range] {
            writer.append(word)
        }
        text = writer.text
        wordIndices = range
        self.words = Array(words[range])
        wordRanges = writer.ranges
    }

    /// The script for a chapter title read on its own. It has no words; the
    /// title's own spaces are all kept, CJK or not.
    init(title: String) {
        var writer = ScriptWriter(joinsCJKWords: false)
        for piece in title.split(whereSeparator: \.isWhitespace) {
            writer.append(String(piece))
        }
        text = writer.text
        wordIndices = 0..<0
        words = []
        wordRanges = []
    }

    /// The words a voice is saying when it reports `range` of ``text``, as
    /// positions in ``words`` and ``wordRanges``.
    ///
    /// - A range can touch several words, as when a voice reads them as one;
    ///   the result runs from the first to the last, with any words between
    ///   them that aren't read.
    /// - An empty range touches the word it lies in.
    /// - A range that touches no word lies in the space or comma between two,
    ///   and belongs to the word after it.
    /// - A range past the last word read gives an empty result at the end.
    func wordPositions(touching range: Range<Int>) -> Range<Int> {
        var first: Int?
        var last = 0
        for (position, wordRange) in wordRanges.enumerated() where !wordRange.isEmpty {
            let touches = range.isEmpty
                ? wordRange.contains(range.lowerBound)
                : wordRange.overlaps(range)
            if touches {
                if first == nil { first = position }
                last = position
            } else if first != nil {
                break
            }
        }
        if let first {
            return first..<last + 1
        }
        if let next = wordRanges.firstIndex(where: { !$0.isEmpty && $0.lowerBound >= range.lowerBound }) {
            return next..<next + 1
        }
        return wordRanges.count..<wordRanges.count
    }
}

// MARK: - Writing

/// Writes words into a script's text, keeping each one's UTF-16 range.
nonisolated private struct ScriptWriter {
    /// Whether two CJK words in a row are joined without a space. They are
    /// for stored words, which the tokenizer cut from unspaced text.
    let joinsCJKWords: Bool

    private(set) var text = ""
    private(set) var ranges: [Range<Int>] = []
    private var length = 0
    /// What the last word read was written as.
    private var previous = ""
    /// Whether a dash in a word left out reads as a comma before the next.
    private var pauseIsPending = false

    init(joinsCJKWords: Bool) {
        self.joinsCJKWords = joinsCJKWords
    }

    mutating func append(_ word: String) {
        let spoken = SpokenWord(word)
        guard let first = spoken.text.unicodeScalars.first else {
            ranges.append(length..<length)
            pauseIsPending = pauseIsPending || spoken.pausesBefore
            return
        }
        if let last = previous.unicodeScalars.last {
            let previousIsCJK = CJKUtilities.isCJK(last)
            if pauseIsPending || spoken.pausesBefore, !SpokenWord.endsWithPause(previous) {
                write(previousIsCJK ? "\u{FF0C}" : ",")        // ， fullwidth comma
            }
            if !(joinsCJKWords && previousIsCJK && CJKUtilities.isCJK(first)) {
                write(" ")
            }
        }
        let start = length
        write(spoken.text)
        ranges.append(start..<length)
        previous = spoken.text
        pauseIsPending = false
    }

    private mutating func write(_ piece: String) {
        text += piece
        length += piece.utf16.count
    }
}

/// One word as a voice is given it.
nonisolated private struct SpokenWord {
    /// What the voice reads; empty when the word is left out.
    let text: String
    /// Whether the word opens with a dash, or is one, that reads as a comma
    /// after the word before it.
    let pausesBefore: Bool

    init(_ word: String) {
        let characters = Array(word)
        guard let first = characters.firstIndex(where: Self.isLetterOrNumber),
              let last = characters.lastIndex(where: Self.isLetterOrNumber) else {
            // Symbols alone: read only those a voice says as words.
            pausesBefore = characters.contains(where: Self.isDash)
            text = characters.contains(where: Self.isSpokenSymbol)
                ? String(characters.filter { !Self.isDash($0) && !Self.isDecorative($0) })
                : ""
            return
        }

        var leading = Array(characters[..<first])
        pausesBefore = Self.removeSeparatingDashes(from: &leading)
        // A `~` before a number means about, so it stays there.
        leading.removeAll { Self.isDecorative($0) && $0 != "~" }

        var trailing = Array(characters[(last + 1)...])
        let pausesAfter = Self.removeSeparatingDashes(from: &trailing)
        trailing.removeAll(where: Self.isDecorative)

        var text = String(leading) + Self.speakingDashes(in: characters[first...last]) + String(trailing)
        if pausesAfter, !Self.endsWithPause(text) {
            text.append(Self.isCJK(characters[last]) ? "\u{FF0C}" : ",")
        }
        self.text = text
    }

    /// Whether `text` already ends with a mark a voice pauses at: a sentence
    /// end, clause mark, or ellipsis.
    static func endsWithPause(_ text: String) -> Bool {
        !PunctuationMarks.marks(in: text).isDisjoint(with: [.sentenceEnd, .clause, .ellipsis])
    }

    /// Removes the dashes at the edge of a word that separate it from the
    /// next or previous word: any run with a long dash or en dash, or of two
    /// or more dashes. A single hyphen stays: `-5`, or `pre-` in
    /// `pre- and post-war`.
    ///
    /// - Returns: Whether any were removed.
    private static func removeSeparatingDashes(from characters: inout [Character]) -> Bool {
        var kept: [Character] = []
        var removed = false
        var index = 0
        while index < characters.count {
            guard isDash(characters[index]) else {
                kept.append(characters[index])
                index += 1
                continue
            }
            var end = index
            while end < characters.count, isDash(characters[end]) {
                end += 1
            }
            let run = characters[index..<end]
            if run.count >= 2 || run.contains(where: { !isHyphen($0) }) {
                removed = true
            } else {
                kept.append(contentsOf: run)
            }
            index = end
        }
        characters = kept
        return removed
    }

    /// The letters-to-letters middle of a word, with each run of dashes that
    /// joins two words (a long dash, or two or more dashes) read as a comma.
    /// The tokenizer splits words there today; documents imported before it
    /// did can still hold `elements—stone`. A single hyphen or en dash
    /// stays: `well-known`, `1990–2000`.
    private static func speakingDashes(in core: ArraySlice<Character>) -> String {
        var text = ""
        var index = core.startIndex
        while index < core.endIndex {
            guard isDash(core[index]) else {
                text.append(core[index])
                index += 1
                continue
            }
            var end = index
            while end < core.endIndex, isDash(core[end]) {
                end += 1
            }
            let run = core[index..<end]
            if run.count >= 2 || run.contains(where: isLongDash) {
                // The core starts with a letter or number, so a run has a character before it.
                text += isCJK(core[index - 1]) ? "\u{FF0C}" : ", "
            } else {
                text += String(run)
            }
            index = end
        }
        return text
    }

    private static func isLetterOrNumber(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.first.map(CJKUtilities.isCJK) ?? false
    }

    private static func isDash(_ character: Character) -> Bool {
        switch character {
        case "-", "\u{2010}", "\u{2012}", "\u{2013}":   // - ‐ ‒ –
            return true
        default:
            return isLongDash(character)
        }
    }

    private static func isHyphen(_ character: Character) -> Bool {
        character == "-" || character == "\u{2010}"
    }

    private static func isLongDash(_ character: Character) -> Bool {
        switch character {
        case "\u{2014}", "\u{2015}",                    // — ―
             "\u{2E3A}", "\u{2E3B}":                    // ⸺ ⸻
            return true
        default:
            return false
        }
    }

    /// Marks that set text apart or point to a note, and that a voice either
    /// skips or reads out by name: bullets, asterisks, bars, daggers, rules,
    /// stars, fleurons, and other ornaments. An emoji is never one.
    private static func isDecorative(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        switch scalar.value {
        case 0x2A, 0x5E, 0x5F, 0x60, 0x7C, 0x7E,       // * ^ _ ` | ~
             0xA6, 0xB6, 0xB7,                          // ¦ ¶ ·
             0x2020...0x2023,                           // † ‡ • ‣
             0x2042, 0x2043, 0x204E, 0x2051,            // ⁂ ⁃ ⁎ ⁑
             0x2217, 0x2219, 0x22C6,                    // ∗ ∙ ⋆
             0x2605, 0x2606, 0x2619:                    // ★ ☆ ☙
            return true
        case 0x2500...0x25FF,                           // box drawing, blocks, geometric shapes
             0x2700...0x27BF:                           // dingbats, such as ❧
            return !scalar.properties.isEmojiPresentation
        default:
            return false
        }
    }

    /// Whether a voice reads `character` as a word even with no letters
    /// around it: `&`, `%`, `+`, `$`, an emoji. Other punctuation alone
    /// (`#`, `…`) and decorative marks aren't.
    private static func isSpokenSymbol(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              !isDecorative(character), !isDash(character) else { return false }
        switch scalar.properties.generalCategory {
        case .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return "&@%\u{2030}\u{00A7}".unicodeScalars.contains(scalar)   // & @ % ‰ §
        }
    }
}
