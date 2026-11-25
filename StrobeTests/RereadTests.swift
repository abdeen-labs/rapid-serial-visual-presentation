import Testing
import Foundation
@testable import Strobe

struct RereadTests {

    private static func words(_ text: String) -> [String] {
        text.split(separator: " ").map(String.init)
    }

    //                                  0   1      2    3    4     5     6   7     8    9
    private static let story = words("It ended. Then more words came. Was that all? Yes.")

    private func start(at index: Int, in words: [String] = story) -> Int {
        SentenceBreak.sentenceStart(at: index, in: words)
    }

    private func reread(from index: Int, in words: [String] = story) -> Int? {
        SentenceBreak.rereadStart(from: index, in: words)
    }

    // MARK: - Where a sentence starts

    @Test func everyWordFindsItsSentencesFirstWord() {
        #expect((0..<Self.story.count).map { start(at: $0) } == [0, 0, 2, 2, 2, 2, 6, 6, 6, 9])
    }

    /// The sentence break's own test: no start after an abbreviation or
    /// before a lowercase word.
    @Test func abbreviationsDoNotStartASentence() {
        let words = Self.words("Go. Mr. Smith arrived at 5 p.m. today. Then he left.")
        #expect(start(at: 7, in: words) == 1)
        #expect(start(at: 2, in: words) == 1)
        #expect(start(at: 10, in: words) == 8)
    }

    @Test func aBlockEndStartsASentence() {
        let words = Self.words("A Heading The first line goes on")
        let ends = BlockEnds([1: .block])
        #expect(SentenceBreak.sentenceStart(at: 5, in: words, blockEnds: ends) == 2)
        #expect(SentenceBreak.sentenceStart(at: 1, in: words, blockEnds: ends) == 0)
        // A table cell's end is a clause's, not a sentence's.
        #expect(SentenceBreak.sentenceStart(at: 5, in: words, blockEnds: BlockEnds([1: .cell])) == 0)
    }

    @Test func aChapterStartsASentence() {
        let words = Self.words("no marks here at all in this text")
        #expect(SentenceBreak.sentenceStart(at: 6, in: words, startsChapter: { $0 == 3 }) == 3)
        #expect(SentenceBreak.sentenceStart(at: 3, in: words, startsChapter: { $0 == 3 }) == 3)
        #expect(SentenceBreak.sentenceStart(at: 2, in: words, startsChapter: { $0 == 3 }) == 0)
    }

    /// Text with no sentence ends goes back a fixed way, not to its start.
    @Test func looksBackOnlySoFar() {
        let words = Array(repeating: "word", count: 1000)
        #expect(start(at: 900, in: words) == 900 - SentenceBreak.longestSentence)
        #expect(start(at: 50, in: words) == 0)
    }

    @Test func positionsOutsideTheDocumentAreHeldToIt() {
        #expect(start(at: -5) == 0)
        #expect(start(at: 99) == 9)
        #expect(SentenceBreak.sentenceStart(at: 3, in: []) == 0)
    }

    // MARK: - Where rereading goes

    @Test func goesBackToTheSentencesFirstWord() {
        #expect(reread(from: 5) == 2)
        let words = Self.words("It ended. Then a great many more words came along. Yes.")
        #expect((5...9).map { SentenceBreak.rereadStart(from: $0, in: words) } == [2, 2, 2, 2, 2])
    }

    /// By the time a reader lets go, the next sentence has begun: its
    /// first word and the two after go back to the sentence before.
    @Test func earlyInASentenceGoesBackToTheOneBefore() {
        #expect(SentenceBreak.nearStart == 2)
        #expect(reread(from: 2) == 0)
        #expect(reread(from: 3) == 0)
        #expect(reread(from: 4) == 0)
        #expect(reread(from: 6) == 2)
        #expect(reread(from: 8) == 2)
        #expect(reread(from: 9) == 6)
    }

    @Test func theFirstSentenceGoesBackToTheFirstWord() {
        #expect(reread(from: 1) == 0)
        #expect(reread(from: 0) == nil)
        #expect(reread(from: 99) == nil)
        #expect(SentenceBreak.rereadStart(from: 0, in: []) == nil)
    }

    /// Going back again and again steps back a sentence at a time, to the
    /// first word, and always moves.
    @Test func goingBackAgainStepsThroughTheSentences() {
        var index = Self.story.count - 1
        var stops: [Int] = []
        while let next = reread(from: index) {
            #expect(next < index)
            stops.append(next)
            index = next
        }
        #expect(stops == [6, 2, 0])
    }

    // MARK: - Engine

    /// At 1 WPM the real timer never fires during a test.
    @MainActor
    private func engine(at index: Int, chapters: [Chapter] = []) -> RSVPEngine {
        RSVPEngine(words: Self.story, currentIndex: index, wordsPerMinute: 1, chapters: chapters)
    }

    @MainActor
    @Test func pausedItGoesBackAndStaysPaused() {
        let engine = engine(at: 5)
        #expect(engine.rereadSentence())
        #expect(engine.currentIndex == 2)
        #expect(!engine.isPlaying)
        #expect(engine.rereadSentence())
        #expect(engine.currentIndex == 0)
        #expect(!engine.rereadSentence())
        #expect(engine.currentIndex == 0)
    }

    @MainActor
    @Test func playingItGoesBackAndReadsOn() {
        let engine = engine(at: 5)
        engine.play()
        defer { engine.pause() }
        #expect(engine.rereadSentence())
        #expect(engine.currentIndex == 2)
        #expect(engine.isPlaying)
        engine.advance()
        #expect(engine.currentIndex == 3)
    }

    @MainActor
    @Test func fromTheLastWordItGoesBack() {
        let engine = engine(at: 9)
        #expect(engine.isAtEnd)
        #expect(engine.rereadSentence())
        #expect(engine.currentIndex == 6)
    }

    /// A chapter's first word starts a sentence, whatever came before it.
    @MainActor
    @Test func aChapterStartStopsIt() {
        let words = Self.words("one two three four five six seven eight")
        let engine = RSVPEngine(
            words: words,
            currentIndex: 7,
            wordsPerMinute: 1,
            chapters: [Chapter(title: "Part Two", wordIndex: 4)]
        )
        #expect(engine.rereadSentence())
        #expect(engine.currentIndex == 4)
    }

    /// Going back doesn't count as reading.
    @MainActor
    @Test func goingBackCountsNoWordsAsPlayed() {
        let engine = engine(at: 5)
        engine.play()
        defer { engine.pause() }
        engine.advance()
        #expect(engine.playedWordTotal == 1)
        engine.rereadSentence()
        #expect(engine.playedWordTotal == 1)
        #expect(engine.furthestPlayedIndex == 6)
    }
}
