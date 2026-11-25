import Testing
import Foundation
@testable import Strobe

struct SpeedRampTests {

    private func isClose(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 1e-9
    }

    // MARK: - The ramp

    /// From half the speed to all of it over 100 seconds.
    private static let ramp = SpeedRamp(isEnabled: true, startFraction: 0.5, duration: 100)

    @Test func startsAtItsShareAndGainsEvenly() {
        #expect(isClose(Self.ramp.speedFraction(after: 0), 0.5))
        #expect(isClose(Self.ramp.speedFraction(after: 25), 0.625))
        #expect(isClose(Self.ramp.speedFraction(after: 50), 0.75))
        #expect(isClose(Self.ramp.speedFraction(after: 99), 0.995))
    }

    @Test func runsAtTheSpeedOnceTheTimeIsUp() {
        #expect(Self.ramp.speedFraction(after: 100) == 1)
        #expect(Self.ramp.speedFraction(after: 10_000) == 1)
    }

    @Test func neverSlowsWhileOff() {
        let off = SpeedRamp(isEnabled: false, startFraction: 0.5, duration: 100)
        #expect(off.speedFraction(after: 0) == 1)
        #expect(off.speedFraction(after: 50) == 1)
        #expect(SpeedRamp().speedFraction(after: 0) == 1)
    }

    /// The request that asked for it: from 260 to 330 wpm in 5 minutes.
    @Test func goesFrom260To330InFiveMinutes() {
        let ramp = SpeedRamp(isEnabled: true, startFraction: 260.0 / 330.0, duration: 5 * 60)
        #expect(isClose(330 * ramp.speedFraction(after: 0), 260))
        #expect(isClose(330 * ramp.speedFraction(after: 150), 295))
        #expect(isClose(330 * ramp.speedFraction(after: 300), 330))
    }

    /// Whatever was stored, words keep coming and never run past the speed.
    @Test func storedNonsenseStillReads() {
        for start in [-1.0, 0, 0.05, 1, 3] {
            for duration in [-60.0, 0, 60] {
                for elapsed in [-5.0, 0, 30, 60, 90] {
                    let ramp = SpeedRamp(isEnabled: true, startFraction: start, duration: duration)
                    let fraction = ramp.speedFraction(after: elapsed)
                    #expect(fraction >= 0.1 && fraction <= 1, "start \(start), duration \(duration), elapsed \(elapsed)")
                }
            }
        }
    }

    @Test func defaultsAreOffered() {
        #expect(!ReaderSettings.Defaults.speedRampEnabled)
        #expect(SpeedRamp.startRange.contains(ReaderSettings.Defaults.speedRampStart))
        #expect(SpeedRamp.minutesRange.contains(ReaderSettings.Defaults.speedRampMinutes))
    }

