import Foundation
import Testing
@testable import Strobe

/// Reading aloud moves the engine through a pacer instead of the timer:
/// play and pause start and stop it, and its events move the word the way
/// the timer's ticks do.
struct ReadAloudEngineTests {

    /// Records what the engine asks of it and sends events as a voice
    /// would, without speaking.
    @MainActor
    private final class FakePacer: WordPacer {
        var onEvent: ((PacerEvent) -> Void)?
        private(set) var contexts: [PacerContext] = []
        private(set) var speeds: [Int] = []
        private(set) var stopCount = 0
        private(set) var isRunning = false

        func start(_ context: PacerContext) {
            contexts.append(context)
            isRunning = true
        }

        func stop() {
            stopCount += 1
            isRunning = false
        }

        func speedDidChange(wordsPerMinute: Int) {
            speeds.append(wordsPerMinute)
        }

        func send(_ events: PacerEvent...) {
            for event in events {
                onEvent?(event)
            }
        }
    }

    /// Splits `text` at spaces into the words a test reads from.
    private func split(_ text: String) -> [String] {
        text.split(separator: " ").map(String.init)
    }

    /// An engine reading `text` through a fake pacer, not yet playing.
    @MainActor
    private func pacedEngine(
        _ text: String,
        at index: Int = 0,
        wordsPerMinute: Int = 300,
        chapters: [Int: String] = [:]
    ) -> (RSVPEngine, FakePacer) {
        let engine = RSVPEngine(
            words: split(text),
            currentIndex: index,
            wordsPerMinute: wordsPerMinute,
            chapters: chapters.map { Chapter(title: $0.value, wordIndex: $0.key) }
        )
        let pacer = FakePacer()
        engine.pacer = pacer
        return (engine, pacer)
    }

    // MARK: - Starting and stopping

    @MainActor
    @Test func playStartsThePacerInsteadOfTheTimer() {
        let (engine, pacer) = pacedEngine("One two three four five.")
        defer { engine.pause() }
        engine.play()
        #expect(engine.isPlaying)
        #expect(pacer.isRunning)
        #expect(pacer.contexts.count == 1)
        #expect(engine.scheduledDeadline == nil)
        #expect(engine.currentWordInterval == nil)
        // Already playing: no second start.
        engine.play()
        #expect(pacer.contexts.count == 1)
    }

    @MainActor
    @Test func pauseSeekScrubAndRestartStopThePacer() {
        let (engine, pacer) = pacedEngine("One two three four five six.")
        engine.play()
        engine.pause()
        #expect(!engine.isPlaying)
        #expect(!pacer.isRunning)

        engine.play()
        engine.seek(to: 3)
        #expect(!engine.isPlaying)
        #expect(!pacer.isRunning)
        #expect(engine.currentIndex == 3)

        engine.play()
        #expect(pacer.contexts.last?.startIndex == 3)
        engine.scrub(by: -2)
        #expect(!pacer.isRunning)

        engine.play()
        engine.restart()
        #expect(!pacer.isRunning)
        #expect(pacer.contexts.count == 4)
        #expect(pacer.stopCount == 4)
    }

    @MainActor
    @Test func playDoesNothingAtTheEnd() {
        let (engine, pacer) = pacedEngine("One two three.", at: 2)
        engine.play()
        #expect(!engine.isPlaying)
        #expect(pacer.contexts.isEmpty)
    }

    @MainActor
    @Test func replacingThePacerPausesAndStopsTheOldOne() {
        let (engine, first) = pacedEngine("One two three four five.")
        engine.play()
        let second = FakePacer()
        engine.pacer = second
        #expect(!engine.isPlaying)
        #expect(!first.isRunning)
        #expect(first.onEvent == nil)
        #expect(second.onEvent != nil)

        engine.play()
        #expect(second.isRunning)
        #expect(first.contexts.count == 1)
        // The old pacer can't move playback any more.
        first.send(.word(3))
        #expect(engine.currentIndex == 0)

        // Without a pacer, the timer plays again.
        engine.pacer = nil
        #expect(!second.isRunning)
        engine.play()
        defer { engine.pause() }
        #expect(engine.scheduledDeadline != nil)
    }

