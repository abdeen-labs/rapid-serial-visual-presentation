import Foundation
import Observation

/// Reading aloud in an open reader. Once the words load, with the setting
/// on, an English document, and the voice model on disk, it gets the chosen
/// voice from ``KokoroVoiceModel``, gives the engine a ``ReadAloudPacer``
/// that reads with it, caps the speed at
/// ``ReaderSettings/readAloudWPMRange``'s top, and pauses and resumes
/// around audio interruptions.
///
/// Until a voice is ready (the model downloading, or its first load
/// compiling it for the device), the words go on without one. A voice that
/// gets ready while they play takes over at the next pause, rather than
/// stopping reading to start.
@Observable
final class ReadAloudController {
    /// Whether a voice reads the engine's words.
    private(set) var isReadingAloud = false

    /// Whether the voices read the document: English, or too little text to
    /// tell. True until its language is known.
    private(set) var canReadDocument = true

    /// The document's language once known (`en`, `fr`), or nil while it
    /// isn't, or when there was too little text to tell.
    private(set) var documentLanguage: String?

    /// Whether the voice model is on disk, so the reader can ask it for a
    /// voice. Follows the model's state without redrawing the reader as a
    /// download moves.
    private(set) var isModelOnDisk = false

    /// Why the voice couldn't get ready for this reader, when the model's
    /// state doesn't say, as when it won't load one voice.
    private(set) var failure: String?

    /// Changes with each Try Again, to set reading aloud up again.
    private(set) var attempt = 0

    /// Whether the reader wants the voice model loaded: a voice reads, or
    /// one is on its way (``VoiceModelUse``).
    private(set) var usesVoiceModel = false

    /// Whether the reader's scene is in the foreground. An interruption
    /// that ends while it isn't leaves reading paused, as leaving the
    /// foreground does.
    @ObservationIgnored var isInForeground = true

    @ObservationIgnored private weak var engine: RSVPEngine?
    /// The voice reading.
    @ObservationIgnored private var current: Voice?
    /// A voice that got ready while the words played; it reads from the
    /// next pause.
    @ObservationIgnored private var waiting: Voice?
    @ObservationIgnored private var session: ReadAloudAudioSession?
    /// The document's language, once detected (nil inside when there was
    /// too little text to tell).
    @ObservationIgnored private var detectedLanguage: String??
    /// Reading aloud was playing when an interruption began.
    @ObservationIgnored private var resumesAfterInterruption = false
    @ObservationIgnored private var followsModel = false

    /// A Kokoro voice, by name, and what renders it.
    private struct Voice {
        let name: String
        let renderer: any SpeechRendering
    }

    /// What reading aloud depends on. A change sets it up again.
    struct Setup: Equatable {
        var isEnabled: Bool
        /// Whether the engine has the document's words.
        var isLoaded: Bool
        /// The chosen voice's name (``KokoroVoices/chosen(_:)``).
        var voice: String
        var isModelOnDisk: Bool
        var attempt: Int
    }

    /// What reading aloud depends on, from the reader's part of it: the
    /// setting, whether the words have loaded, and the chosen voice.
    func setup(isEnabled: Bool, isLoaded: Bool, voice: String) -> Setup {
        Setup(isEnabled: isEnabled, isLoaded: isLoaded, voice: voice, isModelOnDisk: isModelOnDisk, attempt: attempt)
    }

    /// Reads `engine`'s words aloud with the chosen voice, or stops reading
    /// aloud, as `setup` says. Also tells the document's language, whatever
    /// the setting, for the reader's button.
    func update(_ setup: Setup, engine: RSVPEngine) async {
        self.engine = engine
        followModel()
        guard setup.isLoaded, !engine.words.isEmpty else {
            turnOff()
            return
        }
        let language = await detectLanguage(of: engine.words)
        guard !Task.isCancelled else { return }
        canReadDocument = KokoroVoices.canRead(documentLanguage: language)
        guard setup.isEnabled, canReadDocument, isModelOnDisk else {
            turnOff()
            return
        }
        if setup.voice == current?.name {
            waiting = nil
            return
        }
        guard setup.voice != waiting?.name else { return }
        usesVoiceModel = true
        do {
            // The first load compiles the model for the device, which can
            // take a while; the words play on without a voice meanwhile.
            let renderer = try await KokoroVoiceModel.shared.renderer(voice: setup.voice)
            guard !Task.isCancelled else { return }
            failure = nil
            read(Voice(name: setup.voice, renderer: renderer))
        } catch {
            // A change to the setup cancels this, and sets up again.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            turnOff()
            failure = error.localizedDescription
        }
    }

