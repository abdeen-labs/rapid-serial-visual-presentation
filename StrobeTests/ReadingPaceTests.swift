import Foundation
import Testing
@testable import Strobe

struct ReadingPaceTests {

    /// Timing settings at their defaults, with the given changes.
    private static func timing(
        smartTiming: Bool = false,
        percentPerLetter: Double = ReaderSettings.Defaults.smartTimingPercentPerLetter,
        minimumWordLength: Int = ReaderSettings.Defaults.smartTimingMinimumWordLength,
        pauses: Bool = false,
        sentencePause: Double = ReaderSettings.Defaults.sentencePauseMultiplier,
        punctuationPauses: PunctuationPauses = PunctuationPauses(),
        complexity: Bool = false,
        speedUp: Double = ReaderSettings.Defaults.complexitySpeedUpIntensity,
        slowDown: Double = ReaderSettings.Defaults.complexitySlowDownIntensity,
        breaks: Bool = false,
        breakLength: Double = ReaderSettings.Defaults.sentenceBreakLength
    ) -> ReaderSettings.TimingSnapshot {
        ReaderSettings.TimingSnapshot(
            smartTimingEnabled: smartTiming,
            sentencePauseEnabled: pauses,
            smartTimingPercentPerLetter: percentPerLetter,
            smartTimingMinimumWordLength: minimumWordLength,
            sentencePauseMultiplier: sentencePause,
            complexityTimingEnabled: complexity,
            complexitySpeedUpIntensity: speedUp,
            complexitySlowDownIntensity: slowDown,
            punctuationPauses: punctuationPauses,
            sentenceBreakEnabled: breaks,
            sentenceBreakLength: breakLength
        )
    }

    /// Every timing feature alone, then several together with unusual values.
    private static let timings: [ReaderSettings.TimingSnapshot] = [
        timing(),
        timing(smartTiming: true),
        timing(smartTiming: true, percentPerLetter: 7, minimumWordLength: 6),
        timing(pauses: true),
        timing(smartTiming: true, pauses: true),
        timing(
            pauses: true,
            sentencePause: 2.5,
            punctuationPauses: PunctuationPauses(clause: 1.8, dash: 2.2, ellipsis: 1.1, bracket: 1.0)
        ),
        timing(complexity: true, speedUp: 1.0, slowDown: 1.0),
        timing(complexity: true, speedUp: 0.2, slowDown: 0.9),
        timing(breaks: true, breakLength: 1.5),
        timing(pauses: true, breaks: true),
        timing(
            smartTiming: true,
            percentPerLetter: 3,
            minimumWordLength: 4,
            pauses: true,
            sentencePause: 1.8,
            complexity: true,
            speedUp: 0.3,
            slowDown: 0.7,
            breaks: true,
            breakLength: 0.5
        ),
    ]

    /// Words that exercise every timing rule: compounds, acronyms, a number
    /// unit, clause marks, dashes, an ellipsis, brackets and quotes, a passage
    /// in capitals, sentence ends with and without a blank after them, and
    /// CJK.
    private static let words = [
        "The", "FBI", "agent's", "wedge-shaped", "badge\u{2014}", "gleaming,", "bright\u{2014}",
        "was", "(in", "2000 BCE)", "a", "state-of-the-art", "\u{201C}design.\u{201D}", "Mr.", "Smith",
        "said:", "NASA-funded?", "Yes!", "Then...", "silence.", "PNG,", "JPEG,", "GIF;",
        "THE", "END", "HERE.", "e.g.", "this", "one.", "東京は", "大きい。", "Characteristically", "so.",
    ]

    /// Scores spread over the whole range, so complexity both speeds words
    /// up and slows them down.
    private static func scores(for words: [String]) -> [Float] {
        words.indices.map { Float($0 % 5) / 4 }
    }

    @MainActor
    private static func makeEngine(
        _ words: [String],
        at index: Int = 0,
        wordsPerMinute: Int,
        paceFactor: Double = 1,
        timing: ReaderSettings.TimingSnapshot,
        scores: [Float]?
    ) -> RSVPEngine {
        let engine = RSVPEngine(
            words: words,
            currentIndex: index,
            wordsPerMinute: wordsPerMinute,
            smartTimingEnabled: timing.smartTimingEnabled,
            sentencePauseEnabled: timing.sentencePauseEnabled,
            smartTimingPercentPerLetter: timing.smartTimingPercentPerLetter,
            smartTimingMinimumWordLength: timing.smartTimingMinimumWordLength,
            sentencePauseMultiplier: timing.sentencePauseMultiplier,
            punctuationPauses: timing.punctuationPauses,
            sentenceBreakEnabled: timing.sentenceBreakEnabled,
            sentenceBreakLength: timing.sentenceBreakLength,
            complexityTimingEnabled: timing.complexityTimingEnabled,
            complexitySpeedUpIntensity: timing.complexitySpeedUpIntensity,
            complexitySlowDownIntensity: timing.complexitySlowDownIntensity,
            complexityScores: scores
        )
        engine.paceFactor = paceFactor
        return engine
    }

