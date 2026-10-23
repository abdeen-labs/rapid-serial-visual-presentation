import Testing
import Foundation
@testable import Strobe

struct KokoroWordTimingTests {

    // MARK: - Helpers

    /// Seconds in `frames` acoustic frames of Kokoro's 24 kHz audio.
    private func seconds(_ frames: Int) -> TimeInterval {
        Double(frames * KokoroWordTiming.samplesPerFrame) / 24_000
    }

    /// Durations of one frame per token, with `bos` and `eos` frames at the
    /// ends, for `line`.
    private func evenDurations(for line: KokoroPhonemeLine, bos: Int32 = 1, eos: Int32 = 1) -> [Int32] {
        [bos] + [Int32](repeating: 1, count: line.length) + [eos]
    }

    private func audioDuration(_ durations: [Int32]) -> TimeInterval {
        seconds(durations.reduce(0) { $0 + Int($1) })
    }

    private func isClose(_ times: [TimeInterval?], _ expected: [TimeInterval?], within tolerance: Double = 1e-9) -> Bool {
        times.count == expected.count && zip(times, expected).allSatisfy { time, want in
            switch (time, want) {
            case (nil, nil): true
            case let (time?, want?): abs(time - want) <= tolerance
            default: false
            }
        }
    }

    // MARK: - The line

    @Test func joinsWordsWithSingleSpaces() {
        let line = KokoroPhonemeLine(wordPhonemes: ["həlˈO", "wˈɜɹld!"])
        #expect(line.text == "həlˈO wˈɜɹld!")
        #expect(line.length == 13)
        #expect(line.wordSpans == [0..<5, 6..<13])
    }

    @Test func wordsWithoutPhonemesAddNothing() {
        let line = KokoroPhonemeLine(wordPhonemes: ["", "ˈæn", "", "ðə"])
        #expect(line.text == "ˈæn ðə")
        #expect(line.wordSpans == [nil, 0..<3, nil, 4..<6])
    }

    @Test func countsScalarsNotCharacters() {
        // A nasal vowel with a combining tilde is two scalars, as the model counts it.
        let line = KokoroPhonemeLine(wordPhonemes: ["ɑ\u{0303}", "ba"])
        #expect(line.length == 5)
        #expect(line.wordSpans == [0..<2, 3..<5])
    }

    @Test func numberUnitIsOneWordWithItsSpaces() {
        let line = KokoroPhonemeLine(wordPhonemes: ["tˈu θˈWzənd bˌisˌiˈi", "ɪz"])
        #expect(line.wordSpans == [0..<20, 21..<23])
    }

    // MARK: - Cleaning

    @Test func dropsSymbolsTheVocabularyLacks() {
        let cleaned = KokoroPhonemeLine.cleaned("hə#lˈO") { $0 != "#" }
        #expect(cleaned == "həlˈO")
    }

    @Test func collapsesSpaces() {
        let cleaned = KokoroPhonemeLine.cleaned("  tˈu   θˈWzənd ") { _ in true }
        #expect(cleaned == "tˈu θˈWzənd")
    }

    @Test func joinsLeadingPunctuationToTheWord() {
        #expect(KokoroPhonemeLine.cleaned("“ həlˈO,") { _ in true } == "“həlˈO,")
        #expect(KokoroPhonemeLine.cleaned("( “ wˈʌn") { _ in true } == "(“wˈʌn")
    }

    @Test func keepsPunctuationAlone() {
        #expect(KokoroPhonemeLine.cleaned("…") { _ in true } == "…")
    }

    @Test func dropsGroupsLeftEmpty() {
        #expect(KokoroPhonemeLine.cleaned("## ˈæn") { $0 != "#" } == "ˈæn")
        #expect(KokoroPhonemeLine.cleaned("##") { $0 != "#" } == "")
    }

    // MARK: - Parts

    @Test func oneLineThatFitsIsOnePart() {
        #expect(KokoroPhonemeLine.parts(for: ["ab", "cd", "ef"], limit: 8) == [0..<3])
    }

    @Test func splitsAtWordsBeforeTheLimit() {
        // "ab cd" is 5 scalars, "ab cd ef" 8.
        #expect(KokoroPhonemeLine.parts(for: ["ab", "cd", "ef"], limit: 7) == [0..<2, 2..<3])
        #expect(KokoroPhonemeLine.parts(for: ["ab", "cd", "ef"], limit: 5) == [0..<2, 2..<3])
        #expect(KokoroPhonemeLine.parts(for: ["ab", "cd", "ef"], limit: 4) == [0..<1, 1..<2, 2..<3])
    }

