import AVFAudio
import Foundation
import os

/// Reads a document aloud and moves the reader along with the voice: each
/// word shows when the voice says it (see ``WordPacer``).
///
/// Reading is planned as a queue of units, in the order they're heard:
///
/// - a chapter's title, said while it shows, then the silence while it
///   fades (``RSVPEngine/chapterFadeDuration``);
/// - the words of about a sentence (``SpeechChunker``), said as written in
///   their ``SpeechScript``; a run with nothing to say (`***`) is passed
///   over;
/// - with sentence breaks on, the silence of the blank after a sentence.
///
/// Spoken units are rendered one at a time, up to ``spokenUnitsAhead``
/// past the one being heard, and handed to the player once less than
/// ``queuedAudioTarget`` of audio is left before it runs out. About 60 times
/// a second, the pacer asks the player where the listener is and turns it
/// into events: a word once its start in the unit's ``SpeechSchedule`` has
/// come, a title or its fade when its unit starts, a sentence break once the
/// voice falls silent before one, and the end once the last unit has played.
///
/// Each unit is rendered at the voice speed that reads at the moment's words
/// per minute, as far as the voice's learned ``VoicePace`` can tell, within
/// ``SpeechRate/renderSpeedRange``, and played stretched the rest of the way
/// (``SpeechRate``). A speed change stretches what's playing at once. Units
/// rendered ahead that a new rendering would make more than
/// ``rerenderThreshold`` faster or slower are rendered again; those already
/// with the player stay stretched, and so does a unit the listener is
/// waiting for.
///
/// Rendering can take a while, most of all the first time after launch,
/// while the voice model loads and compiles. Reading waits as long as it
/// takes, on the word or title it started on; only a rendering or playback
/// failure stops it, sending ``PacerEvent/failed``.
final class ReadAloudPacer: WordPacer {
    var onEvent: ((PacerEvent) -> Void)?

    /// How many spoken units are rendered ahead of the one heard.
    static let spokenUnitsAhead = 2

    /// The player is handed the next unit once less than this much audio,
    /// in seconds, is queued past what's heard: well before the player's
    /// own margin, with room for a busy main thread.
    static let queuedAudioTarget: TimeInterval = 1.5

    /// How much faster or slower than a unit rendered ahead a new rendering
    /// has to be for the unit to be rendered again after a speed change.
    static let rerenderThreshold = 0.15

    /// How often the pacer checks where the listener is.
    static let tickInterval: TimeInterval = 1.0 / 60

    /// How long a chapter title with nothing to say (only marks) shows:
    /// the shortest time the reader shows a title for without a voice.
    static let silentTitleDuration: TimeInterval = 1.6

    /// How close to its end a unit counts as played out. The player can
    /// resample a unit, which moves its end by a frame or two.
    static let endTolerance: TimeInterval = 0.02

    private let renderer: any SpeechRendering
    private let player: any SpeechPlaying
    private let voiceIdentifier: String
    private let session: ReadAloudAudioSession?
    private let paces: VoicePaceStore

    // MARK: Reading state

    private(set) var isRunning = false
    /// Changes with every start, so an event's answer can tell that reading
    /// stopped and started again in between.
    private var runID = 0
    private var context: PacerContext?
    private var chapterStarts: Set<Int> = []
    private var wordsPerMinute = 0
    /// What to plan after the last unit planned; nil once the document's
    /// end is planned.
    private var nextStep: Step?
    /// The unit heard first, then those after it. Units are dropped once a
    /// later one is heard.
    private var units: [Unit] = []
    private var nextUnitID = 0
    /// The last word sent, so words only move forward.
    private var lastWordSent: Int?
    private var rendering: Rendering?
    private var renderTask: Task<Void, Never>?
    private var renderCount = 0
    private var isPlayerStarted = false
    /// Whether the audio session is active for this run, so the player can
    /// start. It activates off the main thread while the first unit renders.
    private var isSessionReady = false
    /// The format silence is made in: that of the voice's audio, once it
    /// has rendered some.
    private var silenceFormat: AVAudioFormat?
    private var timer: Timer?

    /// - Parameters:
    ///   - voiceIdentifier: The voice `renderer` reads with, a Kokoro voice
    ///     name such as `af_heart`, whose pace the pacer learns and keeps in
    ///     `paces`.
    ///   - session: Activated whenever reading starts, and deactivated when
    ///     it stops. Nil leaves the audio session alone.
    init(
        renderer: any SpeechRendering,
        player: any SpeechPlaying,
        voiceIdentifier: String,
        session: ReadAloudAudioSession? = nil,
        paces: VoicePaceStore = .shared
    ) {
        self.renderer = renderer
        self.player = player
        self.voiceIdentifier = voiceIdentifier
        self.session = session
        self.paces = paces
        player.onChunkFinished = { [weak self] id in
            self?.unitPlayedOut(id)
        }
        player.onFailure = { [weak self] error in
            guard let self, self.isRunning else { return }
            self.fail(error)
        }
    }

