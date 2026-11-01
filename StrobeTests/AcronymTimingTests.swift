import Testing
import Foundation
@testable import Strobe

struct AcronymTimingTests {

    private typealias Expectation = (word: String, letters: Int)

    private func expectLetters(_ expectations: [Expectation]) {
        for (word, letters) in expectations {
            #expect(Acronym.letterCount(in: word) == letters, "mismatch for \(word)")
        }
    }

    /// The additional intervals for each word of `text`, split at spaces.
    private func additions(in text: String) -> [Double] {
        let words = text.split(separator: " ").map(String.init)
        return words.indices.map { Acronym.additionalIntervals(at: $0, in: words) }
    }

    // MARK: - Letter names

    @Test func ordinaryWordsAreNotAcronyms() {
        expectLetters([
            ("the", 0),
            ("", 0),
            ("The", 0),
            ("London", 0),
            ("iPhone", 0),
            ("macOS", 0),
            ("McDonald's", 0),
            ("JavaScript", 0),
            ("Mr.", 0),
            ("St.", 0),
            ("don't", 0),
            ("3.14", 0),
            ("1990s", 0),
            ("***", 0),
        ])
    }

    @Test func singleLettersAreNotAcronyms() {
        expectLetters([
            ("I", 0),
            ("A", 0),
            ("J.", 0),
            ("Is", 0),
            ("Ms", 0),
            ("X-ray", 0),
            ("T-shirt", 0),
            ("A-list", 0),
        ])
    }

    @Test func countsEveryLetterOfAnAcronym() {
        expectLetters([
            ("UK", 2),
            ("OK", 2),
            ("FBI", 3),
            ("NASA", 4),
            ("HTTPS", 5),
            ("UNESCO", 6),
        ])
    }

    @Test func periodsAndEdgePunctuationAreSkipped() {
        expectLetters([
            ("U.S.", 2),
            ("U.S.A.", 3),
            ("J.R.R.", 3),
            ("Ph.D.", 3),
            ("FBI.", 3),
            ("(USA),", 3),
            ("\u{201C}FBI\u{201D}", 3),          // “FBI”
            ("'FBI'", 3),
            ("\u{2018}FBI\u{2019}", 3),          // ‘FBI’
            ("FBI\u{2014}", 3),                  // FBI—
        ])
    }

    @Test func mixedCaseCountsWhenCapitalsOutnumberLowercase() {
        expectLetters([
            ("PhD", 3),
            ("iOS", 3),
            ("mRNA", 4),
            ("IPv6", 4),
            ("pH", 0),
            ("kHz", 0),
            ("OpenAI", 0),
            ("WiFi", 0),
        ])
    }

    @Test func pluralAndPossessiveEndingsAreNotLetterNames() {
        expectLetters([
            ("CPUs", 3),
            ("PDFs", 3),
            ("PhDs", 3),
            ("NASA's", 4),
            ("NASA\u{2019}s", 4),
            ("GPUs'", 3),
        ])
    }

    /// A possessive `'S` in capitals can't be told from the one in `IT'S`.
    @Test func capitalAfterApostropheReadsAsAWord() {
        expectLetters([
            ("DON'T", 0),
            ("CAN\u{2019}T", 0),
            ("O'NEILL", 0),
            ("O'Neill", 0),
            ("IT'S", 0),
            ("NASA'S", 0),
        ])
    }

    @Test func digitRunsAndAmpersandsAreLetterNames() {
        expectLetters([
            ("B2B", 3),
            ("G20", 2),
            ("3D", 2),
            ("MP3", 3),
            ("V2.0", 2),
            ("10AM", 3),
            ("AT&T", 4),
            ("R&D", 3),
        ])
    }

    @Test func partsAreJudgedSeparately() {
        expectLetters([
            ("NASA-funded", 4),
            ("non-NATO", 4),
            ("U.S.-based", 2),
            ("TCP/IP", 5),
            ("I/O", 2),
            ("USB-C", 4),
            ("F-16", 2),
            ("COVID-19", 6),
            ("R2-D2", 4),
            ("SARS-CoV-2", 8),
            ("1990-1995", 0),
            ("9-to-5", 0),
            ("e-mail", 0),
            ("Wi-Fi", 0),
            ("Jean-Paul", 0),
        ])
    }

    @Test func longWordsInCapitalsAreNotAcronyms() {
        expectLetters([
            ("CHAPTER", 0),
            ("WARNING:", 0),
            ("MCMXCIX", 0),
            ("NASA-FUNDING", 4),
        ])
    }

    @Test func romanNumeralsCount() {
        expectLetters([
            ("II", 2),
            ("IV", 2),
            ("XIV", 3),
            ("VIII", 4),
            ("WWII", 4),
        ])
    }

    @Test func lowercaseAbbreviationsAreReadWhole() {
        expectLetters([
            ("e.g.", 0),
            ("i.e.", 0),
            ("a.m.", 0),
            ("etc.", 0),
            ("w/o", 0),
        ])
    }