    @MainActor
    @Test func thePacerDoesNotKeepTheEngineAlive() {
        let pacer = FakePacer()
        weak var released: RSVPEngine?
        do {
            let engine = RSVPEngine(words: ["one", "two"])
            engine.pacer = pacer
            released = engine
        }
        #expect(released == nil)
        pacer.send(.word(1))
    }

    // MARK: - Context

    @MainActor
    @Test func contextCarriesWhatThePacerNeeds() throws {
        let words = split("It ended. Chapter 1 The Storm Rain fell. More words.")
        let heading = Chapter(title: "Chapter 1: The Storm", wordIndex: 2)
        let engine = RSVPEngine(
            words: words,
            currentIndex: 1,
            wordsPerMinute: 380,
            smartTimingEnabled: true,
            sentenceBreakEnabled: true,
            sentenceBreakLength: 2,
            // An untitled chapter isn't announced.
            chapters: [heading, Chapter(title: "", wordIndex: 8)]
        )
        let pacer = FakePacer()
        engine.pacer = pacer
        defer { engine.pause() }
        engine.play()

        let context = try #require(pacer.contexts.first)
        #expect(context.words == words)
        #expect(context.startIndex == 1)
        #expect(context.chapters == [2: heading])
        #expect(context.readingStarts[2] == 6)
        #expect(!context.announcesChapterAtStart)
        #expect(context.wordsPerMinute == 380)
        #expect(context.timing.sentenceBreakEnabled)
        #expect(context.timing.sentenceBreakLength == 2)
        #expect(context.timing.smartTimingEnabled)
    }

    /// The chapter at the start is announced unless its title already
    /// showed, the rule the timer follows.
    @MainActor
    @Test func aChapterAtTheStartIsAnnouncedOnce() {
        let (engine, pacer) = pacedEngine("Intro ends here. Then more words follow.", at: 3, chapters: [3: "Interlude"])
        defer { engine.pause() }
        engine.play()
        #expect(pacer.contexts.last?.announcesChapterAtStart == true)

        pacer.send(.chapterTitle(at: 3, isVisible: true))
        engine.pause()
        #expect(engine.currentIndex == 3)
        engine.play()
        #expect(pacer.contexts.last?.announcesChapterAtStart == false)

        // Seeking back to it announces it again.
        engine.seek(to: 3)
        engine.play()
        #expect(pacer.contexts.last?.announcesChapterAtStart == true)
    }

    // MARK: - Events

    @MainActor
    @Test func wordEventsMoveForwardOnly() {
        let (engine, pacer) = pacedEngine("One two three four five six.")
        defer { engine.pause() }
        engine.play()
        pacer.send(.word(0))
        #expect(engine.currentIndex == 0)
        pacer.send(.word(3))
        #expect(engine.currentIndex == 3)
        pacer.send(.word(1))
        #expect(engine.currentIndex == 3)
        pacer.send(.word(99), .word(-1))
        #expect(engine.currentIndex == 3)
        #expect(engine.isPlaying)
    }

    @MainActor
    @Test func wordsPlayedAndFurthestCountLikeTheTimer() {
        let (engine, pacer) = pacedEngine("One two three four five six.")
        defer { engine.pause() }
        engine.play()
        pacer.send(.word(0), .word(1), .word(2))
        #expect(engine.takePlayedWordCount() == 2)
        // Words the voice passes over in one step were still read.
        pacer.send(.word(5))
        #expect(engine.takePlayedWordCount() == 3)
        #expect(engine.furthestPlayedIndex == 5)
    }