    deinit {
        // Let go of while reading: the run loop would keep the timer.
        timer?.invalidate()
        renderTask?.cancel()
    }

    // MARK: - WordPacer

    func start(_ context: PacerContext) {
        stop()
        isRunning = true
        runID += 1
        self.context = context
        chapterStarts = Set(context.chapters.keys)
        wordsPerMinute = context.wordsPerMinute
        let start = min(max(context.startIndex, 0), context.words.count)
        let announcesTitle = context.announcesChapterAtStart && context.chapters[start] != nil
        nextStep = announcesTitle ? .title(start) : .words(start)
        if let session {
            isSessionReady = false
            let run = runID
            Task { [weak self] in
                do {
                    try await session.activate()
                    guard let self, self.isRunning, self.runID == run else { return }
                    self.isSessionReady = true
                    self.feedPlayer()
                } catch {
                    guard let self, self.isRunning, self.runID == run else { return }
                    self.fail(error)
                }
            }
        } else {
            isSessionReady = true
        }
        extendPlan()

        // Reading starts on the title, or on the word already showing.
        if announcesTitle {
            units.first?.hasStarted = true
            guard send(.chapterTitle(at: start, isVisible: true)) else { return }
        } else if context.words.indices.contains(start) {
            lastWordSent = start
            guard send(.word(start)) else { return }
        }

        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refill()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        renderTask?.cancel()
        renderTask = nil
        rendering = nil
        player.stop()
        isPlayerStarted = false
        units = []
        nextStep = nil
        context = nil
        lastWordSent = nil
        session?.deactivate()
    }

    func speedDidChange(wordsPerMinute: Int) {
        self.wordsPerMinute = wordsPerMinute
        guard isRunning else { return }
        if let heard = heardUnit() ?? units.first {
            applySpeed(for: heard)
        }
        let renderingFor = renderedSpeed()
        for unit in units where !unit.isEnqueued && unit.audio != nil {
            // Silence is made for the speed itself.
            let newSpeed = unit.content.script == nil ? Double(wordsPerMinute) : renderingFor
            if Self.differs(unit.renderedFor, from: newSpeed) {
                unit.audio = nil
                unit.schedule = nil
            }
        }
        // A render under way that's too far off starts again, unless the
        // listener has nothing left to hear: then starting again would only
        // keep them waiting longer, as through the first render after launch.
        if let rendering, Self.differs(rendering.renderedFor, from: renderingFor),
           queuedAudio() > Self.endTolerance {
            renderTask?.cancel()
            renderTask = nil
            self.rendering = nil
        }
        refill()
    }

    // MARK: - Following the listener

    /// Follows the listener through the units: called about 60 times a
    /// second while reading. Internal so tests can move the listener on by
    /// hand.
    func tick() {
        guard isRunning else { return }
        if units.isEmpty, nextStep == nil, rendering == nil {
            // Nothing left to say, as when only marks are left.
            finish()
            return
        }
        guard let position = player.currentPosition(),
              let index = units.firstIndex(where: { $0.id == position.id }) else {
            refill()
            return
        }
        // The units before the one heard have played. One too short for a
        // tick still sends what its start means, so events keep their order.
        for unit in units[..<index] {
            guard begin(unit) else { return }
        }
        units.removeFirst(index)
        let unit = units[0]
        guard begin(unit) else { return }
        applySpeed(for: unit)
        guard follow(unit, at: position.time) else { return }

        if units.count == 1, nextStep == nil, let audio = unit.audio,
           unit.playedOut || position.time >= audio.duration - Self.endTolerance {
            finish()
            return
        }
        refill()
    }

    /// Sends what the start of `unit` means, once.
    /// - Returns: Whether reading goes on.
    private func begin(_ unit: Unit) -> Bool {
        guard !unit.hasStarted else { return true }
        unit.hasStarted = true
        switch unit.content {
        case .title(let chapter, _):
            return send(.chapterTitle(at: chapter, isVisible: true))
        case .titleFade(let chapter):
            return send(.chapterTitle(at: chapter, isVisible: false))
        case .sentenceBreak:
            return send(.sentenceBreak)
        case .words:
            // A word shows when the voice reaches it, so the one before
            // stays through the silence that leads into the unit.
            return true
        }
    }