    @Test func greekCyrillicAndLatinExtensionsCountLikeASCII() {
        expectLetters([
            ("\u{421}\u{428}\u{410}", 3),                             // США
            ("\u{397}\u{3A0}\u{391}", 3),                             // ΗΠΑ
            ("\u{41C}\u{43E}\u{441}\u{43A}\u{432}\u{430}", 0),        // Москва
            ("\u{141}KS", 3),                                         // ŁKS
            ("\u{141}\u{F3}d\u{17A}", 0),                             // Łódź
            ("CAF\u{C9}", 4),                                         // CAFÉ
        ])
    }

    @Test func otherScriptsNeverCount() {
        expectLetters([
            ("\u{4E2D}\u{6587}", 0),                                  // 中文
            ("\u{645}\u{631}\u{62D}\u{628}\u{627}", 0),               // مرحبا
            ("\u{13E3}\u{13B3}\u{13A9}", 0),                          // ᏣᎳᎩ
            ("\u{FF2E}\u{FF21}\u{FF33}\u{FF21}", 0),                  // ＮＡＳＡ
        ])
    }

    @Test func detectsWordsWrittenInCapitals() {
        for word in ["STOP", "I", "DON'T", "U.S.A.", "B2B", "COVID-19", "(USA),", "CHAPTER", "\u{421}\u{428}\u{410}"] {
            #expect(Acronym.isWrittenInCapitals(word), "mismatch for \(word)")
        }
        for word in ["Stop", "CPUs", "NASA's", "iOS", "the", "2020", "", "\u{4E2D}\u{6587}"] {
            #expect(!Acronym.isWrittenInCapitals(word), "mismatch for \(word)")
        }
    }

    // MARK: - Additional time

    @Test func eachLetterAfterTheFirstAddsAQuarterInterval() {
        #expect(Acronym.additionalIntervals(at: 0, in: ["the"]) == 0)
        #expect(Acronym.additionalIntervals(at: 0, in: ["I"]) == 0)
        #expect(Acronym.additionalIntervals(at: 0, in: ["UK"]) == 0.25)
        #expect(Acronym.additionalIntervals(at: 0, in: ["FBI"]) == 0.5)
        #expect(Acronym.additionalIntervals(at: 0, in: ["NASA"]) == 0.75)
    }

    @Test func additionalTimeIsCapped() {
        #expect(Acronym.additionalIntervals(at: 0, in: ["HTTPS"]) == 0.75)
        #expect(Acronym.additionalIntervals(at: 0, in: ["UNESCO"]) == 0.75)
        #expect(Acronym.additionalIntervals(at: 0, in: ["SARS-CoV-2"]) == 0.75)
    }

    @Test func positionOutsideTheWordsAddsNothing() {
        #expect(Acronym.additionalIntervals(at: 1, in: ["FBI"]) == 0)
        #expect(Acronym.additionalIntervals(at: -1, in: ["FBI"]) == 0)
        #expect(Acronym.additionalIntervals(at: 0, in: []) == 0)
    }

    // MARK: - Passages in capitals

    @Test func acronymsAmongLowercaseWordsAreTimed() {
        #expect(additions(in: "the FBI and the CIA met at NASA") == [0, 0.5, 0, 0, 0.5, 0, 0, 0.75])
    }

    @Test func pairsInCapitalsAreTimed() {
        #expect(additions(in: "call the REST API now") == [0, 0, 0.75, 0.5, 0])
        #expect(additions(in: "PART II") == [0.75, 0.25])
    }

    @Test func threeWordsInCapitalsAreAPassage() {
        #expect(additions(in: "THE GREAT GATSBY") == [0, 0, 0])
        #expect(additions(in: "he said I AM DEATH and left") == [0, 0, 0, 0, 0, 0, 0])
        #expect(additions(in: "IT WAS A BRIGHT cold day") == [0, 0, 0, 0, 0, 0])
    }

    @Test func punctuationDoesNotSplitAPassage() {
        #expect(additions(in: "ARRIVED SAFELY. LOVE, MOTHER.") == [0, 0, 0, 0])
        #expect(additions(in: "BY F. SCOTT FITZGERALD") == [0, 0, 0, 0])
        #expect(additions(in: "LOSS OF USE, DATA, OR PROFITS;") == [0, 0, 0, 0, 0, 0])
        #expect(additions(in: "III. THE END") == [0, 0, 0])
    }

    @Test func listOfAcronymsIsNotAPassage() {
        #expect(additions(in: "formats: PNG, JPEG, GIF, BMP, and TIFF.") == [0, 0.5, 0.75, 0.5, 0.5, 0, 0.75])
        #expect(additions(in: "the US, UK, EU, and UN") == [0, 0.25, 0.25, 0.25, 0, 0.25])
        #expect(additions(in: "(PNG), (JPEG), (GIF)") == [0.5, 0.75, 0.5])
    }

