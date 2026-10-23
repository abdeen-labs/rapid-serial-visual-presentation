import AVFAudio

/// The moment speech reaches part of its text: from `time` seconds into a
/// chunk's audio, the voice is saying the UTF-16 offsets `utf16Range` of the
/// text it was given.
nonisolated struct SpeechMarker: Equatable, Sendable {
    let utf16Range: Range<Int>
    let time: TimeInterval
}

/// One chunk of text rendered to audio, with where its words start.
/// `@unchecked Sendable`: the buffer is never changed once rendered.
nonisolated struct RenderedSpeech: @unchecked Sendable {
    /// The whole chunk, in the voice's own format.
    let buffer: AVAudioPCMBuffer
    /// Word markers, in the order the voice reported them.
    let markers: [SpeechMarker]
    /// How loud the audio is (RMS over all channels) in each
    /// `SpeechLoudness.frameDuration` from the start, for lining markers up
    /// with where speech actually begins.
    let loudness: [Float]
    /// The speed it was rendered at: 1 is the voice's natural pace, and 2
    /// takes half as long.
    let speed: Double
    /// Whether the markers come from the voice model's own timing, one per
    /// word, so they need no lining up with the loudness.
    let hasExactMarkers: Bool

    var duration: TimeInterval {
        Double(buffer.frameLength) / buffer.format.sampleRate
    }
}

nonisolated enum SpeechLoudness {
    static let frameDuration: TimeInterval = 0.01
}

/// Turns a chunk's script into speech audio. ``KokoroSpeechRenderer`` does
/// it with the Kokoro voice model.
protocol SpeechRendering: AnyObject {
    /// Renders `script` at `speed` (1 is the voice's natural pace). Marker
    /// ranges are UTF-16 offsets in `script.text`. A title script has no
    /// words, so its audio has no markers. Cancelling the calling task
    /// stops rendering as soon as it can and throws `CancellationError`.
    func render(_ script: SpeechScript, speed: Double) async throws -> RenderedSpeech
}
