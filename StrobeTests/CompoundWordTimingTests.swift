import Testing
import Foundation
@testable import Strobe

struct CompoundWordTimingTests {

    private typealias Expectation = (word: String, parts: Int)

    private func expectParts(_ expectations: [Expectation]) {
        for (word, parts) in expectations {
            #expect(CompoundWord.partCount(in: word) == parts, "mismatch for \(word)")
        }
    }

    // MARK: - Part counting

    @Test func ordinaryWordsAreOnePart() {
        expectParts([
            ("word", 1),
            ("", 1),
            ("the", 1),
            ("don't", 1),
            ("don\u{2019}t", 1),
            ("characteristically", 1),
            ("3.14", 1),
            ("1,000", 1),
            ("10:30", 1),
            ("***", 1),
        ])
    }

    @Test func countsHyphenatedParts() {
        expectParts([
            ("wedge-shaped", 2),
            ("well-known", 2),
            ("re-enter", 2),
            ("twenty-one", 2),
            ("Jean-Paul", 2),
            ("mother-in-law", 3),
            ("up-to-date", 3),
            ("state-of-the-art", 4),
            ("jack-of-all-trades", 4),
        ])
    }

    @Test func singleCharacterPartsAddNothing() {
        expectParts([
            ("e-mail", 1),
            ("x-ray", 1),
            ("T-shirt", 1),
            ("3-D", 1),
            ("I-I-I", 1),
            ("w-w-what", 1),
            ("one-in-a-lifetime", 3),
            ("9-to-5", 1),
            ("5-year-old", 2),
        ])
    }

    @Test func digitsFormParts() {
        expectParts([
            ("1990-1995", 2),
            ("555-1234", 2),
            ("20-year-old", 3),
            ("COVID-19", 2),
            ("1-800-555-1234", 3),
            ("3-4", 1),
        ])
    }

    @Test func edgePunctuationBelongsToItsPart() {
        expectParts([
            ("well-known,", 2),
            ("(wedge-shaped)", 2),
            ("\u{201C}wedge-shaped.\u{201D}", 2),
            ("state-of-the-art...", 4),
            ("U.S.-based", 2),
            ("mother-in-law's", 3),
        ])
    }

    @Test func apostrophesStayInsideTheirPart() {
        expectParts([
            ("rock-'n'-roll", 2),
            ("rock-\u{2019}n\u{2019}-roll", 2),
            ("will-o'-the-wisp", 3),
            ("don't-care", 2),
        ])
    }

    @Test func edgeJoinersSeparateNothing() {
        expectParts([
            ("-prefix", 1),
            ("suffix-", 1),
            ("-", 1),
            ("-5", 1),
            ("well-known-", 2),
            ("word\u{2013}", 1),
        ])
    }

    @Test func dashesAreNotJoints() {
        expectParts([
            ("--", 1),
            ("well--maybe", 1),
            ("--verbose", 1),
            ("elements\u{2014}stone", 1),
            ("wedge-shaped\u{2014}and", 2),
            ("wedge-shaped--and", 2),
            ("https://example", 1),
        ])
    }

    @Test func otherJoinersCountLikeAHyphen() {
        expectParts([
            ("well\u{2010}known", 2),            // ‐ hyphen
            ("well\u{2011}known", 2),            // non-breaking hyphen
            ("555\u{2012}1234", 2),              // ‒ figure dash
            ("1990\u{2013}1995", 2),             // – en dash
            ("London\u{2013}Paris", 2),
            ("and/or", 2),
            ("input/output", 2),
            ("12/25/2024", 3),
            ("1/2", 1),
            ("w/o", 1),
            ("km/h", 1),
        ])
    }

    @Test func nonLatinLettersFormParts() {
        expectParts([
            ("caf\u{E9}-th\u{E9}\u{E2}tre", 2),
            ("\u{43A}\u{430}\u{43A}\u{43E}\u{439}-\u{442}\u{43E}", 2),      // какой-то
            ("\u{4E2D}\u{6587}", 1),
            ("\u{4E2D}\u{6587}\u{3002}", 1),
            ("\u{645}\u{631}\u{62D}\u{628}\u{627}\u{60C}", 1),              // مرحبا،
        ])
    }

    // MARK: - Additional time

    @Test func eachFurtherPartAddsHalfAnInterval() {
        #expect(CompoundWord.additionalIntervals(for: "the") == 0)
        #expect(CompoundWord.additionalIntervals(for: "e-mail") == 0)
        #expect(CompoundWord.additionalIntervals(for: "wedge-shaped") == 0.5)
        #expect(CompoundWord.additionalIntervals(for: "mother-in-law") == 1.0)
        #expect(CompoundWord.additionalIntervals(for: "state-of-the-art") == 1.5)
    }

