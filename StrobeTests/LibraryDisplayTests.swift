import Foundation
import Testing
@testable import Strobe

struct LibraryDisplayTests {

    @Test func readsTheKindFromTheFileExtension() {
        #expect(DocumentKind(fileName: "Moby Dick.epub") == .epub)
        #expect(DocumentKind(fileName: "paper.PDF") == .pdf)
        #expect(DocumentKind(fileName: "notes.txt") == .text)
        // Pasted text stores its title as the file name.
        #expect(DocumentKind(fileName: "Text \u{2014} Sep 24, 2026 at 3:12 PM") == .text)
        #expect(DocumentKind(fileName: "Chapter 1. The Beginning") == .text)
    }

    @Test func statusFollowsProgress() {
        #expect(ReadingStatus(progress: 0) == .new)
        #expect(ReadingStatus(progress: 0.004) == .inProgress(percent: 1))
        #expect(ReadingStatus(progress: 0.42) == .inProgress(percent: 42))
        #expect(ReadingStatus(progress: 0.999) == .inProgress(percent: 99))
        #expect(ReadingStatus(progress: 1) == .finished)
    }

    @Test func statusLabels() {
        #expect(ReadingStatus.new.label == "New")
        #expect(ReadingStatus.inProgress(percent: 42).label == "42%")
        #expect(ReadingStatus.finished.label == "Finished")
        #expect(ReadingStatus.inProgress(percent: 42).isInProgress)
        #expect(!ReadingStatus.finished.isInProgress)
    }

    @Test func readingMinutesRoundUp() {
        #expect(ReadingTime.minutes(words: 0, wordsPerMinute: 300) == 0)
        #expect(ReadingTime.minutes(words: 1, wordsPerMinute: 300) == 1)
        #expect(ReadingTime.minutes(words: 300, wordsPerMinute: 300) == 1)
        #expect(ReadingTime.minutes(words: 301, wordsPerMinute: 300) == 2)
        #expect(ReadingTime.minutes(words: 18_000, wordsPerMinute: 300) == 60)
        #expect(ReadingTime.minutes(words: 500, wordsPerMinute: 0) == 0)
    }

    @Test func readingTimeLabels() {
        let english = Locale(identifier: "en_US")
        #expect(ReadingTime.label(minutes: 12, locale: english) == "12 min")
        #expect(ReadingTime.label(minutes: 60, locale: english) == "1 hr")
        #expect(ReadingTime.label(minutes: 458, locale: english) == "7 hr 38 min")
        // Anything left reads as at least a minute.
        #expect(ReadingTime.label(minutes: 0, locale: english) == "1 min")
        #expect(ReadingTime.spokenLabel(minutes: 62, locale: english) == "1 hour 2 minutes")
    }

    @Test func coverToneIsStableForAnID() {
        let id = UUID(uuidString: "5A1F1D00-0000-4000-8000-000000000001")!
        let index = CoverTone.index(for: id)
        #expect(CoverTone.palette.indices.contains(index))
        #expect(CoverTone.index(for: id) == index)
        #expect(CoverTone.tone(for: id) == CoverTone.palette[index])
    }

    @MainActor
    @Test func remainingWordsCountFromTheResumePosition() {
        let doc = Document(
            title: "Test",
            fileName: "test.epub",
            bookmarkData: Data(),
            words: Array(repeating: "word", count: 101),
            currentWordIndex: 40
        )
        #expect(doc.kind == .epub)
        #expect(doc.remainingWordCount == 60)
        #expect(doc.remainingMinutes(paceFactor: nil) == 1)
        // 60 words at 300 wpm, five times as long: still a minute.
        #expect(doc.remainingMinutes(paceFactor: 5) == 1)
        #expect(doc.remainingMinutes(paceFactor: 6) == 2)
        doc.currentWordIndex = 100
        #expect(doc.remainingWordCount == 0)
    }
}
