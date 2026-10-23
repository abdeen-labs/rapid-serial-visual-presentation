import AVFAudio
import Foundation
import Testing
@testable import Strobe

/// Reading aloud follows the voice: the pacer plans titles, words, and
/// silences, renders them ahead, and turns where the listener is into the
/// engine's events.
@MainActor
struct ReadAloudPacerTests {

    private struct TestError: Error {}

    /// Renders a script as a voice that says each word in 0.3 s, after
    /// 0.2 s of silence and before 0.1 s more, with an exact marker at the
    /// start of each of the script's words. It takes as long at any speed,
    /// so tests hear words at fixed times.
    @MainActor
    private final class FakeRenderer: SpeechRendering {
        struct Request {
            let script: SpeechScript
            let speed: Double

            var text: String { script.text }
        }

        static let leadingSilence: TimeInterval = 0.2
        static let wordDuration: TimeInterval = 0.3
        static let trailingSilence: TimeInterval = 0.1
        static let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!

        private(set) var requests: [Request] = []
        /// The text each rendered buffer says.
        private(set) var texts: [ObjectIdentifier: String] = [:]
        /// Renders wait while this is set, until it's cleared or they're
        /// cancelled.
        var holdsRenders = false
        var failure: (any Error)?
        /// The speed the audio says it was rendered at, as when a renderer
        /// can't reach the one asked for; nil for the speed asked for.
        var reportedSpeed: Double?
        private(set) var cancellations = 0

        func render(_ script: SpeechScript, speed: Double) async throws -> RenderedSpeech {
            requests.append(Request(script: script, speed: speed))
            while holdsRenders {
                do {
                    try await Task.sleep(for: .milliseconds(1))
                } catch {
                    cancellations += 1
                    throw error
                }
            }
            if let failure { throw failure }
            let speech = Self.speech(saying: script, speed: reportedSpeed ?? speed)
            texts[ObjectIdentifier(speech.buffer)] = script.text
            return speech
        }

        static func duration(ofWords count: Int) -> TimeInterval {
            leadingSilence + Double(count) * wordDuration + trailingSilence
        }

        private static func speech(saying script: SpeechScript, speed: Double) -> RenderedSpeech {
            let text = script.text
            var ranges: [Range<Int>] = []
            var start: Int?
            for (offset, unit) in text.utf16.enumerated() {
                if unit == 0x20 {
                    if let wordStart = start { ranges.append(wordStart..<offset) }
                    start = nil
                } else if start == nil {
                    start = offset
                }
            }
            if let start { ranges.append(start..<text.utf16.count) }

            let duration = duration(ofWords: ranges.count)
            let speechEnd = leadingSilence + Double(ranges.count) * wordDuration
            let frames = AVAudioFrameCount((duration * format.sampleRate).rounded())
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            // A title has no words, so no markers.
            let wordStarts = Set(script.wordRanges.map(\.lowerBound))
            let markers = ranges.enumerated().compactMap { position, range in
                wordStarts.contains(range.lowerBound)
                    ? SpeechMarker(utf16Range: range, time: leadingSilence + Double(position) * wordDuration)
                    : nil
            }
            let frameCount = Int((duration / SpeechLoudness.frameDuration).rounded())
            let loudness = (0..<frameCount).map { frame -> Float in
                let middle = (Double(frame) + 0.5) * SpeechLoudness.frameDuration
                return middle > leadingSilence && middle < speechEnd ? 0.5 : 0
            }
            return RenderedSpeech(buffer: buffer, markers: markers, loudness: loudness, speed: speed,
                                  hasExactMarkers: true)
        }
    }

    /// Takes chunks and reports where the listener is, as a test sets it.
    @MainActor
    private final class FakePlayer: SpeechPlaying {
        var speed: Float = 1
        var onChunkFinished: ((Int) -> Void)?
        var onFailure: ((any Error) -> Void)?
        private(set) var queue: [(id: Int, speech: RenderedSpeech)] = []
        private(set) var enqueueCount = 0
        private(set) var isPlaying = false
        private(set) var stopCount = 0
        var playError: (any Error)?
        var position: (id: Int, time: TimeInterval)?

        func enqueue(_ speech: RenderedSpeech, id: Int) {
            queue.append((id, speech))
            enqueueCount += 1
        }

