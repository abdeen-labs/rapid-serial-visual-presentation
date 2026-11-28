import Foundation

/// A few lines of a document's own text from where reading resumes, for the
/// library's Continue Reading card and the medium Continue Reading widget:
/// the sentence the resume position is in, from its first word, cut to fit.
///
/// It needs only the words around the position, so the library reads a
/// ``window(around:)`` of the stored words (``WordStorage/decode(_:range:)``)
/// rather than the whole book.
nonisolated enum ResumePreview {

    /// The most words a preview holds.
    static let maximumWords = 24
    /// The most characters a preview holds, a CJK character counting as two
    /// since it takes about twice the width.
    static let maximumLength = 160

    /// The words a preview can need around `resumeIndex`: back to the
    /// earliest start ``SentenceBreak/sentenceStart(at:in:blockEnds:startsChapter:)``
    /// looks for, and on past the longest chapter heading the position can
    /// sit on, the preview's words, and the word after them.
    static func window(around resumeIndex: Int) -> Range<Int> {
        let index = max(0, resumeIndex)
        let lookAhead = ChapterHeading.maximumHeadingWords + maximumWords + 2
        return max(0, index - SentenceBreak.longestSentence)..<(index + lookAhead)
    }

    /// The preview for the word at `resumeIndex`, or nil when there are no
    /// words to show.
    ///
    /// - Parameters:
    ///   - words: The document's words, or a window of them that starts at
    ///     `firstIndex` (see ``window(around:)``).
    ///   - resumeIndex: The resume position, as an index into the whole
    ///     document. An unstarted document's is 0, so its preview is its
    ///     opening words.
    ///   - blockEnds: The whole document's block ends.
    ///   - chapters: The whole document's chapters. A preview never runs
    ///     into the next chapter, and doesn't repeat a heading the card
    ///     already shows as the chapter title: on a chapter's heading, it
    ///     starts where reading resumes after the announcement
    ///     (``ChapterHeading``).
    static func text(
        words: [String],
        firstIndex: Int = 0,
        resumeIndex: Int,
        blockEnds: BlockEnds = .none,
        chapters: [Chapter] = []
    ) -> String? {
        guard !words.isEmpty else { return nil }
        let window = firstIndex..<(firstIndex + words.count)
        let index = min(max(resumeIndex - firstIndex, 0), words.count - 1)

        // Everything in the window's own indices, loaded as the engine loads it.
        let localChapters = chapters
            .filter { window.contains($0.wordIndex) }
            .map { Chapter(title: $0.title, wordIndex: $0.wordIndex - firstIndex) }
        let chapterStarts = RSVPEngine.announcedChapters(localChapters, wordCount: words.count)
        var localEnds: [Int: BlockEnds.Kind] = [:]
        for entry in blockEnds.entries where window.contains(entry.index) {
            localEnds[entry.index - firstIndex] = entry.kind
        }
        let ends = BlockEnds(localEnds).droppingEnds(beforeChapterStarts: chapterStarts.keys)
        let readingStarts = ChapterHeading.readingStarts(for: chapterStarts, in: words)

        var start = SentenceBreak.sentenceStart(
            at: index,
            in: words,
            blockEnds: ends,
            startsChapter: { chapterStarts[$0] != nil }
        )
        // Past the heading of the chapter the position is in, when the
        // sentence would start on it.
        if let chapter = chapterStarts.keys.filter({ $0 <= index }).max(),
           let resume = readingStarts[chapter], resume > start {
            start = resume
        }
        guard start < words.count else { return nil }

        var text = ""
        var length = 0
        var count = 0
        var previous: String?
        var next = start
        var isCut = false
        while next < words.count {
            if next > start, chapterStarts[next] != nil { break }
            let word = words[next]
            if word.isEmpty {
                next += 1
                continue
            }
            let joins = previous.map { Self.joinsWithoutSpace($0, word) } ?? true
            let wordLength = Self.length(of: word) + (joins ? 0 : 1)
            if previous != nil, length + wordLength > maximumLength {
                isCut = true
                break
            }
            if previous == nil, wordLength > maximumLength {
                // One word too long to show whole, such as a link.
                text = Self.prefix(of: word, length: maximumLength)
                isCut = true
                break
            }
            if !joins { text += " " }
            text += word
            length += wordLength
            previous = word
            count += 1
            next += 1
            if count >= maximumWords {
                isCut = next < words.count && chapterStarts[next] == nil
                break
            }
        }
        guard !text.isEmpty else { return nil }
        return isCut ? Self.endingWithEllipsis(text) : text
    }

    // MARK: - Writing

    /// Whether two words in a row join without a space: CJK words, which the
    /// tokenizer cut from unspaced text, as ``SpeechScript`` joins them.
    private static func joinsWithoutSpace(_ previous: String, _ word: String) -> Bool {
        guard let last = previous.unicodeScalars.last, let first = word.unicodeScalars.first else { return false }
        return CJKUtilities.isCJK(last) && CJKUtilities.isCJK(first)
    }

    private static func length(of text: String) -> Int {
        text.reduce(0) { total, character in
            total + ((character.unicodeScalars.first.map { CJKUtilities.isCJK($0) } ?? false) ? 2 : 1)
        }
    }

    private static func prefix(of text: String, length limit: Int) -> String {
        var length = 0
        var prefix = ""
        for character in text {
            length += Self.length(of: String(character))
            guard length <= limit else { break }
            prefix.append(character)
        }
        return prefix
    }

    /// Marks that the text goes on: a clause mark or dash at the cut goes,
    /// an ellipsis already there stays alone, and one after a sentence's end
    /// stands apart from it.
    private static func endingWithEllipsis(_ text: String) -> String {
        var text = text
        while let last = text.last, Self.droppedAtCut.contains(last) || last.isWhitespace {
            text.removeLast()
        }
        guard !text.isEmpty else { return "…" }
        if text.hasSuffix("…") || text.hasSuffix("...") { return text }
        let mark = text.last { !Self.closingMarks.contains($0) }
        if let mark, Self.sentenceEnds.contains(mark) { return text + " …" }
        return text + "…"
    }

    private static let droppedAtCut: Set<Character> = [
        ",", ";", ":", "-", "‐", "–", "—", "―", "，", "、", "；", "：",
    ]
    private static let closingMarks: Set<Character> = [
        "\"", "'", "”", "’", "»", "›", ")", "]", "}",
    ]
    private static let sentenceEnds: Set<Character> = [".", "!", "?"]
}
