import Testing
import Foundation
@testable import Strobe

struct ChapterHeadingTests {

    /// Splits `text` at spaces into the words a test reads from.
    private func split(_ text: String) -> [String] {
        text.split(separator: " ").map(String.init)
    }

    /// The words at the start of `text` that repeat `title`.
    private func repeated(_ title: String, in text: String) -> [String] {
        let words = split(text)
        return Array(words.prefix(ChapterHeading.headingLength(of: title, at: 0, in: words)))
    }

    /// Where reading goes on after each chapter in `titles`, keyed by start.
    private func readingStarts(_ titles: [Int: String], in text: String) -> [Int: Int] {
        let chapters = Dictionary(uniqueKeysWithValues: titles.map { ($0.key, Chapter(title: $0.value, wordIndex: $0.key)) })
        return ChapterHeading.readingStarts(for: chapters, in: split(text))
    }

    // MARK: - Matching a title

    @Test func titleSpelledByTheFirstWordsIsRepeated() {
        #expect(repeated("Part One", in: "Part One It began.") == ["Part", "One"])
        #expect(repeated("HOW I LEARNED ABOUT HABITS", in: "HOW I LEARNED ABOUT HABITS Attending Denison was")
            == ["HOW", "I", "LEARNED", "ABOUT", "HABITS"])
        #expect(repeated("Problem #1: Winners and losers have the same goals.",
                         in: "Problem #1: Winners and losers have the same goals. Goal setting suffers")
            == split("Problem #1: Winners and losers have the same goals."))
        #expect(repeated("Copyright", in: "AN IMPRINT OF PENGUIN RANDOM HOUSE").isEmpty)
    }

    @Test func caseDiacriticsQuotesAndPunctuationAreSetAside() {
        #expect(repeated("The Man Who Didn’t Look Right", in: "THE MAN WHO DIDN'T LOOK RIGHT The psychologist")
            == split("THE MAN WHO DIDN'T LOOK RIGHT"))
        #expect(repeated("Café Society", in: "CAFE SOCIETY It was late.") == ["CAFE", "SOCIETY"])
        #expect(repeated("Cafe Society", in: "Café Society It was late.") == ["Café", "Society"])
        #expect(repeated("“Margin of Error” and Significance",
                         in: "\"Margin of Error\" and Significance The intercept")
            == split("\"Margin of Error\" and Significance"))
        #expect(repeated("Section & Detail", in: "Section& Detail Body text.") == ["Section&", "Detail"])
        #expect(repeated("Effective Tools", in: "Eﬀective Tools Connect is") == ["Eﬀective", "Tools"])
    }

    /// Current and earlier tokenizers split dashes and join units differently.
    @Test func howTheTokenizerSplitTheHeadingDoesNotMatter() {
        #expect(repeated("Part One—The Beginning", in: "Part One— The Beginning Once upon")
            == ["Part", "One—", "The", "Beginning"])
        #expect(repeated("Part One—The Beginning", in: "Part One—The Beginning Once upon")
            == ["Part", "One—The", "Beginning"])
        #expect(repeated("Self-Control", in: "Selfcontrol Matters.") == ["Selfcontrol"])
        #expect(repeated("Self-Control", in: "Self- Control Matters.") == ["Self-", "Control"])

        let title = "The Ides of March, 44 BC"
        let joined = ["The", "Ides", "of", "March,", "44 BC", "Caesar", "died."]
        let apart = ["The", "Ides", "of", "March,", "44", "BC", "Caesar", "died."]
        #expect(ChapterHeading.headingLength(of: title, at: 0, in: joined) == 5)
        #expect(ChapterHeading.headingLength(of: title, at: 0, in: apart) == 6)
        let tokenized = Tokenizer.tokenize("\(title)\nCaesar died.")
        #expect(ChapterHeading.headingLength(of: title, at: 0, in: tokenized) == Tokenizer.tokenize(title).count)
    }

    @Test func aMatchEndsWhereAWordEnds() {
        #expect(repeated("Part One", in: "Part Oneness is a feeling.").isEmpty)
        #expect(repeated("The Beginning of Everything", in: "The Beginning Once upon a time").isEmpty)
        #expect(ChapterHeading.headingLength(of: "Chapter 3", at: 0, in: ["Chapter", "3 AD", "79", "was"]) == 0)
    }

    @Test func ornamentsAreNotLetters() {
        #expect(repeated("❦ The Beginning ❦", in: "The Beginning Once upon") == ["The", "Beginning"])
        #expect(repeated("The Beginning", in: "❦ The Beginning Once upon") == ["❦", "The", "Beginning"])
        #expect(repeated("* * *", in: "* * * Once upon").isEmpty)
    }

    @Test func cjkHeadingsMatchAcrossTheirSegments() {
        for (heading, body) in [("第一章 开始", "我们从这里出发。"), ("第三章 はじまり", "物語はここから始まる。")] {
            let words = Tokenizer.tokenize("\(heading)\n\(body)")
            let headingWords = Tokenizer.tokenize(heading).count
            #expect(ChapterHeading.headingLength(of: heading, at: 0, in: words) == headingWords, "\(heading)")
            let unnumbered = String(heading.split(separator: " ")[1])
            #expect(ChapterHeading.headingLength(of: unnumbered, at: 0, in: words) == headingWords, "\(unnumbered)")
        }
        let words = Tokenizer.tokenize("第1章\n我们从这里出发。")
        #expect(ChapterHeading.headingLength(of: "第一章", at: 0, in: words) == Tokenizer.tokenize("第1章").count)
    }

    @Test func headingsInScriptsWithoutCase() {
        #expect(repeated("الفصل الأول", in: "الفصل الأول كان يا ما كان") == ["الفصل", "الأول"])
    }

    // MARK: - Numbers and labels

    @Test func aNumberOrLabelOnlyOneSideHasIsSetAside() {
        #expect(repeated("1: The Surprising Power of Atomic Habits",
                         in: "The Surprising Power of Atomic Habits THE FATE OF British")
            == split("The Surprising Power of Atomic Habits"))
        #expect(repeated("The Beginning", in: "Chapter 1 The Beginning Once upon") == split("Chapter 1 The Beginning"))
        #expect(repeated("The Beginning", in: "CHAPTER ONE The Beginning Once upon") == split("CHAPTER ONE The Beginning"))
        #expect(repeated("The Beginning", in: "IV. The Beginning Once upon") == split("IV. The Beginning"))
        #expect(repeated("The Beginning", in: "XII The Beginning Once upon") == split("XII The Beginning"))
        #expect(repeated("The Beginning", in: "1-1 The Beginning Once upon") == split("1-1 The Beginning"))
        #expect(repeated("The Storm", in: "PROLOGUE The Storm Rain fell.") == split("PROLOGUE The Storm"))
        #expect(repeated("Prologue: The Storm", in: "The Storm Rain fell.") == split("The Storm"))
        #expect(repeated("Preface", in: "Page vi Preface The original motivation") == split("Page vi Preface"))
    }

    @Test func numbersOnBothSidesMustAgree() {
        #expect(repeated("1. The Beginning", in: "Chapter One: The Beginning Once upon")
            == split("Chapter One: The Beginning"))
        #expect(repeated("Part II: The Long Road", in: "PART TWO The Long Road It was")
            == split("PART TWO The Long Road"))
        #expect(repeated("Chapter Twenty-One: Home", in: "CHAPTER 21 Home We arrived") == split("CHAPTER 21 Home"))
        #expect(repeated("Chapter Twenty One: Home", in: "CHAPTER XXI Home We arrived") == split("CHAPTER XXI Home"))
        #expect(repeated("6. Monopsony", in: "4-9 Monopsony Up to this point").isEmpty)
        #expect(repeated("Part 1: Beginnings", in: "Chapter 1 Beginnings It was").isEmpty)
    }

    /// The heading's number with its label, or a label alone, is covered by a
    /// title that is only that or opens with the same label; what follows plays.
    @Test func aLabeledNumberCoversTheHeadingsOwn() {
        #expect(repeated("Chapter 1", in: "CHAPTER 1 The Beginning Once upon") == ["CHAPTER", "1"])
        #expect(repeated("Chapter One", in: "CHAPTER 1 The Beginning Once upon") == ["CHAPTER", "1"])
        #expect(repeated("III.", in: "Part III Beginnings It was") == ["Part", "III"])
        #expect(repeated("Chapter 1: The Storm", in: "Chapter One A Different Name Once") == ["Chapter", "One"])
        #expect(repeated("Appendix A: Methods", in: "Appendix A Data Sources The data") == ["Appendix", "A"])
        #expect(repeated("Prologue: The Storm", in: "PROLOGUE Rain fell on the town.") == ["PROLOGUE"])
    }

    /// Bare numbers at a page's top are list items, notes, and years more
    /// often than chapter numbers.
    @Test func bareNumbersInTheTextAreNotChapterNumbers() {
        #expect(repeated("Chapter 2: Labor Supply", in: "2. A variable indicating whether").isEmpty)
        #expect(repeated("Chapter 1: Introduction", in: "1. Isoprofit curves are upward").isEmpty)
        #expect(repeated("Notes", in: "2018 Notes In this section").isEmpty)
        #expect(repeated("Chapter 1", in: "Page 1 The Beginning Once").isEmpty)
    }

    /// Text that opens with the title's words but reads on as a sentence is
    /// left to play.
    @Test func wordsThatReadOnAsASentenceNeverMatch() {
        #expect(repeated("Evidence", in: "Evidence from the 1990s suggests").isEmpty)
        #expect(repeated("The Two-Minute Rule", in: "The Two-Minute Rule can seem like a trick").isEmpty)
        #expect(repeated("The Long Run", in: "the long run. However, firms adjust").isEmpty)
        #expect(repeated("Summary", in: "A summary of the results").isEmpty)
        #expect(repeated("The Beginning", in: "1 The Beginning of the war was").isEmpty)
        #expect(repeated("Evidence", in: "Evidence “from” the 1990s").isEmpty)
        #expect(repeated("iPhone Basics", in: "iPhone Basics The home screen") == ["iPhone", "Basics"])
        #expect(repeated("Summary", in: "Summary 2-1. 2-2. It is costly") == ["Summary"])
    }

    // MARK: - Where reading goes on

    @Test func consecutiveChaptersEachKeepTheirAnnouncement() {
        #expect(readingStarts([0: "Part One", 2: "Chapter 1"], in: "Part One Chapter 1 Rain fell.") == [0: 2, 2: 4])
    }

    @Test func aChapterWhoseHeadingTheTitleShowedIsPassedOver() {
        #expect(readingStarts([0: "Introduction: My Story", 1: "My Story"], in: "Introduction My Story On the final day")
            == [0: 3, 1: 3])
        #expect(readingStarts([0: "Part One: Beginnings", 2: "Map"], in: "Part One Beginnings Once upon a time")
            == [0: 2])
    }

    @Test func aHeadingThatRunsToTheEndIsLeftToPlay() {
        #expect(readingStarts([2: "The End"], in: "It ended. The End").isEmpty)
        #expect(readingStarts([2: "The End"], in: "It ended. The End Fin.") == [2: 4])
    }

    // MARK: - From import

    /// Heading chapters as `EPUBTextExtractor` builds them.
    private func epubWordsAndHeadingChapters(_ html: String) -> (words: [String], chapters: [Int: Chapter]) {
        let content = EPUBContent.parse(Data(html.utf8))
        let cleaned = TextCleaner.cleanPages([content.text], level: .standard, preserveOffsets: true)[0]
        var words: [String] = []
        var carry: String?
        let positions = content.appendWords(cleanedText: cleaned, into: &words, carry: &carry)
        if let carry { words.append(carry) }
        let chapters = content.headings.compactMap { heading in
            positions[heading.offset].map { Chapter(title: heading.title, wordIndex: $0) }
        }
        return (words, Dictionary(chapters.map { ($0.wordIndex, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    @Test func epubHeadingsAreSkippedAfterTheirAnnouncement() {
        let book = epubWordsAndHeadingChapters("""
            <body><h1>Part One</h1>
            <h2>Chapter 1: The <em>Storm</em></h2>
            <p>Rain fell on the town.</p>
            <h2>Chapter 3</h2>
            <p>AD 79 was the year.</p>
            <h2><span>❦</span> The Last</h2>
            <p>It ended.</p></body>
            """)
        let starts = ChapterHeading.readingStarts(for: book.chapters, in: book.words)
        let resumed = book.chapters.keys.sorted().map { book.words[starts[$0] ?? $0] }
        #expect(resumed == ["Chapter", "Rain", "AD 79", "It"])
    }

    /// A table of contents entry that numbers a chapter whose number is its
    /// own heading element, which import drops as a page number.
    @Test func epubTableOfContentsTitleWithTheNumberDroppedAtImport() {
        let book = epubWordsAndHeadingChapters("""
            <body>
            <h2>1</h2>
            <h2>The Surprising Power</h2>
            <p>THE FATE OF British Cycling changed.</p></body>
            """)
        let entry = Chapter(title: "1: The Surprising Power", wordIndex: 0)
        let starts = ChapterHeading.readingStarts(for: [0: entry], in: book.words)
        #expect(book.words[starts[0] ?? 0] == "THE")
    }

    @Test func epubCJKHeadingIsSkipped() {
        let book = epubWordsAndHeadingChapters("<body><h1>第一章 开始</h1>\n<p>我们从这里出发。</p></body>")
        let starts = ChapterHeading.readingStarts(for: book.chapters, in: book.words)
        #expect(starts[0] == Tokenizer.tokenize("第一章 开始").count)
    }

    /// Outline chapters start on a page's first word, as `PDFTextExtractor`
    /// maps them, after the running header is cleaned away.
    @Test func pdfOutlineChaptersSkipAHeadingAtTheTopOfThePage() {
        let pages = [
            "LABOR ECONOMICS\nThe last chapter ends here.\nIts final line.",
            "LABOR ECONOMICS\nCHAPTER 1\nThe Beginning\nOnce upon a time there was a market.",
            "LABOR ECONOMICS\nwages fell, and firms hired.\nSummary\nWe saw how markets work.",
            "LABOR ECONOMICS\nKey Concepts\nFirst concept here.\nSecond concept here.",
        ]
        var words: [String] = []
        var carry: String?
        var pageStarts: [Int] = []
        for page in TextCleaner.cleanPages(pages, level: .standard) {
            pageStarts.append(words.count)
            Tokenizer.appendTokenizedText(page, into: &words, carry: &carry)
        }
        if let carry { words.append(carry) }
        let outline = [(1, "Chapter 1: The Beginning"), (2, "Summary"), (3, "Key Concepts")]
        let chapters = Dictionary(uniqueKeysWithValues: outline.map { page, title in
            (pageStarts[page], Chapter(title: title, wordIndex: pageStarts[page]))
        })
        let starts = ChapterHeading.readingStarts(for: chapters, in: words)
        #expect(words[starts[pageStarts[1]] ?? pageStarts[1]] == "Once")
        #expect(starts[pageStarts[2]] == nil)
        #expect(words[starts[pageStarts[3]] ?? pageStarts[3]] == "First")
    }

    // MARK: - Playback

    /// At 1 WPM the real timer never fires during a test; `advance()` stands
    /// in for each deadline.
    @MainActor
    private func playingEngine(
        _ text: String,
        chapters: [Int: String],
        from index: Int = 0,
        breaks: Bool = false
    ) -> RSVPEngine {
        let engine = RSVPEngine(
            words: split(text),
            currentIndex: index,
            wordsPerMinute: 1,
            sentenceBreakEnabled: breaks,
            chapters: chapters.map { Chapter(title: $0.value, wordIndex: $0.key) }
        )
        engine.play()
        return engine
    }

    /// Advances through an announcement's title and fade.
    @MainActor
    private func finishAnnouncement(_ engine: RSVPEngine) {
        engine.advance()
        engine.advance()
    }

    @MainActor
    @Test func playbackGoesOnAfterTheHeadingTheTitleShowed() {
        let engine = playingEngine("It ended. Chapter 1 The Storm Rain fell.", chapters: [2: "Chapter 1: The Storm"])
        defer { engine.pause() }
        engine.advance()
        engine.advance()
        #expect(engine.chapterAnnouncement?.title == "Chapter 1: The Storm")
        #expect(engine.currentIndex == 2)
        engine.advance()
        #expect(!engine.isChapterTitleVisible)
        #expect(engine.currentIndex == 2)
        engine.advance()
        #expect(engine.chapterAnnouncement == nil)
        #expect(engine.currentWord == "Rain")
        #expect(engine.isPlaying)
        #expect(engine.progress == 6.0 / 7.0)
        engine.advance()
        #expect(engine.currentWord == "fell.")
    }

    @MainActor
    @Test func consecutiveChaptersAreAnnouncedInTurn() {
        let engine = playingEngine("Part One Chapter 1 Rain fell.", chapters: [0: "Part One", 2: "Chapter 1"])
        defer { engine.pause() }
        #expect(engine.chapterAnnouncement?.title == "Part One")
        finishAnnouncement(engine)
        #expect(engine.chapterAnnouncement?.title == "Chapter 1")
        #expect(engine.isChapterTitleVisible)
        #expect(engine.currentIndex == 2)
        finishAnnouncement(engine)
        #expect(engine.chapterAnnouncement == nil)
        #expect(engine.currentWord == "Rain")
    }

    @MainActor
    @Test func aChapterTheTitleCoveredIsNotAnnouncedAgain() {
        let engine = playingEngine(
            "Introduction My Story On the final day",
            chapters: [0: "Introduction: My Story", 1: "My Story"]
        )
        defer { engine.pause() }
        finishAnnouncement(engine)
        #expect(engine.chapterAnnouncement == nil)
        #expect(engine.currentWord == "On")

        engine.seek(to: 1)
        engine.play()
        #expect(engine.chapterAnnouncement?.title == "My Story")
        finishAnnouncement(engine)
        #expect(engine.currentWord == "On")
    }

    @MainActor
    @Test func aHeadingThatEndsTheDocumentStillPlays() {
        let engine = playingEngine("It ended. The End", chapters: [2: "The End"], from: 1)
        engine.advance()
        #expect(engine.chapterAnnouncement?.title == "The End")
        finishAnnouncement(engine)
        #expect(engine.currentWord == "The")
        engine.advance()
        #expect(engine.currentWord == "End")
        engine.advance()
        #expect(!engine.isPlaying)
    }

    /// Hold release, Space, a scene change, or leaving the reader: the title
    /// has shown, so the heading isn't read again, and nothing is announced
    /// twice.
    @MainActor
    @Test(arguments: [false, true])
    func pausingDuringAnAnnouncementLeavesThePositionAfterTheHeading(duringFade: Bool) {
        let engine = playingEngine("Chapter 1 The Storm Rain fell.", chapters: [0: "Chapter 1: The Storm"])
        defer { engine.pause() }
        if duringFade { engine.advance() }
        engine.pause()
        #expect(engine.chapterAnnouncement == nil)
        #expect(engine.currentWord == "Rain")
        engine.advance()
        #expect(engine.currentWord == "Rain")
        engine.play()
        #expect(engine.chapterAnnouncement == nil)
        #expect(engine.currentWord == "Rain")
        engine.advance()
        #expect(engine.currentWord == "fell.")
    }

    @MainActor
    @Test func pausingDuringTheFirstOfTwoAnnouncementsAnnouncesTheSecondOnResume() {
        let engine = playingEngine("Part One Chapter 1 Rain fell.", chapters: [0: "Part One", 2: "Chapter 1"])
        defer { engine.pause() }
        engine.pause()
        #expect(engine.currentWord == "Chapter")
        engine.play()
        #expect(engine.chapterAnnouncement?.title == "Chapter 1")
        finishAnnouncement(engine)
        #expect(engine.currentWord == "Rain")
    }

    /// A chapter jump shows the heading's first word until play announces it.
    @MainActor
    @Test func seekingToAChapterStartAnnouncesItAgain() {
        let engine = playingEngine("Chapter 1 The Storm Rain fell. More words.", chapters: [0: "Chapter 1: The Storm"])
        defer { engine.pause() }
        engine.seek(to: 6)
        #expect(engine.chapterAnnouncement == nil)
        #expect(engine.currentIndex == 6)
        engine.seek(to: 0)
        #expect(engine.currentWord == "Chapter")
        engine.play()
        #expect(engine.chapterAnnouncement?.title == "Chapter 1: The Storm")
        finishAnnouncement(engine)
        #expect(engine.currentWord == "Rain")
    }

    @MainActor
    @Test func noBlankAroundASkippedHeading() {
        let engine = playingEngine(
            "It ended. Problem #1: Winners lose. Goal setting fails. Then more.",
            chapters: [2: "Problem #1: Winners lose."],
            breaks: true
        )
        defer { engine.pause() }
        engine.advance()
        engine.advance()
        #expect(!engine.isInSentenceBreak)
        #expect(engine.chapterAnnouncement != nil)
        finishAnnouncement(engine)
        #expect(!engine.isInSentenceBreak)
        #expect(engine.currentWord == "Goal")
        engine.advance()
        engine.advance()
        #expect(engine.currentWord == "fails.")
        engine.advance()
        #expect(engine.isInSentenceBreak)
        engine.advance()
        #expect(engine.currentWord == "Then")
    }

    @MainActor
    @Test func loadingFindsWhereEachChapterGoesOn() {
        let engine = RSVPEngine(words: [])
        engine.load(
            words: split("Chapter 1 The Storm Rain fell."),
            currentIndex: 0,
            complexityScores: nil,
            chapters: [Chapter(title: "Chapter 1: The Storm", wordIndex: 0), Chapter(title: "Aside", wordIndex: 4)]
        )
        #expect(engine.readingStart(ofChapterAt: 0) == 4)
        #expect(engine.readingStart(ofChapterAt: 4) == 4)
        #expect(engine.readingStart(ofChapterAt: 2) == 2)
    }
}
