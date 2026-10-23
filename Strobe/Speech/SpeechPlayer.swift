import AVFAudio
import Foundation
import os

/// Plays rendered speech chunks back to back through its own
/// `AVAudioEngine`: player node → time pitch → main mixer.
///
/// Each chunk is scheduled at a known frame of the player's timeline, so
/// ``currentPosition()`` can tell which chunk the listener hears and how far
/// into its audio, across chunks and pauses. ``speed`` changes the pace
/// live, at the same pitch.
///
/// Pausing stops the engine, and playing again schedules what's left from
/// where the listener was, on a fresh timeline. The same happens after the
/// engine stops on its own (an interruption, or a change of output device).
/// A paused engine would keep its resources, but it would leave the player's
/// render times off by the length of the pause. After the media services
/// reset, make a new player.
final class SpeechPlayer {
    /// How fast the rendered audio plays, at the same pitch: 1 as rendered,
    /// 1.5 in two thirds of the time. Takes effect at once.
    var speed: Float = 1 {
        didSet { applySpeed() }
    }

    /// The main mixer's output volume. 0 mutes playback without changing
    /// its timing.
    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    /// Called on the main actor with a chunk's ID once its audio has played
    /// out of the speaker, in the order the chunks were enqueued. Never
    /// called for chunks dropped by ``stop()``.
    var onChunkFinished: ((Int) -> Void)?

    /// Called on the main actor when playback stopped on its own, because
    /// the engine couldn't start again after the output changed. The player
    /// is paused where the listener was; ``play()`` tries again.
    var onFailure: ((any Error) -> Void)?

    /// Whether ``play()`` was called since the last pause or stop. Stays
    /// true while the queue is empty: chunks enqueued then play at once.
    private(set) var isPlaying = false

    /// Room left before audio scheduled after the queue ran dry, so the
    /// player hasn't already passed its start. Covers a render cycle at
    /// 2× with the 4096-frame buffers iOS uses while the screen is locked.
    private static let schedulingMargin: TimeInterval = 0.2

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    /// The format the player is connected with. Every scheduled buffer is in it.
    private var format: AVAudioFormat
    /// Chunks scheduled and not yet played out, in order.
    private var queue: [Entry] = []
    /// The chunk that played out last; its end can still be on its way to
    /// the speaker.
    private var lastFinished: Entry?
    private var nextSerial = 0
    /// Where the next chunk goes on the player's timeline, if the player
    /// hasn't passed it.
    private var nextStartFrame: AVAudioFramePosition = 0
    /// Completion handlers from before the last stop or rebuild carry an
    /// older generation and are ignored.
    private var generation = 0
    /// Whether the player has played on its current timeline, which then
    /// has to be rebuilt once the engine stops.
    private var timelineStarted = false
    /// While paused: where on the timeline the listener was.
    private var pausedFrame: Double?
    /// The furthest position reported since the timeline started over.
    /// Positions never go back: after a resume or a speed change, the
    /// latency estimate moves while the audio doesn't.
    private var heardFloor: Double?
    /// The host time of the last render when ``play()`` was called, until the
    /// engine renders again.
    private var renderAtPlay: UInt64?
    private var outputLatency: TimeInterval = 0
    private var configurationObserver: NSObjectProtocol?

    private struct Entry {
        let id: Int
        let serial: Int
        /// The whole chunk, in the player's format.
        let audio: AVAudioPCMBuffer
        /// Where the chunk's first frame falls on the player's timeline.
        /// After a rebuild that starts partway into the chunk, it's before
        /// the scheduled part.
        let start: AVAudioFramePosition
        var end: AVAudioFramePosition { start + AVAudioFramePosition(audio.frameLength) }
    }