        func play() throws {
            if let playError { throw playError }
            isPlaying = true
        }

        func stop() {
            stopCount += 1
            queue = []
            position = nil
            isPlaying = false
        }

        func currentPosition() -> (id: Int, time: TimeInterval)? {
            position
        }
    }

    /// A pacer reading through the fakes, recording its events and
    /// stopping it the way the engine pauses.
    @MainActor
    private final class Harness {
        let renderer = FakeRenderer()
        let player = FakePlayer()
        let paces = VoicePaceStore()
        let pacer: ReadAloudPacer
        private(set) var events: [PacerEvent] = []
        /// An event the engine answers by pausing, besides the end and a failure.
        var stopsOn: PacerEvent?

        init() {
            pacer = ReadAloudPacer(renderer: renderer, player: player, voiceIdentifier: "test", paces: paces)
            pacer.onEvent = { [unowned self] event in
                events.append(event)
                if event == .finished || event == .failed || event == stopsOn {
                    pacer.stop()
                }
            }
        }

        func start(
            _ words: [String],
            at startIndex: Int = 0,
            wordsPerMinute: Int = 300,
            chapters: [Int: String] = [:],
            readingStarts: [Int: Int] = [:],
            announcesChapterAtStart: Bool = false,
            sentenceBreaks: Bool = false
        ) async {
            pacer.start(PacerContext(
                words: words,
                startIndex: startIndex,
                chapters: Dictionary(uniqueKeysWithValues: chapters.map { ($0.key, Chapter(title: $0.value, wordIndex: $0.key)) }),
                readingStarts: readingStarts,
                announcesChapterAtStart: announcesChapterAtStart,
                wordsPerMinute: wordsPerMinute,
                timing: ReaderSettings.TimingSnapshot(
                    smartTimingEnabled: false,
                    sentencePauseEnabled: false,
                    smartTimingPercentPerLetter: 4,
                    smartTimingMinimumWordLength: 1,
                    sentencePauseMultiplier: 1.5,
                    complexityTimingEnabled: false,
                    complexityIntensity: 0.5,
                    punctuationPauses: PunctuationPauses(),
                    sentenceBreakEnabled: sentenceBreaks,
                    sentenceBreakLength: 1
                )
            ))
            await settle()
        }

        /// Lets renders finish and the pacer take them.
        func settle() async {
            for _ in 0..<3 {
                for _ in 0..<20 { await Task.yield() }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        /// Puts the listener `time` seconds into the `unit`th unit the
        /// player was given, and lets the pacer follow.
        func hear(_ unit: Int, at time: TimeInterval) {
            player.position = (player.queue[unit].id, time)
            pacer.tick()
        }

        /// What the `unit`th unit the player was given says; nil for silence.
        func text(ofQueued unit: Int) -> String? {
            renderer.texts[ObjectIdentifier(player.queue[unit].speech.buffer)]
        }
    }

    private static let threeSentences = "One two three. Four five six. Seven eight nine."
        .split(separator: " ").map(String.init)

    // MARK: - Starting

    @Test func startsOnTheWordShowing() async {
        let harness = Harness()
        await harness.start(Self.threeSentences)
        #expect(harness.events == [.word(0)])
        #expect(harness.renderer.requests.map(\.text) == ["One two three.", "Four five six.", "Seven eight nine."])
        #expect(harness.player.isPlaying)
        #expect(harness.text(ofQueued: 0) == "One two three.")
    }

    @Test func startsWithTheChapterTitle() async {
        let harness = Harness()
        let words = "Chapter One The sea was calm. It was late.".split(separator: " ").map(String.init)
        await harness.start(words, chapters: [0: "Chapter One"], readingStarts: [0: 2], announcesChapterAtStart: true)
        #expect(harness.events == [.chapterTitle(at: 0, isVisible: true)])
        // The title, the silence of its fade, then the words after it.
        #expect(harness.text(ofQueued: 0) == "Chapter One")
        #expect(harness.text(ofQueued: 1) == nil)
        #expect(abs(harness.player.queue[1].speech.duration - RSVPEngine.chapterFadeDuration) < 0.001)
        #expect(harness.text(ofQueued: 2) == "The sea was calm.")

        harness.hear(0, at: 0.5)
        #expect(harness.events.count == 1)
        harness.hear(1, at: 0.1)
        #expect(harness.events.last == .chapterTitle(at: 0, isVisible: false))
        // The faded title holds through the silence before the first word.
        harness.hear(2, at: 0.1)
        #expect(harness.events.count == 2)
        harness.hear(2, at: 0.25)
        #expect(harness.events == [
            .chapterTitle(at: 0, isVisible: true),
            .chapterTitle(at: 0, isVisible: false),
            .word(2),
        ])
    }

