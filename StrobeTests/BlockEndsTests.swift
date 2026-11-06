import Foundation
import Testing
@testable import Strobe

struct BlockEndsTests {

    private static func timing(
        pauses: Bool = true,
        breaks: Bool = false,
        breakLength: Double = 2
    ) -> ReaderSettings.TimingSnapshot {
        ReaderSettings.TimingSnapshot(
            smartTimingEnabled: false,
            sentencePauseEnabled: pauses,
            smartTimingPercentPerLetter: 0,
            smartTimingMinimumWordLength: 1,
            sentencePauseMultiplier: 3,
            complexityTimingEnabled: false,
            complexitySpeedUpIntensity: 0,
            complexitySlowDownIntensity: 0,
            punctuationPauses: PunctuationPauses(clause: 2, dash: 1.5, ellipsis: 1.5, bracket: 1.25),
            sentenceBreakEnabled: breaks,
            sentenceBreakLength: breakLength
        )
    }

    private static func interval(_ index: Int, _ words: [String], _ ends: BlockEnds, timing: ReaderSettings.TimingSnapshot = timing()) -> Double {
        RSVPEngine.interval(
            forWordAt: index, in: words, complexityScores: nil, blockEnds: ends, timing: timing, baseInterval: 1
        )
    }

    // MARK: - The model and its storage

    @Test func storageRoundTrips() {
        var ends = BlockEnds()
        for index in [0, 1, 7, 127, 128, 16_383, 16_384, 1_000_000] { ends.mark(index, as: .block) }
        ends.mark(3, as: .cell)
        ends.mark(200_000, as: .cell)
        let data = BlockEndStorage.encode(ends)
        #expect(data != nil)
        #expect(BlockEndStorage.decode(data) == ends)
        #expect(BlockEndStorage.encode(.none) == nil)
        #expect(BlockEndStorage.decode(nil).isEmpty)
        #expect(BlockEndStorage.decode(Data()).isEmpty)
    }

    @Test func storageIsCompact() throws {
        var ends = BlockEnds()
        for paragraph in 0..<5_000 { ends.mark(paragraph * 40 + 39, as: .block) }
        let data = try #require(BlockEndStorage.encode(ends))
        #expect(data.count <= 10_000)
    }

    @Test func malformedStorageKeepsWhatCameBefore() {
        var ends = BlockEnds()
        ends.mark(2, as: .block)
        ends.mark(9, as: .cell)
        var data = BlockEndStorage.encode(ends) ?? Data()
        data.append(0x80)  // A varint that never ends.
        #expect(BlockEndStorage.decode(data) == ends)
        // A distance of zero would repeat an index.
        #expect(BlockEndStorage.decode(Data([0x02, 0x00, 0x04])).entries.map(\.index) == [0])
    }

    @Test func aBlockOutranksACellAtTheSameWord() {
        var ends = BlockEnds()
        ends.mark(4, as: .cell)
        ends.mark(4, as: .block)
        ends.mark(4, as: .cell)
        ends.mark(-1, as: .block)
        #expect(ends.kind(at: 4) == .block)
        #expect(ends.count == 1)
    }

    @Test func aLowercaseContinuationDoesntPauseABlock() {
        let ends = BlockEnds([0: .block, 2: .block, 4: .cell, 6: .block])
        let words = ["Heading", "Body", "split", "continues", "a", "b", "Last"]
        #expect(ends.pause(after: 0, in: words) == .block)
        #expect(ends.pause(after: 2, in: words) == nil)
        #expect(ends.pause(after: 4, in: words) == .cell)
        #expect(ends.pause(after: 6, in: words) == .block)
        #expect(ends.pause(after: 1, in: words) == nil)
        #expect(BlockEnds([0: .block]).pause(after: 0, in: ["Said", "“and"]) == nil)
        #expect(BlockEnds([0: .block]).pause(after: 0, in: ["标题", "正文"]) == .block)
        #expect(BlockEnds([0: .block]).pause(after: 0, in: ["Title", "(1)"]) == .block)
    }

    // MARK: - Timing