    /// The title stands in for the words that repeat it: reading goes on
    /// after them, which counts toward the furthest word but not the words
    /// played, as with the timer.
    @MainActor
    @Test func aChapterTitleThenItsReadingStart() {
        let text = "It ended. Chapter 1 The Storm Rain fell. More words."
        let chapters = [2: "Chapter 1: The Storm"]
        let (engine, pacer) = pacedEngine(text, chapters: chapters)
        defer { engine.pause() }
        #expect(engine.readingStart(ofChapterAt: 2) == 6)
        engine.play()

        pacer.send(.word(0), .word(1), .chapterTitle(at: 2, isVisible: true))
        #expect(engine.currentIndex == 2)
        #expect(engine.chapterAnnouncement?.title == "Chapter 1: The Storm")
        #expect(engine.isChapterTitleVisible)

        pacer.send(.chapterTitle(at: 2, isVisible: false))
        #expect(engine.chapterAnnouncement != nil)
        #expect(!engine.isChapterTitleVisible)

        pacer.send(.word(6))
        #expect(engine.chapterAnnouncement == nil)
        #expect(engine.currentWord == "Rain")
        pacer.send(.word(7))
        #expect(engine.furthestPlayedIndex == 7)
        let paced = engine.takePlayedWordCount()

        // The timer, through the same words.
        let timed = RSVPEngine(
            words: split(text),
            wordsPerMinute: 1,
            chapters: chapters.map { Chapter(title: $0.value, wordIndex: $0.key) }
        )
        defer { timed.pause() }
        timed.play()
        while timed.currentIndex < 7 { timed.advance() }
        #expect(paced == 3)
        #expect(timed.takePlayedWordCount() == paced)
        #expect(timed.furthestPlayedIndex == engine.furthestPlayedIndex)
    }

    @MainActor
    @Test func pausingDuringATitleGoesOnAfterIt() {
        let (engine, pacer) = pacedEngine("It ended. Chapter 1 The Storm Rain fell.", chapters: [2: "Chapter 1: The Storm"])
        engine.play()
        pacer.send(.word(1), .chapterTitle(at: 2, isVisible: true))
        engine.pause()
        #expect(engine.chapterAnnouncement == nil)
        #expect(engine.currentWord == "Rain")
        engine.play()
        defer { engine.pause() }
        #expect(pacer.contexts.last?.startIndex == 6)
        #expect(pacer.contexts.last?.announcesChapterAtStart == false)
    }

    /// Back-to-back chapters: the second starts where the first's heading
    /// ends, so the heading's words never count as played.
    @MainActor
    @Test func aTitleRightAfterAnotherCountsNoHeadingWords() {
        let (engine, pacer) = pacedEngine("Part One Chapter 1 It began.", chapters: [0: "Part One", 2: "Chapter 1"])
        defer { engine.pause() }
        #expect(engine.readingStart(ofChapterAt: 0) == 2)
        #expect(engine.readingStart(ofChapterAt: 2) == 4)
        engine.play()
        pacer.send(
            .chapterTitle(at: 0, isVisible: true),
            .chapterTitle(at: 2, isVisible: true),
            .word(4)
        )
        #expect(engine.currentWord == "It")
        #expect(engine.takePlayedWordCount() == 0)
        #expect(engine.furthestPlayedIndex == 4)
    }

    @MainActor
    @Test func sentenceBreaksBlankTheWordUntilTheNext() {
        let (engine, pacer) = pacedEngine("It rained. Then it stopped. The end.")
        defer { engine.pause() }
        engine.play()
        pacer.send(.word(1), .sentenceBreak)
        #expect(engine.isInSentenceBreak)
        #expect(engine.currentIndex == 1)
        pacer.send(.word(2))
        #expect(!engine.isInSentenceBreak)

        pacer.send(.word(4), .sentenceBreak)
        engine.pause()
        #expect(!engine.isInSentenceBreak)
    }

    @MainActor
    @Test func finishedLandsOnTheLastWordAndPauses() {
        let (engine, pacer) = pacedEngine("One two three four five.")
        engine.play()
        pacer.send(.word(2), .finished)
        #expect(engine.currentIndex == 4)
        #expect(engine.isAtEnd)
        #expect(!engine.isPlaying)
        #expect(!pacer.isRunning)
        #expect(engine.takePlayedWordCount() == 4)
        #expect(engine.furthestPlayedIndex == 4)
    }