    @Test func aTitleAlreadyShownIsNotSaidAgain() async {
        let harness = Harness()
        let words = "Chapter One The sea was calm.".split(separator: " ").map(String.init)
        await harness.start(words, at: 2, chapters: [0: "Chapter One"], readingStarts: [0: 2])
        #expect(harness.events == [.word(2)])
        #expect(harness.renderer.requests.first?.text == "The sea was calm.")
    }

    @Test func laterChaptersAreAnnouncedWhenReached() async {
        let harness = Harness()
        let words = "It ended. Two It began.".split(separator: " ").map(String.init)
        await harness.start(words, chapters: [2: "Two"], readingStarts: [2: 3])
        #expect(harness.renderer.requests.map(\.text) == ["It ended.", "Two", "It began."])
        harness.hear(1, at: 0.3)
        #expect(harness.events == [.word(0), .chapterTitle(at: 2, isVisible: true)])
        harness.hear(2, at: 0.1)
        harness.hear(3, at: 0.25)
        #expect(harness.events.suffix(2) == [.chapterTitle(at: 2, isVisible: false), .word(3)])
    }

    // MARK: - Following the voice

    @Test func wordsFollowTheVoiceThroughAChunk() async {
        let harness = Harness()
        await harness.start(Self.threeSentences)
        // Before the audio is heard, and in the silence before the first
        // word, the first word stays.
        harness.hear(0, at: -0.1)
        harness.hear(0, at: 0.1)
        harness.hear(0, at: 0.35)
        #expect(harness.events == [.word(0)])
        harness.hear(0, at: 0.55)
        #expect(harness.events == [.word(0), .word(1)])
        harness.hear(0, at: 0.95)
        harness.hear(0, at: 1.15)
        #expect(harness.events == [.word(0), .word(1), .word(2)])
    }

    @Test func wordsMoveIntoTheNextChunk() async {
        let harness = Harness()
        await harness.start(Self.threeSentences)
        #expect(harness.player.queue.count == 2)
        harness.hear(0, at: 1.15)
        // The silence before the next chunk's first word keeps the last word.
        harness.hear(1, at: 0.1)
        #expect(harness.events.last == .word(2))
        harness.hear(1, at: 0.25)
        #expect(harness.events.last == .word(3))
        // Moving on hands the player the chunk after.
        #expect(harness.player.queue.count == 3)
        #expect(harness.text(ofQueued: 2) == "Seven eight nine.")
        // Words passed over between checks are skipped, never sent late.
        harness.hear(2, at: 0.55)
        #expect(harness.events == [.word(0), .word(2), .word(3), .word(7)])
    }

    @Test func aSentenceBreakIsSilenceAfterTheVoice() async {
        let harness = Harness()
        await harness.start(Self.threeSentences, sentenceBreaks: true)
        #expect(harness.text(ofQueued: 0) == "One two three.")
        #expect(harness.text(ofQueued: 1) == nil)
        // One word's time at 300 wpm.
        #expect(abs(harness.player.queue[1].speech.duration - 0.2) < 0.001)
        #expect(harness.player.queue[1].speech.markers.isEmpty)
        #expect(harness.text(ofQueued: 2) == "Four five six.")

        harness.hear(0, at: 0.95)
        #expect(harness.events.last == .word(2))
        // The blank starts once the voice falls silent.
        harness.hear(0, at: 1.12)
        #expect(harness.events.last == .sentenceBreak)
        harness.hear(1, at: 0.1)
        harness.hear(2, at: 0.1)
        #expect(harness.events.last == .sentenceBreak)
        harness.hear(2, at: 0.25)
        #expect(harness.events == [.word(0), .word(2), .sentenceBreak, .word(3)])
    }