    /// How long the engine plays `words`, from the first word's appearance to
    /// the end of the last word's time, blanks included. No timer has to
    /// fire: each advance schedules from the deadline before it, and the
    /// speeds used here keep every deadline well in the future.
    @MainActor
    private static func playbackDuration(
        of words: [String],
        wordsPerMinute: Int,
        paceFactor: Double = 1,
        timing: ReaderSettings.TimingSnapshot,
        scores: [Float]?
    ) -> TimeInterval? {
        let engine = makeEngine(
            words,
            wordsPerMinute: wordsPerMinute,
            paceFactor: paceFactor,
            timing: timing,
            scores: scores
        )
        let firstWord = engine.nextInterval()
        engine.play()
        defer { engine.pause() }
        guard let first = engine.scheduledDeadline else { return nil }
        while !engine.isAtEnd {
            engine.advance()
        }
        guard let last = engine.scheduledDeadline else { return nil }
        return firstWord + Double(last.uptimeNanoseconds - first.uptimeNanoseconds) / 1_000_000_000
    }

    private static func pace(
        _ words: [String],
        scores: [Float]? = nil,
        chapters: [Chapter] = [],
        timing: ReaderSettings.TimingSnapshot = ReadingPaceTests.timing()
    ) -> Double {
        ReadingPace.factor(words: words, complexityScores: scores, chapters: chapters, timing: timing)
    }

    // MARK: - One timing for playback and the factor

    /// The engine and the estimate time each word with the same function, and
    /// the engine hands it all of its settings.
    @MainActor
    @Test func wordTimesMatchTheEngine() {
        let words = Self.words
        let scores = Self.scores(for: words)
        for timing in Self.timings {
            for wordsPerMinute in [100, 300, 1000] {
                let base = 60.0 / Double(wordsPerMinute)
                for index in words.indices {
                    let engine = Self.makeEngine(words, at: index, wordsPerMinute: wordsPerMinute, timing: timing, scores: scores)
                    let expected = RSVPEngine.interval(
                        forWordAt: index,
                        in: words,
                        complexityScores: scores,
                        timing: timing,
                        baseInterval: base
                    )
                    #expect(engine.nextInterval() == expected, "\(words[index]) at \(wordsPerMinute) wpm, \(timing)")
                }
                let engine = Self.makeEngine(words, wordsPerMinute: wordsPerMinute, timing: timing, scores: scores)
                #expect(engine.sentenceBreakInterval() == RSVPEngine.sentenceBreakInterval(timing: timing, baseInterval: base))
            }
        }
    }

    /// Played through at a plain base speed, a document takes its plain time
    /// times its factor: every word's time and every blank after a sentence,
    /// at any speed.
    @MainActor
    @Test func playbackTakesAsLongAsThePaceSays() throws {
        let words = Self.words
        let scores = Self.scores(for: words)
        for timing in Self.timings {
            let factor = Self.pace(words, scores: scores, timing: timing)
            for wordsPerMinute in [1, 7] {
                let duration = Self.playbackDuration(
                    of: words,
                    wordsPerMinute: wordsPerMinute,
                    timing: timing,
                    scores: scores
                )
                let played = try #require(duration)
                let plain = Double(words.count) * 60 / Double(wordsPerMinute)
                #expect(abs(played - plain * factor) < 0.001, "\(wordsPerMinute) wpm, \(timing)")
            }
        }
    }

    /// Given its factor, the engine reads a document at its speed: the
    /// timing settings' time comes out of the base speed, so the whole takes
    /// its words over its speed, however much the settings add or take away.
    @MainActor
    @Test func paceFactorPlaysTheDocumentAtItsSpeed() throws {
        let words = Self.words
        let scores = Self.scores(for: words)
        for timing in Self.timings {
            let factor = Self.pace(words, scores: scores, timing: timing)
            for wordsPerMinute in [1, 7] {
                let duration = Self.playbackDuration(
                    of: words,
                    wordsPerMinute: wordsPerMinute,
                    paceFactor: factor,
                    timing: timing,
                    scores: scores
                )
                let played = try #require(duration)
                let plain = Double(words.count) * 60 / Double(wordsPerMinute)
                #expect(abs(played - plain) < 0.001, "\(wordsPerMinute) wpm, \(timing)")
            }
        }
    }