    @MainActor
    @Test func failedPausesWhereItIs() {
        let (engine, pacer) = pacedEngine("One two three four five.")
        engine.play()
        pacer.send(.word(2), .sentenceBreak, .failed)
        #expect(engine.currentIndex == 2)
        #expect(!engine.isPlaying)
        #expect(!engine.isInSentenceBreak)
        #expect(!pacer.isRunning)
    }

    @MainActor
    @Test func eventsAfterPausingChangeNothing() {
        let (engine, pacer) = pacedEngine("One two three four five.", chapters: [3: "Aside"])
        engine.play()
        engine.pause()
        pacer.send(.word(2), .sentenceBreak, .chapterTitle(at: 3, isVisible: true), .finished)
        #expect(engine.currentIndex == 0)
        #expect(!engine.isInSentenceBreak)
        #expect(engine.chapterAnnouncement == nil)
        #expect(engine.takePlayedWordCount() == 0)
    }

    // MARK: - Speed

    @MainActor
    @Test func speedCapHoldsTheSpeedDown() {
        let engine = RSVPEngine(words: ["one", "two"], wordsPerMinute: 600)
        #expect(engine.effectiveWordsPerMinute == 600)
        engine.speedCap = Int(ReaderSettings.readAloudWPMRange.upperBound)
        #expect(engine.effectiveWordsPerMinute == 450)
        engine.wpmOverride = 800
        #expect(engine.effectiveWordsPerMinute == 450)
        engine.wpmOverride = 300
        #expect(engine.effectiveWordsPerMinute == 300)
        engine.wpmOverride = nil
        engine.speedCap = nil
        #expect(engine.effectiveWordsPerMinute == 600)
    }

    @MainActor
    @Test func thePacerStartsAtTheCappedSpeed() {
        let (engine, pacer) = pacedEngine("One two three.", wordsPerMinute: 700)
        defer { engine.pause() }
        engine.speedCap = 450
        engine.play()
        #expect(pacer.contexts.last?.wordsPerMinute == 450)
    }

    @MainActor
    @Test func speedChangesReachThePacerWhilePlaying() {
        let (engine, pacer) = pacedEngine("One two three four five.")
        engine.speedCap = 450
        engine.play()
        #expect(pacer.contexts.last?.wordsPerMinute == 300)

        engine.wordsPerMinute = 400
        engine.wordsPerMinute = 500
        // Already at the cap.
        engine.wordsPerMinute = 600
        engine.wpmOverride = 200
        engine.wpmOverride = nil
        engine.speedCap = 350
        #expect(pacer.speeds == [400, 450, 200, 450, 350])

        engine.pause()
        engine.wordsPerMinute = 320
        #expect(pacer.speeds == [400, 450, 200, 450, 350])
        engine.play()
        defer { engine.pause() }
        #expect(pacer.contexts.last?.wordsPerMinute == 320)
    }

    @MainActor
    @Test func timingSettingsDoNotReachThePacer() {
        let (engine, pacer) = pacedEngine("One, two. Three four five.")
        defer { engine.pause() }
        engine.play()
        engine.smartTimingEnabled = true
        engine.smartTimingPercentPerLetter = 10
        engine.smartTimingMinimumWordLength = 4
        engine.sentencePauseEnabled = true
        engine.sentencePauseMultiplier = 3
        engine.punctuationPauses = PunctuationPauses(clause: 2, dash: 2, ellipsis: 2, bracket: 2)
        engine.sentenceBreakEnabled = true
        engine.sentenceBreakLength = 3
        engine.complexityTimingEnabled = true
        engine.complexityIntensity = 1
        #expect(pacer.speeds.isEmpty)
        #expect(pacer.contexts.count == 1)
        #expect(pacer.stopCount == 0)
        #expect(engine.scheduledDeadline == nil)
        #expect(engine.isPlaying)
    }
}