    @Test func additionalTimeIsCapped() {
        let chain = Array(repeating: "part", count: 12).joined(separator: "-")
        #expect(CompoundWord.partCount(in: chain) == 12)
        #expect(CompoundWord.additionalIntervals(for: chain) == 1.5)
        #expect(CompoundWord.additionalIntervals(for: "978-3-16-148410-0") == 1.0)
    }

    // MARK: - Engine timing

    /// 600 WPM gives a 0.1s base interval.
    @MainActor
    private func interval(
        for word: String,
        smartTiming: Bool = false,
        minimumWordLength: Int = 1,
        pauses: Bool = false,
        complexityScore: Float? = nil
    ) -> TimeInterval {
        RSVPEngine(
            words: [word],
            wordsPerMinute: 600,
            smartTimingEnabled: smartTiming,
            sentencePauseEnabled: pauses,
            smartTimingMinimumWordLength: minimumWordLength,
            complexityTimingEnabled: complexityScore != nil,
            complexitySpeedUpIntensity: 1.0,
            complexitySlowDownIntensity: 1.0,
            complexityScores: complexityScore.map { [$0] }
        ).nextInterval()
    }

    @MainActor
    @Test func compoundsStayLongerWithEveryTimingFeatureOff() {
        #expect(abs(interval(for: "the") - 0.1) < 0.0001)
        #expect(abs(interval(for: "characteristically") - 0.1) < 0.0001)
        #expect(abs(interval(for: "wedge-shaped") - 0.15) < 0.0001)
        #expect(abs(interval(for: "mother-in-law") - 0.2) < 0.0001)
        #expect(abs(interval(for: "state-of-the-art") - 0.25) < 0.0001)
        #expect(abs(interval(for: "e-mail") - 0.1) < 0.0001)
    }

    /// Smart timing counts the compound's letters once; the further parts add
    /// their share on top instead of multiplying it.
    @MainActor
    @Test func compoundTimeAddsToSmartTiming() {
        #expect(abs(interval(for: "wedge-shaped", smartTiming: true) - 0.1 * (1.48 + 0.5)) < 0.0001)
        #expect(abs(interval(for: "state-of-the-art", smartTiming: true) - 0.1 * (1.64 + 1.5)) < 0.0001)
        #expect(abs(interval(for: "wedgeshaped", smartTiming: true) - 0.1 * 1.44) < 0.0001)
    }

    /// The length gate covers only the per-letter slowdown.
    @MainActor
    @Test func minimumWordLengthDoesNotGateCompoundTime() {
        #expect(abs(interval(for: "up-to", smartTiming: true, minimumWordLength: 12) - 0.15) < 0.0001)
        #expect(abs(interval(for: "wedge-shaped", smartTiming: true, minimumWordLength: 6) - 0.1 * (1.48 + 0.5)) < 0.0001)
    }

    @MainActor
    @Test func punctuationPauseAppliesOnceToTheWholeCompound() {
        #expect(abs(interval(for: "well-known,", pauses: true) - 0.1 * 1.5 * 1.3) < 0.0001)
        #expect(abs(interval(for: "(wedge-shaped).", pauses: true) - 0.1 * 1.5 * 1.5) < 0.0001)
        #expect(abs(interval(for: "well-known", pauses: true) - 0.15) < 0.0001)
        #expect(abs(interval(for: "well-known,", smartTiming: true, pauses: true) - 0.1 * (1.40 + 0.5) * 1.3) < 0.0001)
        #expect(abs(interval(for: "well-known,", smartTiming: true) - 0.1 * (1.40 + 0.2 + 0.5)) < 0.0001)
    }

    /// An internal hyphen joins; a trailing one is a dash and only pauses.
    @MainActor
    @Test func trailingHyphenPausesWithoutCompoundTime() {
        #expect(abs(interval(for: "word-", pauses: true) - 0.14) < 0.0001)
        #expect(abs(interval(for: "word-") - 0.1) < 0.0001)
        #expect(abs(interval(for: "elements\u{2014}stone", pauses: true) - 0.14) < 0.0001)
    }

    @MainActor
    @Test func complexityScalesTheWholeCompound() {
        #expect(abs(interval(for: "wedge-shaped", complexityScore: 1.0) - 0.15 * 1.6) < 0.0001)
        #expect(abs(interval(for: "wedge-shaped", complexityScore: 0.5) - 0.15) < 0.0001)
        #expect(abs(interval(for: "wedge-shaped", smartTiming: true, pauses: true, complexityScore: 1.0)
            - 0.1 * (1.48 + 0.5) * 1.6) < 0.0001)
    }

    @MainActor
    @Test func compoundTimeFollowsThePlaybackSpeed() {
        let engine = RSVPEngine(words: ["wedge-shaped"], wordsPerMinute: 300)
        #expect(abs(engine.nextInterval() - 0.3) < 0.0001)
        engine.wpmOverride = 600
        #expect(abs(engine.nextInterval() - 0.15) < 0.0001)
    }
}