    /// A factor that can't be right plays at the plain base speed.
    @MainActor
    @Test func unusablePaceFactorPlaysPlain() {
        let unusable: [Double] = [0, -1, .nan, .infinity]
        for factor in unusable {
            let engine = Self.makeEngine(["plain"], wordsPerMinute: 300, paceFactor: factor, timing: Self.timing(), scores: nil)
            #expect(abs(engine.nextInterval() - 0.2) < 1e-12, "\(factor)")
        }
    }

    /// Every term of a word's time scales with the base interval, so the
    /// factor is the same at every speed.
    @Test func wordTimesScaleWithTheSpeed() {
        let words = Self.words
        let scores = Self.scores(for: words)
        for timing in Self.timings {
            for index in words.indices {
                let inBaseIntervals = RSVPEngine.interval(
                    forWordAt: index,
                    in: words,
                    complexityScores: scores,
                    timing: timing,
                    baseInterval: 1
                )
                for wordsPerMinute in [100, 333, 1000] {
                    let base = 60 / Double(wordsPerMinute)
                    let atSpeed = RSVPEngine.interval(
                        forWordAt: index,
                        in: words,
                        complexityScores: scores,
                        timing: timing,
                        baseInterval: base
                    )
                    #expect(abs(atSpeed / base - inBaseIntervals) < 1e-9, "\(words[index]), \(timing)")
                }
            }
            let blank = RSVPEngine.sentenceBreakInterval(timing: timing, baseInterval: 1)
            #expect(abs(RSVPEngine.sentenceBreakInterval(timing: timing, baseInterval: 0.2) / 0.2 - blank) < 1e-9)
        }
    }

    // MARK: - The factor

    @Test func paceOfKnownWords() {
        // A compound's second part and an acronym's further letters add time
        // with every setting off.
        #expect(abs(Self.pace(["wedge-shaped", "rock"]) - 1.25) < 1e-9)
        #expect(abs(Self.pace(["FBI", "agents"]) - 1.25) < 1e-9)
        // Smart timing: 5 letters at 10% each.
        #expect(abs(Self.pace(["hello"], timing: Self.timing(smartTiming: true, percentPerLetter: 10)) - 1.5) < 1e-9)
        // A sentence end pausing twice as long.
        #expect(abs(Self.pace(["Hello", "world."], timing: Self.timing(pauses: true, sentencePause: 2)) - 1.5) < 1e-9)
        // Complexity at full intensity: score 1 takes 1.6 intervals, and
        // score 0 0.4.
        let complex = Self.timing(complexity: true, speedUp: 1, slowDown: 1)
        #expect(abs(Self.pace(["a", "b"], scores: [1, 1], timing: complex) - 1.6) < 1e-9)
        #expect(abs(Self.pace(["a", "b"], scores: [0, 1], timing: complex) - 1) < 1e-9)
        // Each direction on its own.
        let slowOnly = Self.timing(complexity: true, speedUp: 0, slowDown: 1)
        #expect(abs(Self.pace(["a", "b"], scores: [0, 1], timing: slowOnly) - 1.3) < 1e-9)
        // Without scores, as for a document not yet backfilled, complexity
        // changes nothing, as in the engine.
        #expect(Self.pace(["a", "b"], timing: complex) == 1)
    }

    @Test func sentenceBreaksAddTheirBlank() {
        let words = ["It", "ended.", "Then", "more"]
        let breaks = Self.timing(breaks: true, breakLength: 2)
        // Four words and one blank of two intervals.
        #expect(abs(Self.pace(words, timing: breaks) - 1.5) < 1e-9)
        // No blank before a chapter: its announcement is a break of its own.
        let chapter = Chapter(title: "Part Two", wordIndex: 2)
        #expect(Self.pace(words, chapters: [chapter], timing: breaks) == 1)
        // A chapter without a title isn't announced, so the blank stays.
        let untitled = Chapter(title: "", wordIndex: 2)
        #expect(abs(Self.pace(words, chapters: [untitled], timing: breaks) - 1.5) < 1e-9)
    }

    @Test func plainSettingsKeepThePlainEstimate() throws {
        let suiteName = "ReadingPaceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // The default settings are plain.
        let plain = ReaderSettings.timingSnapshot(from: defaults)
        #expect(plain == Self.timing())

        let words = "The quick brown fox jumps over the lazy dog, then sleeps.".split(separator: " ").map(String.init)
        #expect(Self.pace(words, timing: plain) == 1)
        // Scores don't count while complexity timing is off.
        #expect(Self.pace(words, scores: Array(repeating: 1, count: words.count), timing: plain) == 1)
        #expect(Self.pace([], timing: Self.timing(smartTiming: true, pauses: true)) == 1)
    }