    /// Sends the word the voice is saying `time` seconds into `unit`, and a
    /// sentence break once the voice falls silent before one.
    /// - Returns: Whether reading goes on.
    private func follow(_ unit: Unit, at time: TimeInterval) -> Bool {
        guard case .words(let script) = unit.content, let schedule = unit.schedule else { return true }
        if let position = schedule.wordPosition(at: time) {
            let index = script.wordIndices.lowerBound + position
            if lastWordSent.map({ index > $0 }) ?? true {
                lastWordSent = index
                guard send(.word(index)) else { return false }
            }
        }
        if time >= schedule.speechEnd, units.count > 1, case .sentenceBreak = units[1].content,
           !units[1].hasStarted {
            units[1].hasStarted = true
            return send(.sentenceBreak)
        }
        return true
    }

    private func unitPlayedOut(_ id: Int) {
        guard isRunning else { return }
        units.first { $0.id == id }?.playedOut = true
        tick()
    }

    /// The unit the listener is hearing, if the player has started.
    private func heardUnit() -> Unit? {
        guard let position = player.currentPosition() else { return nil }
        return units.first { $0.id == position.id }
    }

    /// Plays `unit` at the speed of the moment. The stretch is rounded to a
    /// thousandth, so audio rendered for the speed plays at exactly 1 rather
    /// than a hair off it, as floating point can leave it, which would run
    /// it through the player's time pitch for nothing.
    private func applySpeed(for unit: Unit) {
        let stretch = SpeechRate.playbackSpeed(wordsPerMinute: Double(wordsPerMinute), renderedFor: unit.renderedFor)
        let speed = Float((stretch * 1000).rounded() / 1000)
        if player.speed != speed {
            player.speed = speed
        }
    }

    // MARK: - Planning

    /// What comes next in the document.
    private enum Step: Equatable {
        /// The title of the chapter starting at this index.
        case title(Int)
        /// The words from this index.
        case words(Int)
    }

    private enum Content {
        case title(chapterAt: Int, script: SpeechScript)
        case titleFade(chapterAt: Int)
        case words(SpeechScript)
        case sentenceBreak

        /// What the voice says; nil for silence, as for a title of only
        /// marks.
        var script: SpeechScript? {
            switch self {
            case .title(_, let script), .words(let script): script.text.isEmpty ? nil : script
            case .titleFade, .sentenceBreak: nil
            }
        }
    }

    private final class Unit {
        let id: Int
        let content: Content
        var audio: RenderedSpeech?
        /// When each word starts, for words.
        var schedule: SpeechSchedule?
        /// The speed the audio reads at as rendered, in words per minute.
        var renderedFor: Double = 0
        var isEnqueued = false
        /// Whether what its start means has been sent.
        var hasStarted = false
        var playedOut = false

        init(id: Int, content: Content) {
            self.id = id
            self.content = content
        }
    }

    /// Plans units until ``spokenUnitsAhead`` spoken ones follow the one
    /// heard, or the document's end is planned.
    private func extendPlan() {
        guard let context else { return }
        while let step = nextStep,
              units.count(where: { $0.content.script != nil }) <= Self.spokenUnitsAhead {
            switch step {
            case .title(let start):
                let title = context.chapters[start]?.title ?? ""
                append(.title(chapterAt: start, script: SpeechScript(title: title)))
                append(.titleFade(chapterAt: start))
                // Reading goes on past the words that repeat the title,
                // where another chapter can start.
                let resume = context.readingStarts[start] ?? start
                if resume != start, context.chapters[resume] != nil {
                    nextStep = .title(resume)
                } else {
                    nextStep = context.words.indices.contains(resume) ? .words(resume) : nil
                }
            case .words(let start):
                let range = SpeechChunker.chunk(startingAt: start, in: context.words, chapterStarts: chapterStarts)
                let script = SpeechScript(words: context.words, range: range)
                if !script.text.isEmpty {
                    append(.words(script))
                    if breaksAfter(range, in: context) {
                        append(.sentenceBreak)
                    }
                }
                let end = range.upperBound
                if range.isEmpty || !context.words.indices.contains(end) {
                    nextStep = nil
                } else {
                    nextStep = context.chapters[end] != nil ? .title(end) : .words(end)
                }
            }
        }
    }

    private func append(_ content: Content) {
        nextUnitID += 1
        units.append(Unit(id: nextUnitID, content: content))
    }

