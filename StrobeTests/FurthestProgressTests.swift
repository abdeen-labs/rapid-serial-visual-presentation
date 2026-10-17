import Foundation
import Testing
@testable import Strobe

/// The furthest-read marker keeps what playback reached, not just where the
/// reader was each time it saved.
struct FurthestProgressTests {

    private func makeDocument(wordCount count: Int, position: Int = 0) -> Document {
        Document(
            title: "Test",
            fileName: "test",
            bookmarkData: Data(),
            words: Array(repeating: "word", count: count),
            currentWordIndex: position
        )
    }

    // MARK: - RSVPEngine.furthestPlayedIndex

    @MainActor
    @Test func furthestPlayedIndexFollowsPlaybackOnly() {
        let engine = RSVPEngine(words: ["one", "two", "three", "four", "five", "six"], wordsPerMinute: 1)
        defer { engine.pause() }
        engine.play()
        engine.advance()
        engine.advance()
        #expect(engine.furthestPlayedIndex == 2)
        // Jumping ahead to look isn't reading.
        engine.seek(to: 5)
        #expect(engine.furthestPlayedIndex == 2)
        engine.restart()
        #expect(engine.furthestPlayedIndex == 2)
        engine.play()
        engine.advance()
        #expect(engine.currentIndex == 1)
        #expect(engine.furthestPlayedIndex == 2)
    }

    @MainActor
    @Test func furthestPlayedIndexCountsWordsAChapterTitleStandsIn() {
        let chapter = Chapter(title: "Chapter One", wordIndex: 0)
        let engine = RSVPEngine(
            words: ["Chapter", "One", "It", "began"], wordsPerMinute: 1, chapters: [chapter]
        )
        defer { engine.pause() }
        engine.play()
        engine.advance() // Title fades out.
        engine.advance() // Reading picks up after the heading's words.
        #expect(engine.currentWord == "It")
        #expect(engine.furthestPlayedIndex == 2)
    }

    @MainActor
    @Test func loadingWordsStartsTheMarkerOver() {
        let engine = RSVPEngine(words: ["one", "two", "three"], wordsPerMinute: 1)
        engine.play()
        engine.advance()
        engine.load(words: ["a", "b", "c", "d"], currentIndex: 2, complexityScores: nil)
        #expect(engine.furthestPlayedIndex == 0)
    }

    // MARK: - Document.recordPosition

    @Test func recordPositionKeepsTheFurthestPlayedWord() {
        let doc = makeDocument(wordCount: 11, position: 2)
        doc.recordPosition(currentIndex: 3, furthestIndex: 9, wordsPerMinute: 300, touchLastReadDate: false)
        #expect(doc.currentWordIndex == 3)
        #expect(doc.furthestWordIndex == 9)
    }

    @Test func recordPositionIgnoresAFurthestIndexBehindTheMarker() {
        let doc = makeDocument(wordCount: 11, position: 7)
        doc.recordPosition(currentIndex: 4, furthestIndex: 1, wordsPerMinute: 300, touchLastReadDate: false)
        #expect(doc.furthestWordIndex == 7)
    }

    /// Reading to the last word, then "Read Again", then leaving the reader
    /// used to keep the progress from before the session.
    @MainActor
    @Test func readingToTheEndThenReadingAgainStaysFinished() {
        let words = ["one", "two", "three", "four", "five", "six"]
        let doc = makeDocument(wordCount: words.count, position: 2)
        let engine = RSVPEngine(words: [], wordsPerMinute: 1)
        defer { engine.pause() }
        engine.load(words: words, currentIndex: doc.currentWordIndex, complexityScores: nil)
        engine.play()
        while engine.isPlaying { engine.advance() }
        #expect(engine.isAtEnd)
        engine.restart()
        doc.recordPosition(
            currentIndex: engine.currentIndex,
            furthestIndex: engine.furthestPlayedIndex,
            wordsPerMinute: 300,
            touchLastReadDate: true
        )
        #expect(doc.currentWordIndex == 0)
        #expect(doc.progress == 1)
    }
}
