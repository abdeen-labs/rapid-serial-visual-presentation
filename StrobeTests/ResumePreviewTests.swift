import Foundation
import Testing
@testable import Strobe

struct ResumePreviewTests {

    private static func words(_ text: String) -> [String] {
        text.split(separator: " ").map(String.init)
    }

    private func preview(
        _ words: [String],
        at index: Int,
        blockEnds: BlockEnds = .none,
        chapters: [Chapter] = []
    ) -> String? {
        ResumePreview.text(words: words, resumeIndex: index, blockEnds: blockEnds, chapters: chapters)
    }

    // MARK: - Where it starts

    @Test func startsAtTheSentencesFirstWord() {
        //                 0   1      2    3    4     5     6   7     8    9
        let story = Self.words("It ended. Then more words came. Was that all? Yes.")
        #expect(preview(story, at: 4) == "Then more words came. Was that all? Yes.")
        #expect(preview(story, at: 2) == "Then more words came. Was that all? Yes.")
        #expect(preview(story, at: 7) == "Was that all? Yes.")
    }

    @Test func abbreviationsDoNotStartASentence() {
        let words = Self.words("Go. Mr. Smith arrived at 5 p.m. today. Then he left.")
        #expect(preview(words, at: 5) == "Mr. Smith arrived at 5 p.m. today. Then he left.")
    }

    @Test func aBlockEndStartsASentence() {
        let words = Self.words("A Heading The first line goes on")
        #expect(preview(words, at: 5, blockEnds: BlockEnds([1: .block])) == "The first line goes on")
    }

    @Test func anUnstartedDocumentShowsItsOpeningWords() {
        let words = Self.words("Call me Ishmael. Some years ago, never mind how long precisely.")
        #expect(preview(words, at: 0) == "Call me Ishmael. Some years ago, never mind how long precisely.")
    }

    @Test func aDocumentWithoutWordsHasNoPreview() {
        #expect(preview([], at: 0) == nil)
        #expect(preview(["", ""], at: 0) == nil)
    }

    @Test func theLastSentenceRunsToTheEndWithoutAnEllipsis() {
        let words = Self.words("First one. The last one.")
        #expect(preview(words, at: 4) == "The last one.")
        // A position past the end is held to the last word.
        #expect(preview(words, at: 40) == "The last one.")
    }

    // MARK: - Chapters

    @Test func aHeadingAtTheResumePointIsLeftToTheChapterTitle() {
        //                      0    1     2       3     4  5   6   7  8     9
        let words = Self.words("The end. Fin. Chapter One It was a dark night.")
        let chapters = [Chapter(title: "Chapter One", wordIndex: 3)]
        #expect(preview(words, at: 3, chapters: chapters) == "It was a dark night.")
        #expect(preview(words, at: 4, chapters: chapters) == "It was a dark night.")
        #expect(preview(words, at: 7, chapters: chapters) == "It was a dark night.")
    }

    @Test func anOpeningHeadingIsLeftOutOfAnUnstartedDocument() {
        let words = Self.words("Chapter One It was night.")
        #expect(preview(words, at: 0, chapters: [Chapter(title: "Chapter One", wordIndex: 0)]) == "It was night.")
    }