    init() {
        // Kokoro's format; the first chunk reconnects if it differs.
        format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        engine.attach(player)
        engine.attach(timePitch)
        connect(format)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineConfigurationChanged() }
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        engine.stop()
    }

    // MARK: Playing

    /// Adds a chunk after those already queued. A chunk in another format
    /// than the queue's (another voice's) reconnects the engine when nothing
    /// is queued, and is converted otherwise.
    func enqueue(_ speech: RenderedSpeech, id: Int) {
        var audio = speech.buffer
        guard audio.frameLength > 0 else { return }
        if queue.isEmpty,
           let target = AVAudioFormat(
               standardFormatWithSampleRate: audio.format.sampleRate,
               channels: audio.format.channelCount
           ),
           target != format {
            reconnect(target)
        }
        if audio.format != format {
            guard let converted = Self.convert(audio, to: format) else {
                Self.logger.error("Couldn't convert speech from \(audio.format) to \(self.format)")
                return
            }
            audio = converted
        }
        var start = nextStartFrame
        if let rendered = renderedFrame() {
            // A buffer scheduled where the player has already been plays only
            // its rest, as after the queue ran dry.
            start = max(start, rendered + AVAudioFramePosition(Self.schedulingMargin * format.sampleRate))
        }
        nextSerial += 1
        schedule(Entry(id: id, serial: nextSerial, audio: audio, start: start), from: 0)
    }

    /// Starts or resumes playback. Activate the audio session first on iOS.
    func play() throws {
        guard !isPlaying || !engine.isRunning else { return }
        if timelineStarted && !engine.isRunning {
            // Paused, or stopped under the player.
            rebuild()
        }
        if !engine.isRunning {
            try engine.start()
        }
        try startPlayer()
        timelineStarted = true
        renderAtPlay = player.lastRenderTime?.hostTime
        if let pausedFrame { heardFloor = max(heardFloor ?? pausedFrame, pausedFrame) }
        pausedFrame = nil
        isPlaying = true
        refreshOutputLatency()
    }

    /// Pauses where the listener is, and stops the audio hardware.
    func pause() {
        guard isPlaying else { return }
        pausedFrame = heardFrame()
        // Stopping the engine completes every scheduled buffer; playing
        // again schedules what's left anew.
        generation += 1
        player.pause()
        engine.stop()
        isPlaying = false
    }

    /// Stops and drops every queued chunk, without calling
    /// ``onChunkFinished``. The next chunk enqueued starts the timeline over.
    func stop() {
        generation += 1
        player.stop()
        engine.stop()
        queue = []
        lastFinished = nil
        nextStartFrame = 0
        timelineStarted = false
        pausedFrame = nil
        heardFloor = nil
        isPlaying = false
    }

    // MARK: Position

    /// The chunk the listener hears and how far into it, in seconds of its
    /// rendered audio (not of sped-up playback), so it compares directly
    /// with its marker times.
    ///
    /// Allows for the time pitch's lookahead and the output's latency, and
    /// never goes back. Negative before the first chunk's audio reaches the
    /// speaker, as right after ``play()``. Between chunks, and once
    /// everything has played, it's the last chunk heard at its end. Nil with
    /// nothing enqueued since the last ``stop()``. Holds still while paused.
    func currentPosition() -> (id: Int, time: TimeInterval)? {
        let entries = (lastFinished.map { [$0] } ?? []) + queue
        guard let first = entries.first else { return nil }
        let frame = heardFrame()
        let sampleRate = format.sampleRate
        var position = (id: first.id, time: (frame - Double(first.start)) / sampleRate)
        for entry in entries where frame >= Double(entry.start) {
            position = (entry.id, (min(frame, Double(entry.end)) - Double(entry.start)) / sampleRate)
        }
        return position
    }

    /// The frame of the player's timeline the listener hears now.
    private func heardFrame() -> Double {
        if let pausedFrame { return pausedFrame }
        let sampleRate = format.sampleRate
        let speed = Double(timePitch.bypass ? 1 : timePitch.rate)
        // The time pitch reads ahead of what it plays by about its reported
        // latency, bypassed or not (85 ms at 1×, measured), and its output
        // then takes the output latency to be heard.
        let lag = (timePitch.latency + outputLatency) * sampleRate * speed
        var frame = -lag
        if isPlaying, engine.isRunning,
           let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
           let playerTime = player.playerTime(forNodeTime: nodeTime),
           nodeTime.hostTime != renderAtPlay {
            // Until the engine renders after `play()`, the last render is
            // from before it.
            renderAtPlay = nil
            frame = Double(playerTime.sampleTime) - lag
            if nodeTime.isHostTimeValid {
                // The render's host time is when its first frame leaves for
                // the output, a few milliseconds from now. Interpolating gives
                // a smooth position between render cycles.
                let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                frame += (now - AVAudioTime.seconds(forHostTime: nodeTime.hostTime)) * sampleRate * speed
            }
        }
        let heard = max(frame, heardFloor ?? frame)
        heardFloor = heard
        return heard
    }

    /// How far the player has rendered on its timeline, while it plays.
    private func renderedFrame() -> AVAudioFramePosition? {
        guard player.isPlaying,
              let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return nil }
        return playerTime.sampleTime
    }

    private func refreshOutputLatency() {
        #if os(iOS)
        outputLatency = AVAudioSession.sharedInstance().outputLatency
        #else
        outputLatency = engine.outputNode.presentationLatency
        #endif
    }

    // MARK: Scheduling

    /// Schedules `entry` from `offset` frames into its audio.
    private func schedule(_ entry: Entry, from offset: AVAudioFramePosition) {
        var audio = entry.audio
        if offset > 0 {
            guard let rest = Self.slice(entry.audio, from: AVAudioFrameCount(offset)) else { return }
            audio = rest
        }
        let serial = entry.serial
        let generation = generation
        player.scheduleBuffer(
            audio,
            at: AVAudioTime(sampleTime: entry.start + offset, atRate: format.sampleRate),
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            // On a background thread. Also called for buffers dropped by
            // stopping the player or the engine.
            DispatchQueue.main.async {
                self?.chunkPlayed(serial: serial, generation: generation)
            }
        }
        queue.append(entry)
        nextStartFrame = entry.end
    }

    private func chunkPlayed(serial: Int, generation: Int) {
        // An engine that stopped, as for an interruption, completes every
        // scheduled buffer without playing it.
        guard generation == self.generation, engine.isRunning,
              let index = queue.firstIndex(where: { $0.serial == serial })
        else { return }
        let played = queue[...index]
        queue.removeSubrange(...index)
        lastFinished = played.last
        for entry in played { onChunkFinished?(entry.id) }
    }

    /// Schedules what's left again, on a fresh timeline that starts where
    /// the listener was.
    private func rebuild() {
        let frame = pausedFrame ?? heardFloor ?? 0
        let shift = max(0, AVAudioFramePosition(frame.rounded(.down)))
        let finished = queue.filter { $0.end <= shift }
        let remaining = queue.filter { $0.end > shift }
        generation += 1
        player.stop()
        timelineStarted = false
        queue = []
        lastFinished = (finished.last ?? lastFinished).map {
            Entry(id: $0.id, serial: $0.serial, audio: $0.audio, start: $0.start - shift)
        }
        nextStartFrame = 0
        for entry in remaining {
            let offset = max(0, shift - entry.start)
            nextSerial += 1
            schedule(Entry(id: entry.id, serial: nextSerial, audio: entry.audio, start: nextStartFrame - offset), from: offset)
        }
        // Where the listener is on the new timeline: within a frame of its
        // start, or before it if nothing had been heard yet.
        let heard = frame - Double(shift)
        heardFloor = heard
        if pausedFrame != nil { pausedFrame = heard }
        for entry in finished { onChunkFinished?(entry.id) }
    }

    private func engineConfigurationChanged() {
        guard timelineStarted else { return }
        Self.logger.info("Audio engine configuration changed; scheduling speech again")
        let wasPlaying = isPlaying
        if wasPlaying {
            // The engine has stopped; the last position reported stands.
            pausedFrame = heardFloor ?? 0
            isPlaying = false
        }
        rebuild()
        guard wasPlaying else { return }
        do {
            try play()
        } catch {
            Self.logger.error("Couldn't restart speech after a configuration change: \(error)")
            onFailure?(error)
        }
    }

    // MARK: Engine

    private func applySpeed() {
        let rate = min(max(speed, 1 / 32), 32)
        timePitch.rate = rate
        timePitch.bypass = rate == 1
    }

    /// Connects the nodes for buffers in `newFormat`. Only while nothing is
    /// queued: it stops the player.
    private func reconnect(_ newFormat: AVAudioFormat) {
        player.stop()
        engine.stop()
        timelineStarted = false
        nextStartFrame = 0
        lastFinished = nil
        heardFloor = nil
        connect(newFormat)
        guard isPlaying else { return }
        do {
            try engine.start()
            try startPlayer()
            timelineStarted = true
        } catch {
            Self.logger.error("Couldn't restart speech in a new format: \(error)")
            isPlaying = false
            onFailure?(error)
        }
    }

    private func connect(_ newFormat: AVAudioFormat) {
        format = newFormat
        do {
            if #available(iOS 27.0, macOS 27.0, *) {
                try engine.connectNode(player, to: timePitch, format: newFormat)
                try engine.connectNode(timePitch, to: engine.mainMixerNode, format: newFormat)
            } else {
                engine.connect(player, to: timePitch, format: newFormat)
                engine.connect(timePitch, to: engine.mainMixerNode, format: newFormat)
            }
        } catch {
            Self.logger.error("Couldn't connect speech playback in \(newFormat): \(error)")
        }
    }

    private func startPlayer() throws {
        if #available(iOS 27.0, macOS 27.0, *) {
            try player.playAudio()
        } else {
            player.play()
        }
    }

    // MARK: Buffers

    /// `buffer` in `format`, resampled if its rate differs.
    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let input = ConverterInput(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            input.next(inputStatus)
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// `buffer` from `frame` on. `buffer` is in a deinterleaved float format.
    private static func slice(_ buffer: AVAudioPCMBuffer, from frame: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard frame < buffer.frameLength,
              let source = buffer.floatChannelData,
              let rest = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength - frame),
              let destination = rest.floatChannelData
        else { return nil }
        rest.frameLength = rest.frameCapacity
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel] + Int(frame), count: Int(rest.frameLength))
        }
        return rest
    }

    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.abdeen.strobe",
        category: "ReadAloud"
    )
}

/// Gives a converter one buffer, then the end of the stream.
nonisolated private final class ConverterInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .endOfStream
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
