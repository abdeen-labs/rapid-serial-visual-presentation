import Testing
import Foundation
@testable import Strobe

struct SentenceBreakTests {

    private typealias Expectation = (word: String, next: String, breaks: Bool)

    /// Checks each word as the first of a two-word document.
    private func expectBreaks(_ expectations: [Expectation]) {
        for (word, next, breaks) in expectations {
            #expect(SentenceBreak.endsSentence(at: 0, in: [word, next]) == breaks, "mismatch for \(word) \(next)")
        }
    }

    /// The words of `text`, split at spaces, that a blank follows.
    private func wordsBeforeBreaks(in text: String) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        return words.indices.filter { SentenceBreak.endsSentence(at: $0, in: words) }.map { words[$0] }
    }

    // MARK: - Sentence marks

    @Test func sentenceEndsBreakBeforeACapital() {
        expectBreaks([
            ("end.", "The", true),
            ("what?", "She", true),
            ("wow!", "It", true),
            ("what?!", "No", true),
            ("home.\"", "Then", true),
            ("home.\u{201D}", "Then", true),     // home.”
            ("fun!)", "The", true),
            ("end.'", "Then", true),
            ("wait...?", "The", true),
            ("Really?...", "The", true),
            ("OK.", "Fine.", true),
        ])
    }

    @Test func wordsWithoutASentenceEndNeverBreak() {
        expectBreaks([
            ("word", "The", false),
            ("hello,", "The", false),
            ("note:", "The", false),
            ("elements\u{2014}", "The", false),  // elements—
            ("(word)", "The", false),
            ("3.14", "The", false),
            ("", "The", false),
        ])
    }

    /// An ellipsis trails off more often than it ends a sentence, and its
    /// pause already marks it.
    @Test func ellipsisDoesNotBreak() {
        expectBreaks([
            ("wait...", "The", false),
            ("wait\u{2026}", "The", false),      // wait…
            ("wait....", "The", false),
            ("well...,", "The", false),
        ])
    }

    /// A period with a clause mark or dash to its right closes an
    /// abbreviation.
    @Test func periodBeforeAnotherMarkDoesNotBreak() {
        expectBreaks([
            ("etc.,", "The", false),
            ("U.S.\u{2014}", "The", false),      // U.S.—
        ])
    }

    // MARK: - Next word

    @Test func lowercaseNextWordContinuesTheSentence() {
        expectBreaks([
            ("\"Why?\"", "she", false),
            ("\"Stop!\"", "cried", false),
            ("end.", "and", false),
            ("e.g.", "apples", false),
            ("end.", "\u{201C}and", false),      // “and
        ])
    }

    @Test func openingMarksBeforeACapitalStartASentence() {
        expectBreaks([
            ("end.", "\"Why", true),
            ("end.", "\u{201C}Why", true),       // “Why
            ("end.", "(The", true),
            ("end.", "\u{00BF}Qu\u{E9}", true),  // ¿Qué
            ("end.", "\u{2014}", false),         // —
        ])
    }

    /// After a period, a digit is usually a number an abbreviation
    /// introduces; after `?` or `!`, it starts a sentence.
    @Test func digitStartsASentenceOnlyAfterQuestionOrExclamation() {
        expectBreaks([
            ("No.", "5", false),
            ("Vol.", "3", false),
            ("ca.", "1500", false),
            ("approx.", "30", false),
            ("end.", "20", false),
            ("Really?", "20", true),
            ("Wow!", "3", true),
        ])
    }

    // MARK: - Abbreviations

    @Test func initialsDoNotBreak() {
        expectBreaks([
            ("J.", "R.", false),
            ("F.", "Kennedy", false),
            ("\u{C9}.", "Zola", false),         // É.
            ("J.-P.", "Sartre", false),
            ("(B.", "Smith", false),
            ("\u{62F}.", "\u{645}\u{62D}\u{645}\u{62F}", false),  // د. محمد
        ])
    }

    @Test func dottedAbbreviationsDoNotBreak() {
        expectBreaks([
            ("U.S.", "Army", false),
            ("U.S.A.", "Today", false),
            ("e.g.", "Paris", false),
            ("i.e.", "London", false),
            ("a.m.", "Monday", false),
            ("Ph.D.", "Thesis", false),
            ("D.C.", "Heath", false),
            ("non-U.S.", "Firms", false),
            ("\u{442}.\u{435}.", "\u{41E}\u{43D}", false),        // т.е. Он
        ])
    }

    /// Groups longer than three letters, or digits, make a web address, a
    /// file name, or a decimal, which end sentences like any word.
    @Test func webAddressesAndDecimalsStillBreak() {
        expectBreaks([
            ("example.com.", "The", true),
            ("www.bls.gov/oes/tables.htm.", "These", true),
            ("U.S.-based.", "The", true),
        ])
        #expect(SentenceBreak.endsSentence(at: 1, in: ["to", "0.2.", "The"]))
    }

    @Test func titlesAndShortFormsBeforeANameDoNotBreak() {
        expectBreaks([
            ("Mr.", "Smith", false),
            ("Mrs.", "Smith", false),
            ("Ms.", "Aura", false),
            ("Dr.", "Watson", false),
            ("\u{201C}Dr.", "Gabor", false),     // “Dr.
            ("Prof.", "Smith", false),
            ("St.", "Louis", false),
            ("Jr.", "Day", false),
            ("MR.", "AND", false),
            ("Sr.", "Garc\u{ED}a", false),       // Sr. García
            ("Inc.", "CEO", false),
            ("Corp.", "(NLS)", false),
            ("vs.", "Kramer", false),
            ("v.", "Wade", false),
            ("cf.", "Smith", false),
            ("al.", "The", false),
            ("Vol.", "II", false),
            ("Fig.", "A", false),
            ("bzw.", "Katze", false),
        ])
    }

    /// Short forms that often close a sentence, and lowercase words that only
    /// look like a title, still break before a capital.
    @Test func formsThatEndSentencesStillBreak() {
        expectBreaks([
            ("etc.", "The", true),
            ("No.", "I", true),
            ("no.", "We", true),
            ("Hmm.", "I", true),
            ("rep.", "She", true),
            ("ft.", "He", true),
            ("US.", "The", true),
        ])
    }

    /// A number or lowercase letter with a period that follows a sentence end
    /// or colon, or opens the document, is a list label.
    @Test func listLabelsDoNotBreak() {
        #expect(!SentenceBreak.endsSentence(at: 1, in: ["follows:", "1.", "Open"]))
        #expect(!SentenceBreak.endsSentence(at: 1, in: ["box.", "2.", "Remove"]))
        #expect(!SentenceBreak.endsSentence(at: 1, in: ["variables?", "3.", "A"]))
        #expect(!SentenceBreak.endsSentence(at: 1, in: ["done.", "b.", "Next"]))
        #expect(!SentenceBreak.endsSentence(at: 1, in: ["follows:", "1.2.", "Background"]))
        #expect(!SentenceBreak.endsSentence(at: 0, in: ["1.", "Introduction"]))
        #expect(wordsBeforeBreaks(in: "Steps: 1. Open the box. 2. Remove the cover. Then stop.") == ["cover."])
    }

    /// Elsewhere a number or a lone lowercase letter is the sentence's last
    /// word.
    @Test func numbersAndVariablesStillBreak() {
        #expect(SentenceBreak.endsSentence(at: 2, in: ["born", "in", "1985.", "His"]))
        #expect(SentenceBreak.endsSentence(at: 1, in: ["was", "45.", "He"]))
        #expect(SentenceBreak.endsSentence(at: 1, in: ["page", "12.", "The"]))
        #expect(SentenceBreak.endsSentence(at: 1, in: ["Press,", "2014.", "The"]))
        #expect(SentenceBreak.endsSentence(at: 1, in: ["1998),", "38\u{2013}40.", "Museum"]))  // 38–40.
        #expect(SentenceBreak.endsSentence(at: 2, in: ["the", "wage", "w.", "The"]))
        #expect(SentenceBreak.endsSentence(at: 1, in: ["wage,", "w.", "Suppose"]))
    }

    // MARK: - Other scripts

    @Test func chineseAndJapaneseSentenceMarksBreak() {
        expectBreaks([
            ("\u{597D}\u{3002}", "\u{6211}", true),                   // 好。 我
            ("\u{5417}\u{FF1F}", "\u{4ED6}", true),                   // 吗？ 他
            ("\u{554A}\u{FF01}", "\u{6211}", true),                   // 啊！ 我
            ("\u{597D}\u{3002}\u{300D}", "\u{4ED6}", true),           // 好。」 他
            ("\u{5417}\u{FF1F}", "3", true),                          // 吗？ 3
            ("\u{597D}\u{FF0C}", "\u{6211}", false),                  // 好， 我
            ("\u{4EC0}\u{4E48}\u{2026}\u{2026}", "\u{4ED6}", false),  // 什么…… 他
        ])
    }

    /// `と` and `って` tie a quotation to the rest of its sentence.
    @Test func japaneseQuotativeParticleContinuesTheSentence() {
        let question = "\u{5143}\u{6C17}\u{FF1F}\u{300D}"                // 元気？」
        expectBreaks([
            (question, "\u{3068}", false),                            // と
            (question, "\u{3068}\u{3001}", false),                    // と、
            (question, "\u{3063}\u{3066}", false),                    // って
            (question, "\u{3068}\u{3066}\u{3082}", true),             // とても
        ])
    }

    @Test func arabicAndHangulSentenceEndsBreak() {
        expectBreaks([
            ("\u{645}\u{627}\u{630}\u{627}\u{61F}", "\u{642}\u{627}\u{644}", true),       // ماذا؟ قال
            ("\u{645}\u{631}\u{62D}\u{628}\u{627}.", "\u{643}\u{64A}\u{641}", true),      // مرحبا. كيف
            ("\u{6C1}\u{6D2}\u{6D4}", "\u{6CC}\u{6C1}", true),                            // ہے۔ یہ
            ("\u{C548}\u{B155}\u{D558}\u{C138}\u{C694}.", "\u{C800}\u{B294}", true),      // 안녕하세요. 저는
            ("\u{B124}.", "\u{C54C}\u{AC8C}\u{C2B5}\u{B2C8}\u{B2E4}.", true),             // 네. 알겠습니다.
        ])
    }

    // MARK: - Position

    @Test func lastWordNeverBreaks() {
        #expect(!SentenceBreak.endsSentence(at: 1, in: ["The", "end."]))
        #expect(!SentenceBreak.endsSentence(at: 0, in: ["End."]))
        #expect(!SentenceBreak.endsSentence(at: 2, in: ["The", "end."]))
        #expect(!SentenceBreak.endsSentence(at: -1, in: ["The", "end."]))
        #expect(!SentenceBreak.endsSentence(at: 0, in: []))
    }

    @Test func everyBreakIsAlsoASentenceEndPause() {
        let words = """
            Dr. Watson left at 5 p.m. It was late. "Why?" she asked. "Stop!" Tom said. \
            Apples, pears, etc. The rest (see Fig. 2) was fine. No. 5 won. No. It lost... \
            Then 1985. Done.
            """.split(separator: " ").map(String.init)
        for index in words.indices where SentenceBreak.endsSentence(at: index, in: words) {
            #expect(PunctuationMarks.marks(in: words[index]).contains(.sentenceEnd), "mismatch for \(words[index])")
        }
        #expect(wordsBeforeBreaks(in: words.joined(separator: " "))
            == ["late.", "asked.", "\"Stop!\"", "said.", "etc.", "fine.", "won.", "No.", "1985."])
    }

    // MARK: - Engine phase

    /// At 1 WPM the real timer never fires during a test; `advance()` stands
    /// in for each deadline.
    @MainActor
    private func playingEngine(
        _ text: String,
        breaks: Bool = true,
        chapters: [Chapter] = []
    ) -> RSVPEngine {
        let engine = RSVPEngine(
            words: text.split(separator: " ").map(String.init),
            wordsPerMinute: 1,
            sentenceBreakEnabled: breaks,
            chapters: chapters
        )
        engine.play()
        return engine
    }

    @MainActor
    @Test func blankFollowsASentenceEndThenTheNextWordShows() {
        let engine = playingEngine("It ended. Then more words.")
        defer { engine.pause() }
        engine.advance()
        #expect(engine.currentWord == "ended.")
        #expect(!engine.isInSentenceBreak)
        engine.advance() // The sentence's last word has had its time.
        #expect(engine.isInSentenceBreak)
        #expect(engine.currentWord == "ended.")
        #expect(engine.isPlaying)
        engine.advance()
        #expect(!engine.isInSentenceBreak)
        #expect(engine.currentWord == "Then")
        engine.advance()
        #expect(!engine.isInSentenceBreak)
        #expect(engine.currentWord == "more")
    }

    @MainActor
    @Test func noBlankWhenOff() {
        let engine = playingEngine("It ended. Then more.", breaks: false)
        defer { engine.pause() }
        engine.advance()
        engine.advance()
        #expect(!engine.isInSentenceBreak)
        #expect(engine.currentWord == "Then")
    }

    @MainActor
    @Test func noBlankInsideASentence() {
        let engine = playingEngine("Mr. Smith arrived at 5 p.m. Monday.")
        defer { engine.pause() }
        for expected in ["Smith", "arrived", "at", "5", "p.m.", "Monday."] {
            engine.advance()
            #expect(!engine.isInSentenceBreak)
            #expect(engine.currentWord == expected)
        }
    }

    @MainActor
    @Test func noBlankAfterTheLastWord() {
        let engine = playingEngine("The end.")
        engine.advance()
        #expect(engine.isAtEnd)
        engine.advance()
        #expect(!engine.isPlaying)
        #expect(!engine.isInSentenceBreak)
        #expect(engine.currentWord == "end.")
    }

    /// The chapter announcement is a break of its own.
    @MainActor
    @Test func noBlankBeforeAChapterStarts() {
        let chapter = Chapter(title: "Two", wordIndex: 2)
        let engine = playingEngine("It ended. Next chapter.", chapters: [chapter])
        defer { engine.pause() }
        engine.advance()
        engine.advance()
        #expect(!engine.isInSentenceBreak)
        #expect(engine.chapterAnnouncement == chapter)
        #expect(engine.currentWord == "Next")
    }

    @MainActor
    @Test func blankLengthFollowsThePlaybackSpeed() {
        let engine = RSVPEngine(words: ["end.", "The"], wordsPerMinute: 600,
                                sentenceBreakEnabled: true, sentenceBreakLength: 1.5)
        #expect(abs(engine.sentenceBreakInterval() - 0.15) < 0.0001)
        engine.wpmOverride = 300
        #expect(abs(engine.sentenceBreakInterval() - 0.3) < 0.0001)
        engine.sentenceBreakLength = 0.5
        #expect(abs(engine.sentenceBreakInterval() - 0.1) < 0.0001)
        engine.wordsPerMinute = 100
        #expect(abs(engine.sentenceBreakInterval() - 0.1) < 0.0001)
        engine.wpmOverride = nil
        #expect(abs(engine.sentenceBreakInterval() - 0.3) < 0.0001)
        engine.sentenceBreakEnabled = false
        #expect(engine.sentenceBreakInterval() == 0)
    }

    /// There is nothing on screen to read during the blank, so the word's
    /// length, compounds, acronyms, pauses, and complexity don't stretch it.
    @MainActor
    @Test func blankIgnoresTheWordsOwnTiming() {
        let engine = RSVPEngine(
            words: ["NASA-funded.", "The"],
            wordsPerMinute: 600,
            smartTimingEnabled: true,
            sentencePauseEnabled: true,
            sentencePauseMultiplier: 3.0,
            sentenceBreakEnabled: true,
            complexityTimingEnabled: true,
            complexityIntensity: 1.0,
            complexityScores: [1.0, 0.5]
        )
        #expect(engine.nextInterval() > 0.5)
        #expect(abs(engine.sentenceBreakInterval() - 0.1) < 0.0001)
    }

    /// The blank comes on top of the sentence end's pause, which keeps its
    /// meaning: 1.5 intervals on the word, then one blank interval.
    @MainActor
    @Test func blankAddsToTheSentenceEndPause() {
        let withBreak = RSVPEngine(words: ["end.", "The"], wordsPerMinute: 600,
                                   sentencePauseEnabled: true, sentenceBreakEnabled: true)
        let withoutBreak = RSVPEngine(words: ["end.", "The"], wordsPerMinute: 600,
                                      sentencePauseEnabled: true)
        #expect(abs(withBreak.nextInterval() - 0.15) < 0.0001)
        #expect(withBreak.nextInterval() == withoutBreak.nextInterval())
        #expect(abs(withBreak.sentenceBreakInterval() - 0.1) < 0.0001)
        #expect(abs(withBreak.nextInterval() + withBreak.sentenceBreakInterval() - 0.25) < 0.0001)
    }

    /// Resuming shows the sentence's last word again, then its blank.
    @MainActor
    @Test func pauseEndsTheBlankAndResumeShowsTheWordAgain() {
        let engine = playingEngine("It ended. Then more.")
        defer { engine.pause() }
        engine.advance()
        engine.advance()
        #expect(engine.isInSentenceBreak)
        engine.pause() // Space, tap, background, or leaving the reader.
        #expect(!engine.isInSentenceBreak)
        #expect(!engine.isPlaying)
        #expect(engine.currentWord == "ended.")
        engine.advance() // A stale timer callback changes nothing.
        #expect(!engine.isInSentenceBreak)
        #expect(engine.currentWord == "ended.")
        engine.play()
        #expect(!engine.isInSentenceBreak)
        #expect(engine.currentWord == "ended.")
        engine.advance()
        #expect(engine.isInSentenceBreak)
        engine.advance()
        #expect(engine.currentWord == "Then")
    }

    /// Releasing a hold clears the speed override, then pauses.
    @MainActor
    @Test func holdReleaseEndsTheBlank() {
        let engine = playingEngine("It ended. Then more.")
        defer { engine.pause() }
        engine.advance()
        engine.wpmOverride = 600
        engine.advance()
        #expect(engine.isInSentenceBreak)
        engine.wpmOverride = nil
        #expect(engine.isInSentenceBreak)
        engine.pause()
        #expect(!engine.isInSentenceBreak)
        #expect(engine.wpmOverride == nil)
        #expect(engine.currentWord == "ended.")
    }

    @MainActor
    @Test func seekingAndLoadingEndTheBlank() {
        let engine = playingEngine("It ended. Then more.")
        defer { engine.pause() }
        engine.advance()
        engine.advance()
        engine.seek(to: 3)
        #expect(!engine.isInSentenceBreak)
        #expect(!engine.isPlaying)
        #expect(engine.currentIndex == 3)

        engine.seek(to: 0)
        engine.play()
        engine.advance()
        engine.advance()
        engine.scrub(by: -1)
        #expect(!engine.isInSentenceBreak)
        #expect(engine.currentIndex == 0)

        engine.play()
        engine.advance()
        engine.advance()
        engine.load(words: ["New", "book."], currentIndex: 0, complexityScores: nil)
        #expect(!engine.isInSentenceBreak)
        #expect(!engine.isPlaying)
    }

    /// A setting changed mid-blank never skips it or stretches it with the
    /// word's timing; the next deadline shows the next word.
    @MainActor
    @Test func settingChangesDuringTheBlankKeepIt() {
        let engine = playingEngine("It ended. Then more.")
        defer { engine.pause() }
        engine.advance()
        engine.advance()
        engine.wordsPerMinute = 2
        engine.wpmOverride = 900
        engine.smartTimingEnabled = true
        engine.sentencePauseEnabled = true
        engine.sentencePauseMultiplier = 4
        engine.punctuationPauses = PunctuationPauses(clause: 2)
        engine.complexityTimingEnabled = true
        engine.sentenceBreakLength = 3
        #expect(engine.isInSentenceBreak)
        #expect(engine.isPlaying)
        #expect(engine.currentWord == "ended.")
        engine.advance()
        #expect(!engine.isInSentenceBreak)
        #expect(engine.currentWord == "Then")
    }

    /// Turning breaks off mid-blank ends that blank at the next deadline and
    /// starts no new ones.
    @MainActor
    @Test func turningBreaksOffDuringTheBlank() {
        let engine = playingEngine("It ended. Then more. Done.")
        defer { engine.pause() }
        engine.advance()
        engine.advance()
        engine.sentenceBreakEnabled = false
        #expect(engine.sentenceBreakInterval() == 0)
        engine.advance()
        #expect(!engine.isInSentenceBreak)
        #expect(engine.currentWord == "Then")
        engine.advance()
        engine.advance()
        #expect(!engine.isInSentenceBreak)
        #expect(engine.currentWord == "Done.")
    }

    // MARK: - Settings

    @MainActor
    @Test func engineBreakDefaultsMatchTheSettings() {
        let engine = RSVPEngine(words: [])
        #expect(engine.sentenceBreakEnabled == ReaderSettings.Defaults.sentenceBreakEnabled)
        #expect(engine.sentenceBreakLength == ReaderSettings.Defaults.sentenceBreakLength)
    }

    @Test func settingsSnapshotReadsBreakSettings() throws {
        let suiteName = "SentenceBreakTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var snapshot = ReaderSettings.timingSnapshot(from: defaults)
        #expect(snapshot.sentenceBreakEnabled == ReaderSettings.Defaults.sentenceBreakEnabled)
        #expect(snapshot.sentenceBreakLength == ReaderSettings.Defaults.sentenceBreakLength)

        defaults.set(true, forKey: ReaderSettings.Keys.sentenceBreakEnabled)
        defaults.set(2.5, forKey: ReaderSettings.Keys.sentenceBreakLength)
        snapshot = ReaderSettings.timingSnapshot(from: defaults)
        #expect(snapshot.sentenceBreakEnabled)
        #expect(snapshot.sentenceBreakLength == 2.5)
    }
}