    @Test func aBlockEndPausesLikeASentenceEndAndACellLikeAClause() {
        let words = ["Heading", "Body", "Cell", "Next"]
        let ends = BlockEnds([0: .block, 2: .cell])
        #expect(Self.interval(0, words, ends) == 3)
        #expect(Self.interval(1, words, ends) == 1)
        #expect(Self.interval(2, words, ends) == 2)
        #expect(Self.interval(0, words, .none) == 1)
        // Punctuation pauses off turn block pauses off too.
        #expect(Self.interval(0, words, ends, timing: Self.timing(pauses: false)) == 1)
    }

    @Test func aWordWithItsOwnMarkPausesOnceForTheLongest() {
        let ends = BlockEnds([0: .block, 1: .block, 2: .cell])
        let words = ["Done.", "Note:", "Item.", "Next"]
        #expect(Self.interval(0, words, ends) == Self.interval(0, words, .none))
        #expect(Self.interval(1, words, ends) == 3)
        #expect(Self.interval(2, words, ends) == 3)
    }

    @Test func aBlockEndTakesASentenceBreakButACellDoesnt() {
        let timing = Self.timing(breaks: true)
        let words = ["Heading", "Body", "Cell", "Next", "lower"]
        let ends = BlockEnds([0: .block, 2: .cell, 3: .block, 4: .block])
        #expect(RSVPEngine.breaksAfterWord(at: 0, in: words, blockEnds: ends, nextWordStartsChapter: false, timing: timing))
        #expect(!RSVPEngine.breaksAfterWord(at: 0, in: words, blockEnds: ends, nextWordStartsChapter: true, timing: timing))
        #expect(!RSVPEngine.breaksAfterWord(at: 2, in: words, blockEnds: ends, nextWordStartsChapter: false, timing: timing))
        #expect(!RSVPEngine.breaksAfterWord(at: 3, in: words, blockEnds: ends, nextWordStartsChapter: false, timing: timing))
        #expect(!RSVPEngine.breaksAfterWord(at: 4, in: words, blockEnds: ends, nextWordStartsChapter: false, timing: timing))
        #expect(!RSVPEngine.breaksAfterWord(
            at: 0, in: words, blockEnds: ends, nextWordStartsChapter: false, timing: Self.timing(breaks: false)
        ))
    }

    @MainActor
    @Test func theEngineTimesWithTheDocumentsBlockEnds() {
        let engine = RSVPEngine(words: [], wordsPerMinute: 600, sentencePauseEnabled: true)
        let words = ["Heading", "Body"]
        engine.load(words: words, currentIndex: 0, complexityScores: nil, blockEnds: BlockEnds([0: .block]))
        let withEnds = engine.nextInterval()
        engine.load(words: words, currentIndex: 0, complexityScores: nil)
        #expect(withEnds > engine.nextInterval())
        #expect(engine.blockEnds.isEmpty)
    }

    @Test func thePaceCountsBlockEnds() {
        let words = ["Heading", "Body", "text."]
        let ends = BlockEnds([0: .block, 2: .block])
        let timing = Self.timing(breaks: true)
        let plain = ReadingPace.factor(words: words, complexityScores: nil, chapters: [], timing: timing)
        let blocked = ReadingPace.factor(words: words, complexityScores: nil, blockEnds: ends, chapters: [], timing: timing)
        // `Heading` pauses (2 more intervals) and takes a 2-interval blank.
        #expect(abs((blocked - plain) * Double(words.count) - 4) < 1e-9)
    }

    // MARK: - The voice

    @Test func aChunkEndsAtABlockEnd() {
        let words = ["Title", "Body", "text", "goes", "on."]
        #expect(SpeechChunker.chunk(startingAt: 0, in: words, chapterStarts: [], blockEnds: BlockEnds([0: .block])) == 0..<1)
        #expect(SpeechChunker.chunk(startingAt: 0, in: words, chapterStarts: []) == 0..<5)
        // A continuation in lowercase isn't an end.
        #expect(SpeechChunker.chunk(startingAt: 1, in: words, chapterStarts: [], blockEnds: BlockEnds([1: .block])) == 1..<5)
    }

    @Test func aLongRunOfCellsSplitsAtACell() {
        let words = (0..<50).map { "Cell\($0)" }
        var ends = BlockEnds()
        for index in stride(from: 4, to: 50, by: 5) { ends.mark(index, as: .cell) }
        #expect(SpeechChunker.chunk(startingAt: 0, in: words, chapterStarts: [], blockEnds: ends) == 0..<20)
    }

    @Test func aScriptEndsUnpunctuatedBlocksAndCells() {
        let words = ["Title", "Cell", "Ready:", "Body."]
        let ends = BlockEnds([0: .block, 1: .cell, 2: .block])
        let script = SpeechScript(words: words, range: words.indices, blockEnds: ends)
        #expect(script.text == "Title. Cell, Ready: Body.")
        #expect(script.wordRanges[0] == 0..<6)
        #expect(script.wordRanges[1] == 7..<12)
        #expect(SpeechScript(words: words, range: words.indices).text == "Title Cell Ready: Body.")
        #expect(SpeechScript(words: ["标题", "正文"], range: 0..<2, blockEnds: BlockEnds([0: .block])).text == "标题。正文")
    }

    @Test func theScriptsPeriodWaitsForAContinuation() {
        let words = ["Split", "continues"]
        #expect(SpeechScript(words: words, range: 0..<2, blockEnds: BlockEnds([0: .block])).text == "Split continues")
    }

    // MARK: - Importers

    @Test func markdownRecordsBlocksAndCells() throws {
        let result = try MarkdownTextExtractor.extractWordsAndChapters(from: """
        # Title

        Body text.

        | A | B |
        | --- | --- |
        | 1 | 2 |

        - Item
        """)
        #expect(result.words == ["Title", "Body", "text.", "A", "B", "1", "2", "Item"])
        #expect(result.blockEnds.entries.map(\.index) == [0, 2, 3, 4, 5, 6, 7])
        #expect(result.blockEnds.kind(at: 0) == .block)
        #expect(result.blockEnds.kind(at: 3) == .cell)
        #expect(result.blockEnds.kind(at: 5) == .cell)
        // The table's last cell ends a block.
        #expect(result.blockEnds.kind(at: 6) == .block)
        #expect(result.blockEnds.kind(at: 7) == .block)
    }

    @Test func eachOfTwoTablesInARowEndsABlock() throws {
        let result = try MarkdownTextExtractor.extractWordsAndChapters(from: """
        | A | B |
        | --- | --- |
        | 1 | 2 |

        | C | D |
        | --- | --- |
        | 3 | 4 |
        """)
        #expect(result.words == ["A", "B", "1", "2", "C", "D", "3", "4"])
        #expect(result.blockEnds.kind(at: 2) == .cell)
        #expect(result.blockEnds.kind(at: 3) == .block)
        #expect(result.blockEnds.kind(at: 6) == .cell)
        #expect(result.blockEnds.kind(at: 7) == .block)
    }

    @Test func noBlockPauseRightBeforeAChapter() {
        let words = ["Intro", "Heading", "Body"]
        let ends = BlockEnds([0: .block, 1: .block])
        let chapters = [Chapter(title: "Heading", wordIndex: 1)]
        #expect(ends.droppingEnds(beforeChapterStarts: [1]).entries.map(\.index) == [1])
        let timing = Self.timing()
        #expect(
            ReadingPace.factor(words: words, complexityScores: nil, blockEnds: ends, chapters: chapters, timing: timing)
                == ReadingPace.factor(words: words, complexityScores: nil, blockEnds: BlockEnds([1: .block]), chapters: chapters, timing: timing)
        )
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func plainTextParagraphsEndAtBlankLines(_ lineEnd: String) {
        let text = ["Heading", "", "A paragraph that", "wraps.", "", "", "Last one"].joined(separator: lineEnd)
        let (words, ends) = PlainTextParagraphs.tokenize(text)
        #expect(words == ["Heading", "A", "paragraph", "that", "wraps.", "Last", "one"])
        #expect(ends.entries.map(\.index) == [0, 4, 6])
    }

    @Test func plainTextKeepsItsWordsButNoUnitAcrossAParagraph() {
        let text = "It was 2000\n\nBCE was later.\n\nThe year 44 BC passed."
        let (words, _) = PlainTextParagraphs.tokenize(text)
        #expect(words == ["It", "was", "2000", "BCE", "was", "later.", "The", "year", "44 BC", "passed."])
        let wrapped = "One line\nand the next.\n\nSecond paragraph."
        #expect(PlainTextParagraphs.tokenize(wrapped).words == Tokenizer.tokenize(wrapped))
    }

    @Test func aHyphenatedFragmentAcrossAParagraphMarksNoEnd() {
        let (words, ends) = PlainTextParagraphs.tokenize("infor-\n\nmation here")
        #expect(ends.count == 1)
        #expect(ends.kind(at: words.count - 1) == .block)
    }

    @Test func aFragmentThatDoesntMergeEndsItsParagraph() {
        let (words, ends) = PlainTextParagraphs.tokenize("Pre-\n\nThe next")
        #expect(words == ["Pre-", "The", "next"])
        #expect(ends.entries.map(\.index) == [0, 2])
    }

    @Test func pastedTextStoresItsParagraphs() throws {
        let prepared = try #require(TextImport.prepare("Title\n\nBody."))
        #expect(BlockEndStorage.decode(prepared.blockEndsBlob).entries.map(\.index) == [0, 1])
    }

    @Test func epubRecordsTheWordBeforeEachBlockBreak() {
        let content = EPUBContent.parse(Data("<h1>The Heading</h1><p>Body text.</p><p>split</p><p>continues here</p>".utf8))
        var words: [String] = []
        var carry: String?
        var ends = BlockEnds()
        _ = content.appendWords(cleanedText: content.text, into: &words, carry: &carry, blockEnds: &ends)
        #expect(words == ["The", "Heading", "Body", "text.", "split", "continues", "here"])
        #expect(ends.entries.map(\.index) == [1, 3, 4])
        // `split` runs on into `continues`, so it doesn't pause.
        #expect(ends.pause(after: 4, in: words) == nil)
    }

    @Test func importedPlainTextCarriesItsBlockEnds() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("strobe_\(UUID().uuidString).txt")
        try "Title\r\n\r\nBody text.\r\nMore.".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try DocumentImportPipeline.extractWordsAndChapters(from: url, cleaningLevel: .standard)
        #expect(result.words == ["Title", "Body", "text.", "More."])
        #expect(result.blockEnds.entries.map(\.index) == [0, 3])
    }

    // MARK: - Sync

    @Test func downloadedBlockEndsMustFitTheWords() throws {
        let words = WordStorage.encode(["Title", "Body."])
        let fields = BookRecordFields(
            title: "T", fileName: "t.txt", dateAdded: .now, wordCount: 2, chapters: [],
            contentHash: ContentFingerprint.of(words)
        )
        let directory = FileManager.default.temporaryDirectory.appending(path: "block-ends-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wordsURL = directory.appending(path: "words")
        try words.write(to: wordsURL)
        let fitting = directory.appending(path: "fitting")
        try #require(BlockEndStorage.encode(BlockEnds([0: .block, 1: .block]))).write(to: fitting)
        let tooLong = directory.appending(path: "tooLong")
        try #require(BlockEndStorage.encode(BlockEnds([5: .block]))).write(to: tooLong)

        let content = BookContent.load(wordsURL: wordsURL, complexityURL: nil, blockEndsURL: fitting, fields: fields)
        #expect(BlockEndStorage.decode(content?.blockEnds).count == 2)
        #expect(BookContent.load(wordsURL: wordsURL, complexityURL: nil, blockEndsURL: tooLong, fields: fields)?.blockEnds == nil)
        #expect(BookContent.load(wordsURL: wordsURL, complexityURL: nil, fields: fields)?.blockEnds == nil)
    }

    @Test func theBookRecordDeclaresBlockEnds() {
        #expect(CloudSyncSchema.BookField.all.contains(CloudSyncSchema.BookField.blockEnds))
    }
}