    /// What the reader's Read Aloud button shows and does. Reads the
    /// model's state, download progress included.
    func availability(isEnabled: Bool) -> ReadAloudAvailability {
        ReadAloudAvailability(
            isEnabled: isEnabled,
            canReadDocument: canReadDocument,
            model: ReadAloudAvailability.ModelState(KokoroVoiceModel.shared.state),
            isReadingAloud: isReadingAloud,
            readerFailure: failure
        )
    }

    /// Tries the voice again: the model's download or load if that failed,
    /// and the reader's voice.
    func retry() {
        failure = nil
        attempt += 1
        if case .failed = KokoroVoiceModel.shared.state {
            VoiceModelUse.install()
        }
    }

    /// Playback paused: a voice that got ready while the words played takes
    /// over now.
    func playbackDidPause() {
        guard let waiting else { return }
        read(waiting)
    }

    /// Gives the engine a new pacer reading with `voice`, unless the words
    /// are playing, in which case it waits for the next pause.
    private func read(_ voice: Voice) {
        guard let engine else { return }
        guard !engine.isPlaying else {
            waiting = voice
            return
        }
        waiting = nil
        engine.pacer = ReadAloudPacer(
            renderer: voice.renderer,
            player: SpeechPlayer(),
            voiceIdentifier: voice.name,
            session: session ?? makeSession()
        )
        engine.speedCap = Int(ReaderSettings.readAloudWPMRange.upperBound)
        current = voice
        isReadingAloud = true
    }

    private func turnOff() {
        if let engine {
            if engine.pacer != nil { engine.pacer = nil }
            if engine.speedCap != nil { engine.speedCap = nil }
        }
        current = nil
        waiting = nil
        isReadingAloud = false
        usesVoiceModel = false
        failure = nil
        resumesAfterInterruption = false
    }

    /// Keeps ``isModelOnDisk`` to the model's state from the first update
    /// on. Only a change to it is set, so the reader doesn't redraw with
    /// every step of a download.
    private func followModel() {
        guard !followsModel else { return }
        followsModel = true
        observeModel()
    }

    private func observeModel() {
        let state = withObservationTracking {
            KokoroVoiceModel.shared.state
        } onChange: { [weak self] in
            // Called before the change; read it once it's made.
            Task { @MainActor [weak self] in self?.observeModel() }
        }
        let isOnDisk = ReadAloudAvailability.ModelState(state).isOnDisk
        if isOnDisk != isModelOnDisk { isModelOnDisk = isOnDisk }
    }

    /// The language of `words`, detected off the main actor the first time.
    private func detectLanguage(of words: [String]) async -> String? {
        if let detectedLanguage { return detectedLanguage }
        let sample = Array(words.prefix(DocumentLanguage.sampleWordCount))
        let language = await Task.detached(priority: .userInitiated) {
            DocumentLanguage.detect(in: sample)
        }.value
        detectedLanguage = .some(language)
        documentLanguage = language
        return language
    }

    // MARK: - Audio session

    private func makeSession() -> ReadAloudAudioSession {
        let session = ReadAloudAudioSession()
        session.onInterruptionBegan = { [weak self] in
            self?.interruptionBegan()
        }
        session.onInterruptionEnded = { [weak self] shouldResume in
            self?.interruptionEnded(shouldResume: shouldResume)
        }
        session.onOutputLost = { [weak self] in
            self?.outputLost()
        }
        session.onMediaServicesReset = { [weak self] in
            self?.mediaServicesWereReset()
        }
        self.session = session
        return session
    }

    private func interruptionBegan() {
        guard isReadingAloud, let engine else { return }
        resumesAfterInterruption = engine.isPlaying
        if engine.isPlaying { engine.pause() }
    }

    /// Reads on if the system says to, reading aloud was playing when the
    /// interruption began, and the reader is still in the foreground.
    private func interruptionEnded(shouldResume: Bool) {
        defer { resumesAfterInterruption = false }
        guard shouldResume, resumesAfterInterruption, isInForeground, isReadingAloud,
              let engine, !engine.isPlaying else { return }
        engine.play()
    }

    /// Headphones went away: pause rather than go on through the speaker.
    private func outputLost() {
        resumesAfterInterruption = false
        guard isReadingAloud, let engine, engine.isPlaying else { return }
        engine.pause()
    }

    /// Every audio object is dead: read on with a new pacer and player. The
    /// renderer still works, since it makes its audio without them.
    private func mediaServicesWereReset() {
        resumesAfterInterruption = false
        guard isReadingAloud, let engine, let current else { return }
        if engine.isPlaying { engine.pause() }
        read(current)
    }
}

extension ReadAloudAvailability.ModelState {
    init(_ state: KokoroVoiceModel.State) {
        switch state {
        case .notInstalled: self = .notInstalled
        case .downloading(let fraction): self = .downloading(fraction: fraction)
        case .installed: self = .installed
        case .preparing: self = .preparing
        case .ready: self = .ready
        case .failed(let message): self = .failed(message: message)
        }
    }
}