    @Test func wordTooLongAloneIsItsOwnPart() {
        #expect(KokoroPhonemeLine.parts(for: ["ab", "cdefgh", "ij"], limit: 4) == [0..<1, 1..<2, 2..<3])
    }

    @Test func wordsWithoutPhonemesStayInTheirPart() {
        #expect(KokoroPhonemeLine.parts(for: ["", "ab", "", "cd", ""], limit: 3) == [0..<3, 3..<5])
        #expect(KokoroPhonemeLine.parts(for: ["", ""], limit: 3) == [0..<2])
        #expect(KokoroPhonemeLine.parts(for: [], limit: 3).isEmpty)
    }

    @Test func partsNeverPassTheLimit() {
        let words = (0..<200).map { String(repeating: "a", count: 1 + $0 % 9) }
        let parts = KokoroPhonemeLine.parts(for: words, limit: 50)
        #expect(parts.first?.lowerBound == 0)
        #expect(parts.last?.upperBound == words.count)
        for (part, next) in zip(parts, parts.dropFirst()) {
            #expect(part.upperBound == next.lowerBound)
        }
        for part in parts {
            #expect(KokoroPhonemeLine(wordPhonemes: Array(words[part])).length <= 50)
        }
    }

    @Test func truncatesAtTheLastWholeGroup() {
        #expect(KokoroPhonemeLine.truncated("abc def ghi", toLength: 9) == "abc def")
        #expect(KokoroPhonemeLine.truncated("abc def ghi", toLength: 7) == "abc def")
        #expect(KokoroPhonemeLine.truncated("abcdefghi", toLength: 4) == "abcd")
        #expect(KokoroPhonemeLine.truncated("abc", toLength: 4) == "abc")
    }

    // MARK: - Word starts

    @Test func wordStartsWithTheSpaceBeforeIt() {
        let line = KokoroPhonemeLine(wordPhonemes: ["ab", "cd", "ef"])
        // BOS lasts 4 frames, then a b ␠ c d ␠ e f, then EOS.
        let durations: [Int32] = [4, 2, 3, 5, 1, 2, 6, 2, 2, 7]
        let result = KokoroWordTiming.startTimes(for: line, durations: durations, audioDuration: audioDuration(durations))
        #expect(result.isExact)
        #expect(isClose(result.startTimes, [seconds(4), seconds(4 + 2 + 3), seconds(4 + 2 + 3 + 5 + 1 + 2)]))
    }

    @Test func pauseBeforeAWordIsNotPartOfIt() {
        // The comma after "ab," lasts 6 frames; "cd" starts with the space after it.
        let line = KokoroPhonemeLine(wordPhonemes: ["ab,", "cd"])
        let durations: [Int32] = [3, 2, 2, 6, 4, 2, 2, 5]
        let result = KokoroWordTiming.startTimes(for: line, durations: durations, audioDuration: audioDuration(durations))
        #expect(isClose(result.startTimes, [seconds(3), seconds(3 + 2 + 2 + 6)]))
    }

    @Test func firstWordPassesItsLeadingPunctuation() {
        let line = KokoroPhonemeLine(wordPhonemes: ["“ab", "(cd"])
        // BOS, “ a b ␠ ( c d, EOS
        let durations: [Int32] = [2, 3, 1, 1, 4, 2, 1, 1, 2]
        let result = KokoroWordTiming.startTimes(for: line, durations: durations, audioDuration: audioDuration(durations))
        #expect(isClose(result.startTimes, [seconds(2 + 3), seconds(2 + 3 + 1 + 1)]))
    }

    @Test func stressMarkStartsTheWord() {
        let line = KokoroPhonemeLine(wordPhonemes: ["ˈɛnd."])
        let durations = evenDurations(for: line, bos: 5)
        let result = KokoroWordTiming.startTimes(for: line, durations: durations, audioDuration: audioDuration(durations))
        #expect(isClose(result.startTimes, [seconds(5)]))
    }

    @Test func wordOfPunctuationAloneStartsAtItsToken() {
        let line = KokoroPhonemeLine(wordPhonemes: ["ab", "…", "cd"])
        let durations = evenDurations(for: line, bos: 2)
        let result = KokoroWordTiming.startTimes(for: line, durations: durations, audioDuration: audioDuration(durations))
        #expect(isClose(result.startTimes, [seconds(2), seconds(2 + 2), seconds(2 + 4)]))
    }