    @Test func aHeadingThatDoesNotRepeatTheTitleIsShown() {
        let words = Self.words("Something else entirely. More text.")
        #expect(
            preview(words, at: 0, chapters: [Chapter(title: "Chapter One", wordIndex: 0)])
                == "Something else entirely. More text."
        )
    }

    @Test func stopsBeforeTheNextChapter() {
        let words = Self.words("Last words here. Chapter Two Begins now.")
        let chapters = [Chapter(title: "Chapter Two", wordIndex: 3)]
        #expect(preview(words, at: 0, chapters: chapters) == "Last words here.")
    }

    // MARK: - Length

    @Test func cutsAtTheMostWords() {
        let words = Array(repeating: "word", count: 30)
        let expected = Array(repeating: "word", count: ResumePreview.maximumWords).joined(separator: " ") + "…"
        #expect(preview(words, at: 0) == expected)
        // Exactly the most words, with nothing after: no ellipsis.
        let exact = Array(repeating: "word", count: ResumePreview.maximumWords)
        #expect(preview(exact, at: 0) == exact.joined(separator: " "))
    }

    @Test func cutsAtTheMostCharacters() {
        let long = String(repeating: "a", count: 20)
        let words = Array(repeating: long, count: 10)
        // Seven words and their spaces take 146 characters; an eighth would
        // take 167.
        let text = preview(words, at: 0)
        #expect(text == Array(repeating: long, count: 7).joined(separator: " ") + "…")
    }

    @Test func aWordTooLongToShowIsCut() {
        let link = String(repeating: "x", count: 300)
        #expect(preview([link, "after"], at: 0) == String(repeating: "x", count: ResumePreview.maximumLength) + "…")
    }

    @Test func aClauseMarkAtTheCutMakesWayForTheEllipsis() {
        let words = Array(repeating: "word", count: 23) + ["end,", "more"]
        #expect(preview(words, at: 0)?.hasSuffix(" end…") == true)
        let dashed = Array(repeating: "word", count: 23) + ["end—", "more"]
        #expect(preview(dashed, at: 0)?.hasSuffix(" end…") == true)
    }

    @Test func anEllipsisAfterASentenceEndStandsApart() {
        let words = Array(repeating: "word", count: 23) + ["end.", "More"]
        #expect(preview(words, at: 0)?.hasSuffix(" end. …") == true)
        let quoted = Array(repeating: "word", count: 23) + ["end.\u{201D}", "More"]
        #expect(preview(quoted, at: 0)?.hasSuffix(" end.\u{201D} …") == true)
        let trailing = Array(repeating: "word", count: 23) + ["end...", "more"]
        #expect(preview(trailing, at: 0)?.hasSuffix(" end...") == true)
    }

    // MARK: - Joining

    @Test func storedWordsKeepTheirSpacesAndPunctuation() {
        let words = ["Rome", "fell", "in", "476 AD.", "Then", "came", "night."]
        #expect(preview(words, at: 0) == "Rome fell in 476 AD. Then came night.")
    }

    @Test func cjkWordsJoinWithoutSpaces() {
        let words = ["我们", "今天", "去", "公园。", "他们", "也", "去。"]
        #expect(preview(words, at: 0) == "我们今天去公园。他们也去。")
        #expect(preview(words, at: 5) == "他们也去。")
        // Latin words among CJK keep their spaces.
        #expect(preview(["我", "用", "iPhone", "读书。"], at: 0) == "我用 iPhone 读书。")
    }

    @Test func cjkCharactersCountTwiceTowardTheLength() {
        let word = "字字字字字"
        let words = Array(repeating: word, count: 30)
        // Sixteen five-character words come to 160.
        #expect(preview(words, at: 0) == String(repeating: word, count: 16) + "…")
    }

    // MARK: - Reading a window of the words

    @Test func aWindowOfTheStoredWordsGivesTheWholeDocumentsPreview() {
        var words = (0..<1000).map { $0 % 9 == 8 ? "W\($0)." : "W\($0)" }
        // A long stretch without a sentence end, so the look back is cut short.
        for index in 400..<700 { words[index] = "w\(index)" }
        let blockEnds = BlockEnds([120: .block, 450: .block, 451: .cell, 760: .block])
        let chapters = [Chapter(title: "W300", wordIndex: 300), Chapter(title: "Part Two", wordIndex: 800)]
        let blob = WordStorage.encode(words)
        for index in [0, 5, 120, 299, 300, 301, 450, 520, 650, 699, 761, 800, 999] {
            let window = ResumePreview.window(around: index)
            let windowed = ResumePreview.text(
                words: WordStorage.decode(blob, range: window),
                firstIndex: window.lowerBound,
                resumeIndex: index,
                blockEnds: blockEnds,
                chapters: chapters
            )
            let whole = ResumePreview.text(words: words, resumeIndex: index, blockEnds: blockEnds, chapters: chapters)
            #expect(windowed != nil)
            #expect(windowed == whole, "at \(index)")
        }
    }

    @Test func readsARangeOfTheStoredWords() {
        let words = ["Caf\u{E9}", "2000 BCE", "", "我们", "end.", "last"]
        let data = WordStorage.encode(words)
        #expect(WordStorage.decode(data, range: 0..<words.count) == words)
        #expect(WordStorage.decode(data, range: 1..<4) == Array(words[1..<4]))
        #expect(WordStorage.decode(data, range: 4..<100) == ["end.", "last"])
        #expect(WordStorage.decode(data, range: 6..<10) == [])
        #expect(WordStorage.decode(data, range: 2..<2) == [])
        #expect(WordStorage.decode(data, range: -5..<2) == Array(words[0..<2]))
        #expect(WordStorage.decode(Data(), range: 0..<3) == [])
        // A trailing newline is an empty last word, as decode(_:) reads it.
        let trailing = Data("a\nb\n".utf8)
        #expect(WordStorage.decode(trailing, range: 0..<5) == WordStorage.decode(trailing))
    }

    // MARK: - Snapshot

    private func item(preview: String?) -> ContinueReadingSnapshot.Item {
        ContinueReadingSnapshot.Item(
            id: UUID(uuidString: "5A1F1D00-0000-4000-8000-000000000012")!,
            title: "Moby-Dick",
            fileName: "Moby-Dick.epub",
            progress: 0.4,
            chapterTitle: "Loomings",
            remainingMinutes: 12,
            preview: preview
        )
    }

    @Test func aSnapshotSavedBeforePreviewsStillDecodes() throws {
        let json = """
        {"item":{"id":"5A1F1D00-0000-4000-8000-000000000012","title":"Moby-Dick","fileName":"Moby-Dick.epub",\
        "progress":0.4,"chapterTitle":"Loomings","remainingMinutes":12},"libraryIsEmpty":false}
        """
        let snapshot = try JSONDecoder().decode(ContinueReadingSnapshot.self, from: Data(json.utf8))
        #expect(snapshot == ContinueReadingSnapshot(item: item(preview: nil), libraryIsEmpty: false))
    }

    @Test func aSnapshotKeepsItsPreview() throws {
        let snapshot = ContinueReadingSnapshot(item: item(preview: "Call me Ishmael."), libraryIsEmpty: false)
        let decoded = try JSONDecoder().decode(ContinueReadingSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        #expect(decoded.item?.preview == "Call me Ishmael.")
    }

    @Test func anArabicPreviewReadsRightToLeft() {
        #expect(item(preview: "كان يا ما كان في قديم الزمان").previewIsRightToLeft)
        #expect(!item(preview: "Call me Ishmael.").previewIsRightToLeft)
        #expect(!item(preview: nil).previewIsRightToLeft)
    }
}