    @Test func readsItsSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "SpeedRampTests"))
        defaults.removePersistentDomain(forName: "SpeedRampTests")
        defer { defaults.removePersistentDomain(forName: "SpeedRampTests") }

        #expect(ReaderSettings.speedRamp(from: defaults) == SpeedRamp(
            isEnabled: false,
            startFraction: ReaderSettings.Defaults.speedRampStart,
            duration: ReaderSettings.Defaults.speedRampMinutes * 60
        ))

        defaults.set(true, forKey: ReaderSettings.Keys.speedRampEnabled)
        defaults.set(0.6, forKey: ReaderSettings.Keys.speedRampStart)
        defaults.set(5.0, forKey: ReaderSettings.Keys.speedRampMinutes)
        #expect(ReaderSettings.speedRamp(from: defaults)
            == SpeedRamp(isEnabled: true, startFraction: 0.6, duration: 300))
    }

    // MARK: - The engine

    /// A clock the test moves by hand.
    @MainActor
    private final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 0)
    }

    /// At 1 WPM a plain word takes 60 s and the real timer never fires
    /// during a test; `advance()` stands in for each deadline. The ramp goes
    /// from half the speed to all of it over 600 s of playing.
    @MainActor
    private func engine(
        _ text: String = "one two three four five six seven eight nine ten eleven twelve",
        ramp: SpeedRamp = SpeedRamp(isEnabled: true, startFraction: 0.5, duration: 600),
        sentenceBreaks: Bool = false,
        clock: Clock? = nil
    ) -> RSVPEngine {
        let engine = RSVPEngine(
            words: text.split(separator: " ").map(String.init),
            wordsPerMinute: 1,
            sentenceBreakEnabled: sentenceBreaks,
            speedRamp: ramp
        )
        if let clock { engine.currentDate = { clock.now } }
        return engine
    }

    @MainActor
    @Test func theFirstWordRunsAtTheStartingShare() {
        let engine = engine()
        #expect(isClose(engine.nextInterval(), 120))
        #expect(engine.effectiveWordsPerMinute == 1)
    }

    @MainActor
    @Test func eachWordsTimeCountsTowardTheSpeed() {
        let engine = engine()
        engine.play()
        defer { engine.pause() }
        #expect(engine.rampElapsed == 0)
        engine.advance()
        // The first word took 120 s of the 600: a fifth of the way.
        #expect(isClose(engine.rampElapsed, 120))
        #expect(isClose(engine.nextInterval(), 60 / 0.6))
        engine.advance()
        #expect(isClose(engine.rampElapsed, 220))
    }

    @MainActor
    @Test func reachesTheSpeedAndStaysThere() {
        let engine = engine()
        engine.play()
        defer { engine.pause() }
        var last = engine.nextInterval()
        for _ in 0..<8 {
            engine.advance()
            let interval = engine.nextInterval()
            #expect(interval <= last)
            last = interval
        }
        #expect(engine.rampElapsed >= 600)
        #expect(isClose(engine.nextInterval(), 60))
    }

    @MainActor
    @Test func theBlankAfterASentenceRampsToo() {
        let engine = engine("It ended. Then more words came.", sentenceBreaks: true)
        #expect(isClose(engine.sentenceBreakInterval(), 120))
    }

    @MainActor
    @Test func theSpeedDragRampsToo() {
        let engine = engine()
        engine.wpmOverride = 2
        #expect(isClose(engine.nextInterval(), 60))
    }

    @MainActor
    @Test func aRampTurnedOnMidSessionDoesNotSlowTheWords() {
        let engine = engine(ramp: SpeedRamp())
        engine.play()
        defer { engine.pause() }
        for _ in 0..<10 { engine.advance() }
        #expect(isClose(engine.rampElapsed, 600))
        engine.speedRamp = SpeedRamp(isEnabled: true, startFraction: 0.5, duration: 600)
        #expect(isClose(engine.nextInterval(), 60))
    }

    // MARK: - Sessions

    @MainActor
    @Test func aShortPauseCarriesOn() {
        let clock = Clock()
        let engine = engine(clock: clock)
        engine.play()
        engine.advance()
        engine.pause()
        clock.now += SpeedRamp.sessionPause
        engine.play()
        defer { engine.pause() }
        #expect(isClose(engine.rampElapsed, 120))
        #expect(isClose(engine.nextInterval(), 60 / 0.6))
    }

    @MainActor
    @Test func aLongPauseRampsUpAgain() {
        let clock = Clock()
        let engine = engine(clock: clock)
        engine.play()
        engine.advance()
        engine.pause()
        clock.now += SpeedRamp.sessionPause + 1
        engine.play()
        defer { engine.pause() }
        #expect(engine.rampElapsed == 0)
        #expect(isClose(engine.nextInterval(), 120))
    }

    /// Scrubbing pauses an engine that's already paused, which doesn't
    /// count as reading: the pause is still measured from when words
    /// stopped.
    @MainActor
    @Test func scrubbingWhilePausedDoesNotShortenThePause() {
        let clock = Clock()
        let engine = engine(clock: clock)
        engine.play()
        engine.advance()
        engine.advance()
        engine.pause()
        clock.now += SpeedRamp.sessionPause - 10
        engine.scrub(by: -1)
        clock.now += 20
        engine.play()
        defer { engine.pause() }
        #expect(engine.rampElapsed == 0)
    }

    @MainActor
    @Test func scrubbingKeepsTheSessionsTime() {
        let clock = Clock()
        let engine = engine(clock: clock)
        engine.play()
        engine.advance()
        engine.advance()
        engine.scrub(by: -2)
        engine.restart()
        clock.now += 30
        engine.play()
        defer { engine.pause() }
        #expect(isClose(engine.rampElapsed, 220))
    }

    // MARK: - A voice

    @MainActor
    private final class SilentPacer: WordPacer {
        var onEvent: ((PacerEvent) -> Void)?
        private(set) var contexts: [PacerContext] = []
        func start(_ context: PacerContext) { contexts.append(context) }
        func stop() {}
        func speedDidChange(wordsPerMinute: Int) {}
        func timingDidChange(_ timing: ReaderSettings.TimingSnapshot) {}
    }

    /// A voice reads at the speed itself, and the time it reads counts.
    @MainActor
    @Test func aVoiceReadsAtTheSpeedAndItsTimeCounts() {
        let engine = RSVPEngine(
            words: ["one", "two", "three", "four"],
            wordsPerMinute: 300,
            speedRamp: SpeedRamp(isEnabled: true, startFraction: 0.5, duration: 600)
        )
        let pacer = SilentPacer()
        engine.pacer = pacer
        engine.play()
        defer { engine.pause() }
        #expect(pacer.contexts.last?.wordsPerMinute == 300)
        pacer.onEvent?(.word(1, interval: 0.25))
        pacer.onEvent?(.word(2))
        pacer.onEvent?(.word(3, interval: 0.5))
        #expect(isClose(engine.rampElapsed, 0.75))
    }
}