    @Test func wordsWithoutPhonemesHaveNoStart() {
        let line = KokoroPhonemeLine(wordPhonemes: ["ab", "", "cd"])
        let durations = evenDurations(for: line, bos: 2)
        let result = KokoroWordTiming.startTimes(for: line, durations: durations, audioDuration: audioDuration(durations))
        #expect(isClose(result.startTimes, [seconds(2), nil, seconds(2 + 2)]))
    }

    @Test func framesDivideTheAudioEvenly() {
        // However long the audio, each frame is the same share of it.
        let line = KokoroPhonemeLine(wordPhonemes: ["ab", "cd"])
        let durations: [Int32] = [5, 1, 1, 3, 1, 1, 9]
        let result = KokoroWordTiming.startTimes(for: line, durations: durations, audioDuration: 2.1)
        #expect(isClose(result.startTimes, [2.1 * 5 / 21, 2.1 * 7 / 21]))
    }

    @Test func startTimesNeverDecrease() {
        let words = ["ðə", "kwˈIət", "", "“ɹˈɪvəɹ,", "ɹˈæn", "…", "ˈɔn."]
        let line = KokoroPhonemeLine(wordPhonemes: words)
        let durations = [Int32(3)] + (0..<line.length).map { Int32(1 + $0 % 4) } + [Int32(6)]
        let result = KokoroWordTiming.startTimes(for: line, durations: durations, audioDuration: audioDuration(durations))
        let times = result.startTimes.compactMap { $0 }
        #expect(times.count == 6)
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
    }

    // MARK: - The first word

    /// Loudness frames of 10 ms: quiet, then loud from `onset` on.
    private func loudness(onset: Int, count: Int = 60) -> [Float] {
        (0..<count).map { $0 >= onset ? 0.3 : 0.0001 }
    }

    @Test func firstWordStartsWhereItIsFirstHeard() {
        let start = KokoroWordTiming.firstWordStart(0.3, loudness: loudness(onset: 20), frameDuration: 0.01)
        #expect(abs(start - 0.2) < 1e-9)
    }

    @Test func firstWordKeepsItsStartWithoutEarlierSound() {
        #expect(KokoroWordTiming.firstWordStart(0.3, loudness: loudness(onset: 35), frameDuration: 0.01) == 0.3)
        #expect(KokoroWordTiming.firstWordStart(0.3, loudness: loudness(onset: 30), frameDuration: 0.01) == 0.3)
    }

    @Test func firstWordIgnoresSoundTooFarBefore() {
        // Heard from 50 ms, more than the window before 300 ms.
        #expect(KokoroWordTiming.firstWordStart(0.3, loudness: loudness(onset: 5), frameDuration: 0.01) == 0.3)
    }

    @Test func firstWordStartCopesWithShortAudio() {
        #expect(KokoroWordTiming.firstWordStart(0.3, loudness: [], frameDuration: 0.01) == 0.3)
        #expect(KokoroWordTiming.firstWordStart(0.05, loudness: loudness(onset: 2, count: 4), frameDuration: 0.01) == 0.02)
        #expect(KokoroWordTiming.firstWordStart(0.3, loudness: loudness(onset: 2, count: 4), frameDuration: 0.01) == 0.3)
    }

    // MARK: - Falling back

    @Test func missingTokensFallBackToProportions() {
        let line = KokoroPhonemeLine(wordPhonemes: ["abc", "def"])
        // Seven scalars should give nine durations; one token is missing.
        let durations: [Int32] = [4, 2, 2, 2, 2, 2, 2, 6]
        let result = KokoroWordTiming.startTimes(for: line, durations: durations, audioDuration: audioDuration(durations))
        #expect(!result.isExact)
        // Between BOS (4 frames) and EOS, 12 frames spread over 7 scalars.
        #expect(isClose(result.startTimes, [seconds(4), seconds(4) + seconds(12) * 4 / 7], within: 1e-6))
    }

    @Test func noFramesFallBackWithoutFailing() {
        let line = KokoroPhonemeLine(wordPhonemes: ["ab", "cd"])
        let result = KokoroWordTiming.startTimes(for: line, durations: [], audioDuration: 1)
        #expect(!result.isExact)
        #expect(isClose(result.startTimes, [0, 0.6]))

        let silent = KokoroWordTiming.startTimes(for: line, durations: [0, 0, 0, 0, 0, 0, 0], audioDuration: 0)
        #expect(isClose(silent.startTimes, [0, 0]))
    }