    /// Whether a sentence break follows the words in `range`, as it does
    /// for the same word in playback without a voice.
    private func breaksAfter(_ range: Range<Int>, in context: PacerContext) -> Bool {
        let last = range.upperBound - 1
        guard context.timing.sentenceBreakEnabled, last >= 0, last + 1 < context.words.count else { return false }
        return RSVPEngine.breaksAfterWord(
            at: last,
            in: context.words,
            nextWordStartsChapter: context.chapters[last + 1] != nil,
            timing: context.timing
        )
    }

    // MARK: - Rendering

    /// A render under way.
    private struct Rendering {
        let unitID: Int
        /// Tells this render's result from that of one dropped since.
        let number: Int
        /// The voice's pace when the render started.
        let pace: VoicePace
        /// The speed asked for.
        let speed: Double

        /// The reading speed the audio is expected to read at.
        var renderedFor: Double {
            SpeechRate.wordsPerMinute(atSpeed: speed, pace: pace)
        }
    }

    /// Plans, renders, and hands the player what comes next.
    private func refill() {
        extendPlan()
        renderNext()
        feedPlayer()
    }

    /// Starts rendering the first unit without audio, after making the
    /// silence of any silent units before it.
    private func renderNext() {
        guard isRunning, rendering == nil else { return }
        for unit in units where unit.audio == nil {
            if let script = unit.content.script {
                render(unit, script: script)
                return
            }
            guard makeSilence(for: unit) else { return }
        }
    }

    private func render(_ unit: Unit, script: SpeechScript) {
        let pace = paces[voiceIdentifier]
        let speed = SpeechRate.renderSpeed(forWordsPerMinute: Double(wordsPerMinute), pace: pace)
        renderCount += 1
        let rendering = Rendering(unitID: unit.id, number: renderCount, pace: pace, speed: speed)
        self.rendering = rendering
        let renderer = renderer
        renderTask = Task { [weak self] in
            let result: Result<RenderedSpeech, any Error>
            do {
                result = .success(try await renderer.render(script, speed: speed))
            } catch {
                result = .failure(error)
            }
            self?.finishRendering(rendering, with: result)
        }
    }

    private func finishRendering(_ finished: Rendering, with result: Result<RenderedSpeech, any Error>) {
        // A render dropped for a speed change, or one from before a stop,
        // changes nothing.
        guard isRunning, rendering?.number == finished.number else { return }
        rendering = nil
        renderTask = nil
        let speech: RenderedSpeech
        switch result {
        case .success(let rendered):
            speech = rendered
        case .failure(let error):
            fail(error)
            return
        }
        if let unit = units.first(where: { $0.id == finished.unitID }) {
            unit.audio = speech
            // The speed the audio says it was rendered at, should the
            // renderer not reach the one asked for.
            let speed = speech.speed.isFinite && speech.speed > 0 ? speech.speed : finished.speed
            unit.renderedFor = SpeechRate.wordsPerMinute(atSpeed: speed, pace: finished.pace)
            silenceFormat = speech.buffer.format
            if case .words(let script) = unit.content {
                unit.schedule = SpeechSchedule(script: script, speech: speech)
                paces[voiceIdentifier].learn(wordCount: script.words.count, duration: speech.duration, speed: speed)
            }
        }
        refill()
    }

    /// The reading speed a unit rendered now would read at.
    private func renderedSpeed() -> Double {
        let pace = paces[voiceIdentifier]
        let speed = SpeechRate.renderSpeed(forWordsPerMinute: Double(wordsPerMinute), pace: pace)
        return SpeechRate.wordsPerMinute(atSpeed: speed, pace: pace)
    }

    /// Whether audio rendered for `renderedFor` reads more than
    /// ``rerenderThreshold`` faster or slower than a new rendering would.
    private static func differs(_ renderedFor: Double, from renderingFor: Double) -> Bool {
        guard renderedFor > 0, renderingFor > 0 else { return true }
        return abs(renderingFor / renderedFor - 1) > rerenderThreshold
    }

    /// Gives a silent unit its audio: a zeroed buffer in the voice's format.
    /// - Returns: Whether reading goes on.
    private func makeSilence(for unit: Unit) -> Bool {
        let duration: TimeInterval
        switch unit.content {
        case .titleFade:
            duration = RSVPEngine.chapterFadeDuration
        case .sentenceBreak:
            duration = RSVPEngine.sentenceBreakInterval(
                timing: context?.timing ?? ReaderSettings.timingSnapshot(),
                baseInterval: 60 / Double(max(1, wordsPerMinute))
            )
        case .title, .words:
            duration = Self.silentTitleDuration
        }
        let format = silenceFormat ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        guard let format, let silence = Self.silence(lasting: duration, in: format) else {
            fail(ReadAloudError.couldNotMakeSilence)
            return false
        }
        unit.audio = silence
        // Stretched with the speed like the rest, so a sentence break keeps
        // to its number of words' time.
        unit.renderedFor = Double(wordsPerMinute)
        return true
    }