    @Test func noSentenceBreakWhenTheSettingIsOff() async {
        let harness = Harness()
        await harness.start(Self.threeSentences, sentenceBreaks: false)
        #expect(harness.text(ofQueued: 1) == "Four five six.")
        harness.hear(0, at: 1.15)
        harness.hear(1, at: 0.25)
        #expect(!harness.events.contains(.sentenceBreak))
    }

    @Test func chunksWithNothingToSayAreSkipped() async {
        let harness = Harness()
        let words = ["Intro", "ends.", "***", "Next", "part", "begins."]
        await harness.start(words, at: 2, chapters: [3: "Two"])
        #expect(harness.events == [.word(2)])
        #expect(harness.renderer.requests.map(\.text) == ["Two", "Next part begins."])
        harness.hear(0, at: 0.3)
        harness.hear(1, at: 0.1)
        harness.hear(2, at: 0.25)
        #expect(harness.events == [
            .word(2),
            .chapterTitle(at: 3, isVisible: true),
            .chapterTitle(at: 3, isVisible: false),
            .word(3),
        ])
    }

    @Test func onlyMarksLeftFinishesAtOnce() async {
        let harness = Harness()
        await harness.start(["One", "two.", "***", "\u{2022}"], at: 2)
        harness.pacer.tick()
        #expect(harness.renderer.requests.isEmpty)
        #expect(harness.events == [.word(2), .finished])
        #expect(!harness.pacer.isRunning)
    }

    // MARK: - Finishing

    @Test func finishesOnceTheLastChunkHasPlayed() async {
        let harness = Harness()
        let words = "One two. Three four.".split(separator: " ").map(String.init)
        await harness.start(words, sentenceBreaks: true)
        // No break after the last sentence.
        #expect(harness.player.queue.count == 3)
        #expect(harness.text(ofQueued: 2) == "Three four.")
        let end = FakeRenderer.duration(ofWords: 2)
        harness.hear(2, at: 0.55)
        harness.hear(2, at: end - 0.05)
        #expect(harness.events.last == .word(3))
        #expect(harness.pacer.isRunning)
        harness.hear(2, at: end)
        #expect(harness.events.last == .finished)
        #expect(!harness.pacer.isRunning)
        #expect(harness.player.stopCount >= 1)
    }

    @Test func finishesWhenThePlayerReportsTheLastChunkPlayed() async {
        let harness = Harness()
        await harness.start(["One", "two."])
        harness.hear(0, at: 0.55)
        let id = harness.player.queue[0].id
        harness.player.onChunkFinished?(id)
        #expect(harness.events == [.word(0), .word(1), .finished])
    }

    // MARK: - Speed

    /// Each render's speed reads at the speed of the moment with the pace
    /// learned so far, and each chunk of words teaches the pace at the speed
    /// it was rendered at.
    @Test func rendersFollowTheLearnedPace() async {
        let harness = Harness()
        await harness.start(Self.threeSentences, wordsPerMinute: 240)
        #expect(harness.renderer.requests.count == 3)
        var pace = VoicePace()
        for request in harness.renderer.requests {
            let speed = SpeechRate.renderSpeed(forWordsPerMinute: 240, pace: pace)
            #expect(abs(request.speed - speed) < 1e-9)
            let count = request.script.words.count
            pace.learn(wordCount: count, duration: FakeRenderer.duration(ofWords: count), speed: request.speed)
        }
        // The fake voice takes as long at any speed, so it seems to slow.
        #expect(pace.naturalWordsPerMinute < VoicePace.initialWordsPerMinute)
        #expect(abs(harness.paces["test"].naturalWordsPerMinute - pace.naturalWordsPerMinute) < 1e-6)
    }

    /// A title teaches nothing: it has no words to count.
    @Test func titlesDontTeachThePace() async {
        let harness = Harness()
        await harness.start(["Two"], chapters: [0: "Two"], readingStarts: [0: 1], announcesChapterAtStart: true)
        #expect(harness.renderer.requests.map(\.text) == ["Two"])
        #expect(harness.paces["test"] == VoicePace())
    }

    @Test func aSpeedChangeStretchesWhatPlays() async {
        let harness = Harness()
        let natural = Int(VoicePace.initialWordsPerMinute)
        await harness.start(Self.threeSentences, wordsPerMinute: natural)
        // Read at the voice's natural pace, as far as the pacer knows.
        let first = harness.renderer.requests[0]
        let renderedFor = SpeechRate.wordsPerMinute(atSpeed: first.speed, pace: VoicePace())
        #expect(abs(renderedFor - Double(natural)) < 1e-9)
        harness.hear(0, at: 0.2)
        // Audio rendered for the speed plays as rendered.
        #expect(harness.player.speed == 1)

        // A small change stretches what's rendered.
        let small = natural * 21 / 20
        harness.pacer.speedDidChange(wordsPerMinute: small)
        #expect(abs(Double(harness.player.speed) - SpeechRate.playbackSpeed(wordsPerMinute: Double(small), renderedFor: renderedFor)) < 0.001)
        await harness.settle()
        #expect(harness.renderer.requests.count == 3)

        // A large one renders again what the player doesn't have yet.
        let large = natural * 13 / 10
        harness.pacer.speedDidChange(wordsPerMinute: large)
        #expect(abs(Double(harness.player.speed) - SpeechRate.playbackSpeed(wordsPerMinute: Double(large), renderedFor: renderedFor)) < 0.001)
        await harness.settle()
        #expect(harness.renderer.requests.count == 4)
        #expect(harness.renderer.requests[3].text == "Seven eight nine.")
        #expect(harness.renderer.requests[3].speed > harness.renderer.requests[2].speed)
        #expect(harness.player.queue.count == 2)
    }

    /// Past the fastest render speed, playback stretches the rest of the way.
    @Test func fastReadingRendersAtTheTopSpeedAndStretches() async {
        let harness = Harness()
        await harness.start(Self.threeSentences, wordsPerMinute: 450)
        let top = SpeechRate.renderSpeedRange.upperBound
        #expect(harness.renderer.requests.allSatisfy { $0.speed == top })
        harness.hear(0, at: 0.2)
        let renderedFor = SpeechRate.wordsPerMinute(atSpeed: top, pace: VoicePace())
        #expect(harness.player.speed > 1)
        #expect(abs(Double(harness.player.speed) - SpeechRate.playbackSpeed(wordsPerMinute: 450, renderedFor: renderedFor)) < 0.001)
    }

    /// Audio rendered slower than asked for, as its speed says, plays
    /// stretched the rest of the way.
    @Test func playbackMakesUpASpeedTheRendererDidntReach() async {
        let harness = Harness()
        harness.renderer.reportedSpeed = 1
        let natural = VoicePace.initialWordsPerMinute
        let wordsPerMinute = Int(natural * 1.3)
        await harness.start(Self.threeSentences, wordsPerMinute: wordsPerMinute)
        #expect(harness.renderer.requests[0].speed > 1.2)
        harness.hear(0, at: 0.2)
        #expect(abs(Double(harness.player.speed) - Double(wordsPerMinute) / natural) < 0.001)
    }

    /// A speed change while the listener waits for a render keeps it:
    /// starting over would only keep them waiting longer. It plays
    /// stretched, and what follows renders for the new speed.
    @Test func aRenderTheListenerWaitsForIsKeptThroughASpeedChange() async {
        let harness = Harness()
        let natural = Int(VoicePace.initialWordsPerMinute)
        harness.renderer.holdsRenders = true
        await harness.start(Self.threeSentences, wordsPerMinute: natural)
        let faster = natural * 14 / 10
        harness.pacer.speedDidChange(wordsPerMinute: faster)
        await harness.settle()
        #expect(harness.renderer.cancellations == 0)
        #expect(harness.renderer.requests.count == 1)

        harness.renderer.holdsRenders = false
        await harness.settle()
        #expect(harness.events == [.word(0)])
        #expect(harness.text(ofQueued: 0) == "One two three.")
        let renderedFor = SpeechRate.wordsPerMinute(atSpeed: harness.renderer.requests[0].speed, pace: VoicePace())
        #expect(abs(Double(harness.player.speed) - Double(faster) / renderedFor) < 0.001)
        #expect(harness.renderer.requests.count == 3)
        #expect(harness.renderer.requests[1].speed > harness.renderer.requests[0].speed)
    }

    /// A render ahead of what's heard starts over for a large speed change.
    @Test func aRenderAheadStartsOverForALargeSpeedChange() async {
        let harness = Harness()
        let natural = Int(VoicePace.initialWordsPerMinute)
        let words = "One two three. Four five six. Seven eight nine. Ten eleven twelve."
            .split(separator: " ").map(String.init)
        await harness.start(words, wordsPerMinute: natural)
        harness.renderer.holdsRenders = true
        // Moving on plans the fourth sentence and starts rendering it.
        harness.hear(1, at: 0.25)
        await harness.settle()
        #expect(harness.renderer.requests.count == 4)
        #expect(harness.player.queue.count == 3)

        harness.pacer.speedDidChange(wordsPerMinute: natural * 14 / 10)
        await harness.settle()
        #expect(harness.renderer.cancellations == 1)
        #expect(harness.renderer.requests.count == 5)
        #expect(harness.renderer.requests[4].text == "Ten eleven twelve.")
        #expect(harness.renderer.requests[4].speed > harness.renderer.requests[3].speed)

        harness.renderer.holdsRenders = false
        await harness.settle()
        harness.hear(2, at: 0.25)
        #expect(harness.text(ofQueued: 3) == "Ten eleven twelve.")
    }

    // MARK: - Waiting

    /// The first render after launch can take seconds while the voice model
    /// loads. Reading waits on the word it started on, however long that
    /// takes, and nothing fails.
    @Test func aSlowFirstRenderIsWaitedFor() async {
        let harness = Harness()
        harness.renderer.holdsRenders = true
        await harness.start(Self.threeSentences)
        // Ten seconds of the pacer's checks.
        for _ in 0..<600 { harness.pacer.tick() }
        await harness.settle()
        #expect(harness.pacer.isRunning)
        #expect(harness.events == [.word(0)])
        #expect(harness.renderer.requests.count == 1)
        #expect(harness.renderer.cancellations == 0)
        #expect(!harness.player.isPlaying)

        harness.renderer.holdsRenders = false
        await harness.settle()
        #expect(harness.player.isPlaying)
        #expect(harness.text(ofQueued: 0) == "One two three.")
        harness.hear(0, at: 0.55)
        #expect(harness.events == [.word(0), .word(1)])
    }

    // MARK: - Stopping

    @Test func stopSilencesEverything() async {
        let harness = Harness()
        await harness.start(Self.threeSentences)
        harness.hear(0, at: 0.55)
        harness.pacer.stop()
        #expect(!harness.pacer.isRunning)
        #expect(harness.player.stopCount == 1)
        let events = harness.events
        harness.player.position = (1, 0.9)
        harness.pacer.tick()
        harness.pacer.speedDidChange(wordsPerMinute: 400)
        await harness.settle()
        #expect(harness.events == events)
        // Stopping again does nothing.
        harness.pacer.stop()
        #expect(harness.player.stopCount == 1)
    }

    @Test func stopCancelsARenderUnderWay() async {
        let harness = Harness()
        harness.renderer.holdsRenders = true
        await harness.start(Self.threeSentences)
        #expect(harness.renderer.requests.count == 1)
        harness.pacer.stop()
        await harness.settle()
        #expect(harness.renderer.cancellations == 1)
        harness.renderer.holdsRenders = false
        await harness.settle()
        #expect(harness.player.enqueueCount == 0)
        #expect(harness.events == [.word(0)])
    }

    @Test func stoppingInAnswerToAnEventSendsNothingMore() async {
        let harness = Harness()
        harness.stopsOn = .word(1)
        await harness.start(Self.threeSentences)
        harness.hear(0, at: 0.55)
        #expect(!harness.pacer.isRunning)
        harness.player.position = (1, 0.9)
        harness.pacer.tick()
        #expect(harness.events == [.word(0), .word(1)])
    }

    // MARK: - Failing

    @Test func aRenderFailureFails() async {
        let harness = Harness()
        harness.renderer.failure = TestError()
        await harness.start(Self.threeSentences)
        #expect(harness.events == [.word(0), .failed])
        #expect(!harness.pacer.isRunning)
    }

    @Test func aPlayerFailureFails() async {
        let harness = Harness()
        await harness.start(Self.threeSentences)
        harness.player.onFailure?(TestError())
        #expect(harness.events == [.word(0), .failed])

        let refused = Harness()
        refused.player.playError = TestError()
        await refused.start(Self.threeSentences)
        #expect(refused.events == [.word(0), .failed])
    }
}
