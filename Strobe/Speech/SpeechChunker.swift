import Foundation

/// Picks the words each piece of read-aloud speech covers.
///
/// The voice model renders one chunk at a time, and reading can't start
/// until the first one is ready, so a chunk is about a sentence: enough for
/// the voice to phrase it as a whole, and quick to render again after a
/// seek. How a sentence sounds matters more than how fast it renders, so one
/// up to ``maximumWords`` words and ``maximumLength`` UTF-16 units stays
/// whole. A longer one is split, at a clause mark where it can be, into
/// pieces of about ``preferredWords`` words and ``preferredLength`` units.
///
/// Kokoro renders speech many times faster than it plays and takes at most
/// 510 phonemes in a call, about 80 words of English. Every chunk also
/// carries about 0.8 s of silence around its speech, which is a natural
/// pause at the end of a sentence but a gap in the middle of one, so
/// sentences are split only when they're long. A whole sentence at the
/// maximum renders in about half a second on an M3 Pro and stays well under
/// 510 phonemes unless it's mostly numbers.
nonisolated enum SpeechChunker {

    /// A sentence of at most this many words stays whole, if it's also
    /// within ``maximumLength``.
    static let maximumWords = 40

    /// A sentence whose words, with a space after each, run to at most this
    /// many UTF-16 units stays whole, if it's also within ``maximumWords``.
    static let maximumLength = 250

    /// The most words a piece of a longer sentence aims for.
    static let preferredWords = 24

    /// The most UTF-16 units, counted as in ``maximumLength``, a piece of a
    /// longer sentence aims for, so long words make shorter pieces.
    static let preferredLength = 160

    /// A longer sentence is split at a clause mark only after at least this
    /// many words, so a mark near its start (`Well,`) doesn't make a piece of
    /// a word or two.
    static let minimumSplitWords = 4

    /// The words to read next, starting with the word at `start`.
    ///
    /// - The chunk runs through the end of the sentence `start` is in, by
    ///   ``SentenceBreak/endsSentence(at:in:)``, so `Mr.` or `U.S.` never ends
    ///   one. Starting mid-sentence, as after a seek or a split, gives the
    ///   rest of that sentence.
    /// - It stops before any chapter start in `chapterStarts` after `start`,
    ///   where the next chapter's title is read first.
    /// - A sentence past ``maximumWords`` words or ``maximumLength`` units is
    ///   split after a word with a clause mark or dash
    ///   (``PunctuationMarks/clause``, ``PunctuationMarks/dash``), where a
    ///   voice pauses anyway: the last one that keeps the chunk within
    ///   ``preferredWords`` and ``preferredLength``, or else the first one
    ///   past them, never before ``minimumSplitWords`` words. Without one,
    ///   the chunk is as long as the preferred size allows.
    ///
    /// Always holds at least the word at `start`, and is empty only when
    /// `start` is outside `words`.
    static func chunk(startingAt start: Int, in words: [String], chapterStarts: Set<Int>) -> Range<Int> {
        guard words.indices.contains(start) else {
            let bound = min(max(start, 0), words.count)
            return bound..<bound
        }
        var length = 0
        var index = start
        while index < words.count {
            if index > start, chapterStarts.contains(index) {
                return start..<index
            }
            let wordLength = Self.length(of: words[index])
            if index - start == maximumWords || (index > start && length + wordLength > maximumLength) {
                return start..<splitEnd(from: start, before: index, in: words)
            }
            length += wordLength
            if SentenceBreak.endsSentence(at: index, in: words) {
                return start..<index + 1
            }
            index += 1
        }
        return start..<words.count
    }

    /// A word's length in a chunk: its UTF-16 units and a space.
    private static func length(of word: String) -> Int {
        word.utf16.count + 1
    }

    /// Where a chunk of a sentence too long to stay whole ends, given that
    /// it can't take the word at `limit`.
    private static func splitEnd(from start: Int, before limit: Int, in words: [String]) -> Int {
        // The longest chunk within the preferred size, of at least one word.
        var preferredEnd = start + 1
        var length = Self.length(of: words[start])
        while preferredEnd < limit, preferredEnd - start < preferredWords {
            let longer = length + Self.length(of: words[preferredEnd])
            guard longer <= preferredLength else { break }
            length = longer
            preferredEnd += 1
        }

        let pauses: PunctuationMarks = [.clause, .dash]
        var lastWithin: Int?
        for end in stride(from: start + minimumSplitWords, through: limit, by: 1)
        where !PunctuationMarks.marks(in: words[end - 1]).isDisjoint(with: pauses) {
            guard end <= preferredEnd else {
                return lastWithin ?? end
            }
            lastWithin = end
        }
        return lastWithin ?? preferredEnd
    }
}