    /// The speed counts every pause, so a document's time is its words over
    /// its speed, rounded up to whole minutes.
    @Test func minutesAreWordsOverTheSpeed() {
        #expect(ReadingTime.minutes(words: 3000, wordsPerMinute: 300) == 10)
        #expect(ReadingTime.minutes(words: 3000, wordsPerMinute: 150) == 20)
        #expect(ReadingTime.minutes(words: 100, wordsPerMinute: 300) == 1)
        #expect(ReadingTime.minutes(words: 0, wordsPerMinute: 300) == 0)
        #expect(ReadingTime.minutes(words: 301, wordsPerMinute: 300) == 2)
        #expect(ReadingTime.minutes(words: 301, wordsPerMinute: 0) == 0)
    }

    // MARK: - The cache

    @Test func everyTimingSettingChangesTheKey() throws {
        typealias Keys = ReaderSettings.Keys
        let id = UUID()
        let changes: [(key: String, value: Any)] = [
            (Keys.smartTimingEnabled, true),
            (Keys.sentencePauseEnabled, true),
            (Keys.smartTimingPercentPerLetter, 6.0),
            (Keys.smartTimingMinimumWordLength, 5),
            (Keys.sentencePauseMultiplier, 2.0),
            (Keys.complexityTimingEnabled, true),
            (Keys.complexitySpeedUpIntensity, 0.9),
            (Keys.complexitySlowDownIntensity, 0.9),
            (Keys.clausePauseMultiplier, 1.9),
            (Keys.dashPauseMultiplier, 1.9),
            (Keys.ellipsisPauseMultiplier, 1.9),
            (Keys.bracketPauseMultiplier, 1.9),
            (Keys.sentenceBreakEnabled, true),
            (Keys.sentenceBreakLength, 2.0),
        ]
        let baseline = ReadingPace.Key(documentID: id, wordCount: 100, timing: Self.timing())
        #expect(baseline == ReadingPace.Key(documentID: id, wordCount: 100, timing: Self.timing()))
        // A different document, or different words, needs its own factor.
        #expect(baseline != ReadingPace.Key(documentID: UUID(), wordCount: 100, timing: Self.timing()))
        #expect(baseline != ReadingPace.Key(documentID: id, wordCount: 101, timing: Self.timing()))

        for change in changes {
            let suiteName = "ReadingPaceTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(change.value, forKey: change.key)
            let key = ReadingPace.Key(documentID: id, wordCount: 100, timing: ReaderSettings.timingSnapshot(from: defaults))
            #expect(key != baseline, "\(change.key)")
        }
    }

    @MainActor
    @Test func keyFollowsTheSettings() throws {
        let suiteName = "ReadingPaceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pace = ReadingPace(defaults: defaults, cacheURL: nil)
        let document = Document(title: "Pace", fileName: "pace.txt", bookmarkData: Data(), words: ["one", "two"])
        let before = pace.key(for: document)
        // The speed isn't part of the key.
        document.wordsPerMinute = 600
        #expect(pace.key(for: document) == before)

        defaults.set(true, forKey: ReaderSettings.Keys.sentencePauseEnabled)
        pace.reloadTiming()
        let after = pace.key(for: document)
        #expect(after != before)
        #expect(after.timing.sentencePauseEnabled)
    }

    @MainActor
    @Test func workedOutPaceIsKeptUntilTheSettingsChange() async throws {
        let suiteName = "ReadingPaceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheURL = FileManager.default.temporaryDirectory
            .appending(path: "ReadingPaceTests-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        defaults.set(true, forKey: ReaderSettings.Keys.sentencePauseEnabled)
        defaults.set(2.0, forKey: ReaderSettings.Keys.sentencePauseMultiplier)
        let pace = ReadingPace(defaults: defaults, cacheURL: cacheURL)
        let document = Document(
            title: "Pace",
            fileName: "pace.txt",
            bookmarkData: Data(),
            words: ["Hello", "world."]
        )
        #expect(pace.factor(for: document) == nil)

        let worked = await pace.preparedFactor(for: document)
        let factor = try #require(worked)
        #expect(abs(factor - 1.5) < 1e-9)
        #expect(pace.factor(for: document) == factor)

        // The next launch reads it back.
        let relaunched = ReadingPace(defaults: defaults, cacheURL: cacheURL)
        #expect(relaunched.factor(for: document) == factor)

        // A timing change makes it stale until it's worked out again.
        defaults.set(3.0, forKey: ReaderSettings.Keys.sentencePauseMultiplier)
        pace.reloadTiming()
        #expect(pace.factor(for: document) == nil)
        let reworked = await pace.preparedFactor(for: document)
        #expect(abs((reworked ?? 0) - 2) < 1e-9)

        // New complexity scores drop it.
        pace.forget(document.id)
        #expect(pace.factor(for: document) == nil)
    }
}