    /// `duration` seconds of silence in `format`, as speech with no words.
    private static func silence(lasting duration: TimeInterval, in format: AVAudioFormat) -> RenderedSpeech? {
        let frames = AVAudioFrameCount(max(1, (duration * format.sampleRate).rounded()))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = channel.mData {
                memset(data, 0, Int(channel.mDataByteSize))
            }
        }
        let loudness = [Float](repeating: 0, count: Int((duration / SpeechLoudness.frameDuration).rounded(.up)))
        return RenderedSpeech(buffer: buffer, markers: [], loudness: loudness, speed: 1, hasExactMarkers: true)
    }

    // MARK: - Playing

    /// Hands the player the next rendered units, in order, while less than
    /// ``queuedAudioTarget`` of audio is queued past what's heard, and
    /// starts it with the first.
    private func feedPlayer() {
        guard isRunning else { return }
        var queued = queuedAudio()
        for unit in units where !unit.isEnqueued {
            guard let audio = unit.audio, queued < Self.queuedAudioTarget else { break }
            if !isPlayerStarted, !units.contains(where: \.isEnqueued) {
                applySpeed(for: unit)
            }
            player.enqueue(audio, id: unit.id)
            unit.isEnqueued = true
            queued += audio.duration / Double(max(player.speed, 0.1))
        }
        guard !isPlayerStarted, isSessionReady, units.contains(where: \.isEnqueued) else { return }
        do {
            try player.play()
            isPlayerStarted = true
        } catch {
            fail(error)
        }
    }

    /// The seconds of audio with the player that the listener hasn't heard.
    private func queuedAudio() -> TimeInterval {
        let position = player.currentPosition()
        var seconds = 0.0
        for unit in units where unit.isEnqueued {
            guard let audio = unit.audio else { continue }
            if let position, position.id == unit.id {
                seconds += max(0, audio.duration - position.time)
            } else {
                seconds += audio.duration
            }
        }
        return seconds / Double(max(player.speed, 0.1))
    }

    // MARK: - Events

    /// Sends `event` while reading.
    /// - Returns: Whether reading goes on: the engine can stop the pacer
    ///   in answer, as it does at the end.
    @discardableResult
    private func send(_ event: PacerEvent) -> Bool {
        guard isRunning else { return false }
        let run = runID
        onEvent?(event)
        return isRunning && runID == run
    }

    private func finish() {
        send(.finished)
        stop()
    }

    private func fail(_ error: any Error) {
        Self.logger.error("Reading aloud stopped: \(error)")
        send(.failed)
        stop()
    }

    private enum ReadAloudError: Error {
        case couldNotMakeSilence
    }

    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.abdeen.strobe",
        category: "ReadAloud"
    )
}

// MARK: - Playing speech

/// Plays rendered speech for ``ReadAloudPacer``: what it needs of
/// ``SpeechPlayer``, so tests can stand in for the audio.
protocol SpeechPlaying: AnyObject {
    /// How fast the audio plays, at the same pitch. Takes effect at once.
    var speed: Float { get set }
    /// Called with a chunk's ID once its audio has played out, in order.
    var onChunkFinished: ((Int) -> Void)? { get set }
    /// Called when playback stopped on its own.
    var onFailure: ((any Error) -> Void)? { get set }
    /// Queues a chunk after those already queued.
    func enqueue(_ speech: RenderedSpeech, id: Int)
    /// Starts playing, and plays chunks as they're queued.
    func play() throws
    /// Stops and drops every queued chunk.
    func stop()
    /// The chunk the listener hears and how far into it, in seconds of its
    /// rendered audio; nil with nothing queued since the last stop.
    func currentPosition() -> (id: Int, time: TimeInterval)?
}

extension SpeechPlayer: SpeechPlaying {}

// MARK: - Voice paces

/// How fast each voice reads (``VoicePace``), by voice identifier (a Kokoro
/// voice name such as `af_heart`), learned as it reads. Kept while the app
/// runs, so a reader opened later starts from what earlier ones learned.
final class VoicePaceStore {
    static let shared = VoicePaceStore()

    private var paces: [String: VoicePace] = [:]

    subscript(voiceIdentifier: String) -> VoicePace {
        get { paces[voiceIdentifier] ?? VoicePace() }
        set { paces[voiceIdentifier] = newValue }
    }
}