    @Test func mixedCaseAcronymsNeverJoinAPassage() {
        #expect(additions(in: "NASA's CPUs PhD") == [0.75, 0.5, 0.5])
        #expect(additions(in: "FBI CPUs CIA") == [0.5, 0.5, 0.5])
    }

    // MARK: - Engine timing

    /// 600 WPM gives a 0.1s base interval.
    @MainActor
    private func interval(
        at index: Int = 0,
        in words: [String],
        smartTiming: Bool = false,
        minimumWordLength: Int = 1,
        pauses: Bool = false,
        complexityScore: Float? = nil
    ) -> TimeInterval {
        RSVPEngine(
            words: words,
            currentIndex: index,
            wordsPerMinute: 600,
            smartTimingEnabled: smartTiming,
            sentencePauseEnabled: pauses,
            smartTimingMinimumWordLength: minimumWordLength,
            complexityTimingEnabled: complexityScore != nil,
            complexitySpeedUpIntensity: 1.0,
            complexitySlowDownIntensity: 1.0,
            complexityScores: complexityScore.map { Array(repeating: $0, count: words.count) }
        ).nextInterval()
    }

    @MainActor
    @Test func acronymsStayLongerWithEveryTimingFeatureOff() {
        #expect(abs(interval(in: ["the"]) - 0.1) < 0.0001)
        #expect(abs(interval(in: ["I"]) - 0.1) < 0.0001)
        #expect(abs(interval(in: ["UK"]) - 0.125) < 0.0001)
        #expect(abs(interval(in: ["FBI"]) - 0.15) < 0.0001)
        #expect(abs(interval(in: ["NASA"]) - 0.175) < 0.0001)
        #expect(abs(interval(in: ["UNESCO"]) - 0.175) < 0.0001)
    }

    /// Smart timing counts an acronym's letters as a short word's; the letter
    /// names add their share on top instead of multiplying it.
    @MainActor
    @Test func acronymTimeAddsToSmartTiming() {
        #expect(abs(interval(in: ["FBI"], smartTiming: true) - 0.1 * (1.12 + 0.5)) < 0.0001)
        #expect(abs(interval(in: ["UNESCO"], smartTiming: true) - 0.1 * (1.24 + 0.75)) < 0.0001)
        #expect(abs(interval(in: ["fib"], smartTiming: true) - 0.1 * 1.12) < 0.0001)
    }

    /// The length gate covers only the per-letter slowdown.
    @MainActor
    @Test func minimumWordLengthDoesNotGateAcronymTime() {
        #expect(abs(interval(in: ["FBI"], smartTiming: true, minimumWordLength: 6) - 0.15) < 0.0001)
    }

    @MainActor
    @Test func punctuationPauseScalesTheWholeAcronym() {
        #expect(abs(interval(in: ["FBI."], pauses: true) - 0.1 * 1.5 * 1.5) < 0.0001)
        #expect(abs(interval(in: ["CPU,"], pauses: true) - 0.1 * 1.5 * 1.3) < 0.0001)
        #expect(abs(interval(in: ["FBI."], smartTiming: true, pauses: true) - 0.1 * (1.12 + 0.5) * 1.5) < 0.0001)
    }

    @MainActor
    @Test func complexityScalesTheWholeAcronym() {
        #expect(abs(interval(in: ["FBI"], complexityScore: 1.0) - 0.15 * 1.6) < 0.0001)
        #expect(abs(interval(in: ["FBI"], complexityScore: 0.5) - 0.15) < 0.0001)
    }

    /// A compound's parts and an acronym's letter names are counted apart.
    @MainActor
    @Test func compoundAndAcronymTimeAdd() {
        #expect(abs(interval(in: ["NASA-funded"]) - 0.1 * (1 + 0.5 + 0.75)) < 0.0001)
        #expect(abs(interval(in: ["TCP/IP"]) - 0.1 * (1 + 0.5 + 0.75)) < 0.0001)
        #expect(abs(interval(in: ["USB-C"]) - 0.175) < 0.0001)
    }

    @MainActor
    @Test func passageInCapitalsKeepsTheBaseInterval() {
        let words = ["IN", "NO", "EVENT", "SHALL", "THE", "AUTHORS", "BE", "LIABLE."]
        for index in words.indices {
            #expect(abs(interval(at: index, in: words) - 0.1) < 0.0001, "mismatch for \(words[index])")
        }
    }

    @MainActor
    @Test func engineJudgesTheWordAmongItsNeighbours() {
        let words = ["the", "FBI", "and", "THE", "FBI", "AGENTS"]
        #expect(abs(interval(at: 1, in: words) - 0.15) < 0.0001)
        #expect(abs(interval(at: 4, in: words) - 0.1) < 0.0001)
    }

    @MainActor
    @Test func acronymTimeFollowsThePlaybackSpeed() {
        let engine = RSVPEngine(words: ["FBI"], wordsPerMinute: 300)
        #expect(abs(engine.nextInterval() - 0.3) < 0.0001)
        engine.wpmOverride = 600
        #expect(abs(engine.nextInterval() - 0.15) < 0.0001)
    }
}