    @Test func lineWithoutPhonemesHasNoStarts() {
        let line = KokoroPhonemeLine(wordPhonemes: ["", ""])
        let result = KokoroWordTiming.startTimes(for: line, durations: [3, 3], audioDuration: seconds(6))
        #expect(result.isExact)
        #expect(isClose(result.startTimes, [nil, nil]))
    }

    // MARK: - Spoken text

    @Test func plainWordsGoAsTheyAre() {
        #expect(KokoroSpokenText.plan(for: "well,") == .init(text: "well,"))
        #expect(KokoroSpokenText.plan(for: "2000 BCE") == .init(text: "2000 BCE"))
        #expect(KokoroSpokenText.plan(for: "10:30 PM") == .init(text: "10:30 PM"))
        #expect(KokoroSpokenText.plan(for: "elements, stone") == .init(text: "elements, stone"))
    }

    @Test func dropsAccentsOutsideCJK() {
        #expect(KokoroSpokenText.plan(for: "café").text == "cafe")
        #expect(KokoroSpokenText.plan(for: "naïveté,").text == "naivete,")
        #expect(KokoroSpokenText.plan(for: "が").text == "が")
    }

    @Test func tildeBeforeANumberReadsAsAbout() {
        #expect(KokoroSpokenText.plan(for: "~5").text == "about 5")
        #expect(KokoroSpokenText.plan(for: "(~1,000").text == "(about 1,000")
        #expect(KokoroSpokenText.plan(for: "~").text == "~")
        #expect(KokoroSpokenText.plan(for: "a~b").text == "a~b")
    }

    @Test func eraAfterTheYearIsSpelled() {
        #expect(KokoroSpokenText.plan(for: "79 AD") == .init(text: "79", trailing: "ˌAdˈi"))
        #expect(KokoroSpokenText.plan(for: "79 A.D.,") == .init(text: "79", trailing: "ˌAdˈi,"))
        #expect(KokoroSpokenText.plan(for: "1440 AH.") == .init(text: "1440", trailing: "ˌAˈAʧ."))
    }

    @Test func eraBeforeTheYearIsSpelled() {
        #expect(KokoroSpokenText.plan(for: "AD 79") == .init(text: "79", leading: "ˌAdˈi"))
        #expect(KokoroSpokenText.plan(for: "(a.d. 79)") == .init(text: "79)", leading: "(ˌAdˈi"))
    }

    @Test func morningTimeReadsWithPMSpelledAsAM() {
        let plan = KokoroSpokenText.plan(for: "12:00 a.m.,")
        #expect(plan == .init(text: "12:00 PM,", replaced: "pˌiˈɛm", replacement: "ˌAˈɛm"))
        #expect(plan.phonemes(fromPhonemizerOutput: "twˈɛlv pˌiˈɛm,") == "twˈɛlv ˌAˈɛm,")
        #expect(plan.phonemes(fromPhonemizerOutput: "twˈɛlv") == nil)
    }

    @Test func lowercaseUndottedDesignatorsAreWords() {
        #expect(KokoroSpokenText.plan(for: "9 am") == .init(text: "9 am"))
        #expect(KokoroSpokenText.plan(for: "ad 79") == .init(text: "ad 79"))
    }

    @Test func readsDesignators() {
        func designator(_ token: String) -> [String]? {
            KokoroSpokenText.designator(in: token).map { [$0.letters, $0.after] }
        }
        #expect(designator("AM") == ["AM", ""])
        #expect(designator("A.M.") == ["AM", ""])
        #expect(designator("a.m.!") == ["AM", "!"])
        #expect(designator("AD.") == ["AD", "."])
        #expect(designator("B.C.E") == ["BCE", ""])
        #expect(designator("am") == nil)
        #expect(designator("A.MM") == nil)
        #expect(designator("79") == nil)
    }

    @Test func leadingAndTrailingPhonemesJoinWithSpaces() {
        let plan = KokoroSpokenText.Plan(text: "79", leading: "ˌAdˈi")
        #expect(plan.phonemes(fromPhonemizerOutput: "sˈɛvənti nˈIn") == "ˌAdˈi sˈɛvənti nˈIn")
        #expect(plan.phonemes(fromPhonemizerOutput: "") == "ˌAdˈi")
    }
}
