import Accelerate
import AVFAudio
import FluidAudio
import Foundation
import os

/// Renders scripts with a Kokoro voice, each word's start taken from the
/// model's own timing.
///
/// Each word of a script is phonemized on its own, from the part of the
/// script's text that reads it (``KokoroSpokenText``), and the words'
/// phonemes are joined into one line (``KokoroPhonemeLine``) that the model
/// renders in one go, so it phrases the chunk as a whole. The model
/// predicts how many frames each phoneme lasts, which places every word in
/// the audio exactly (``KokoroWordTiming``). A line longer than the model
/// takes is rendered in parts, split between words, and a word too long for
/// it alone is cut short.
///
/// Phonemes are kept by spoken text for as long as the renderer lives, so a
/// word the document repeats is phonemized once. A word the phonemizer
/// failed on for now, rather than for good, isn't kept, and is tried again
/// the next time it's read.
final class KokoroSpeechRenderer: SpeechRendering {
    /// The Kokoro voice it reads with, such as `af_heart`.
    let voice: String

    private let model: KokoroVoiceModel
    private let generation: Int
    private let encodable: Set<Unicode.Scalar>
    private var phonemeCache: [String: String] = [:]

    /// The most phoneme symbols the model renders at once.
    static let phonemeLimit = KokoroAneConstants.maxPhonemeLength

    /// The cache is emptied when it holds this many words.
    static let phonemeCacheLimit = 20_000

    /// How long the audio for a script with nothing to say lasts.
    static let silenceDuration: TimeInterval = 0.1

    /// - Parameters:
    ///   - model: The model that loads the voice. Each render asks it for
    ///     the loaded model, which loads it again if it was unloaded.
    ///   - generation: The model's generation when the renderer was made,
    ///     so a renderer outliving the model's files never loads them again.
    ///   - vocabulary: The phoneme symbols the model reads.
    init(model: KokoroVoiceModel, generation: Int, voice: String, vocabulary: KokoroAneVocab) {
        self.model = model
        self.generation = generation
        self.voice = voice
        encodable = Set(vocabulary.map.keys.flatMap(\.unicodeScalars))
    }

    func render(_ script: SpeechScript, speed: Double) async throws -> RenderedSpeech {
        try Task.checkCancellation()
        let manager = try await model.loadedManager(for: generation)
        try Task.checkCancellation()
        let speed = speed.isFinite && speed > 0 ? speed : 1

        let wordPhonemes: [String]
        if script.words.isEmpty {
            wordPhonemes = try await titlePhonemes(script.text, with: manager)
        } else {
            var phonemes: [String] = []
            phonemes.reserveCapacity(script.words.count)
            let utf16 = script.text.utf16
            for range in script.wordRanges {
                guard !range.isEmpty else {
                    phonemes.append("")
                    continue
                }
                let start = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
                let end = utf16.index(start, offsetBy: range.count)
                phonemes.append(try await self.phonemes(for: String(script.text[start..<end]), with: manager))
            }
            wordPhonemes = phonemes
        }

        var samples: [Float] = []
        var markers: [SpeechMarker] = []
        // The markers of each part's first word.
        var firstMarkers: [Int] = []
        var isExact = true
        let sampleRate = Double(KokoroAneConstants.sampleRate)
        for (part, line) in KokoroPhonemeLine.lines(for: wordPhonemes, limit: Self.phonemeLimit) {
            guard line.length > 0 else { continue }
            try Task.checkCancellation()
            let result = try await manager.synthesizeFromPhonemesDetailed(line.text, voice: voice, speed: Float(speed))
            try Task.checkCancellation()

            let offset = Double(samples.count) / sampleRate
            let timing = KokoroWordTiming.startTimes(
                for: line,
                durations: result.predictedDurations,
                audioDuration: Double(result.samples.count) / Double(result.sampleRate)
            )
            if !timing.isExact {
                isExact = false
                Self.logger.debug("Kokoro gave \(result.predictedDurations.count) durations for \(line.length + 2) tokens")
            }
            if !script.words.isEmpty {
                firstMarkers.append(markers.count)
                for (position, start) in timing.startTimes.enumerated() {
                    guard let start else { continue }
                    markers.append(SpeechMarker(utf16Range: script.wordRanges[part.lowerBound + position], time: offset + start))
                }
            }
            samples += result.samples
        }
        if samples.isEmpty {
            samples = [Float](repeating: 0, count: Int(Self.silenceDuration * sampleRate))
        }
        return try await Self.speech(
            samples: samples,
            sampleRate: sampleRate,
            markers: markers,
            firstMarkers: firstMarkers.filter(markers.indices.contains),
            speed: speed,
            isExact: isExact
        )
    }

    // MARK: - Phonemes

    /// The phonemes for one word's spoken text, cleaned for the line; empty
    /// when the phonemizer finds nothing to say, as for an emoji, or failed.
    private func phonemes(for spoken: String, with manager: KokoroAneManager) async throws -> String {
        if let cached = phonemeCache[spoken] {
            return cached
        }
        let plan = KokoroSpokenText.plan(for: spoken)
        let output = plan.text.isEmpty ? "" : try await phonemize(plan.text, with: manager)
        let raw: String?
        if let output, let fixed = plan.phonemes(fromPhonemizerOutput: output) {
            raw = fixed
        } else if output != nil {
            raw = try await phonemize(KokoroSpokenText.withoutAccents(spoken), with: manager)
        } else {
            raw = nil
        }
        // The phonemizer failed for now: the word goes unread this time, and
        // isn't kept, so it's tried again the next time it comes up.
        guard let raw else { return "" }
        let cleaned = KokoroPhonemeLine.cleaned(raw) { encodable.contains($0) }
        if phonemeCache.count >= Self.phonemeCacheLimit {
            phonemeCache.removeAll(keepingCapacity: true)
        }
        phonemeCache[spoken] = cleaned
        return cleaned
    }

    /// A chapter title's phonemes, phonemized whole, as groups of the line:
    /// it has no words to place, and it can be split anywhere between
    /// groups when it's too long to render at once.
    private func titlePhonemes(_ title: String, with manager: KokoroAneManager) async throws -> [String] {
        let text = KokoroSpokenText.readingApproximations(in: KokoroSpokenText.withoutAccents(title))
        guard !text.isEmpty else { return [] }
        let output = try await phonemize(text, with: manager) ?? ""
        let cleaned = KokoroPhonemeLine.cleaned(output) { encodable.contains($0) }
        return cleaned.split(separator: " ").map(String.init)
    }

    /// The phonemizer's output for `text`: empty when it finds nothing to
    /// say, as it will every time, and nil when it failed in a way that can
    /// pass, as when its fallback model's prediction fails. Only
    /// cancellation throws: a word the phonemizer can't read is left unread
    /// rather than stopping the chunk.
    private func phonemize(_ text: String, with manager: KokoroAneManager) async throws -> String? {
        try Task.checkCancellation()
        let phonemes: String
        do {
            phonemes = try await manager.englishPhonemes(for: text)
        } catch KokoroAneError.inputProcessingFailed(_) {
            // Nothing in the text it can say, such as an emoji.
            try Task.checkCancellation()
            return ""
        } catch {
            try Task.checkCancellation()
            Self.logger.error("Couldn't phonemize a word: \(error)")
            return nil
        }
        try Task.checkCancellation()
        return phonemes
    }

    // MARK: - Audio

    /// The rendered speech for `samples`, Kokoro's mono audio, with its
    /// loudness, worked out off the main actor. The markers at `firstMarkers`,
    /// each the first of a part, move to where the part is first heard.
    @concurrent
    nonisolated private static func speech(
        samples: [Float],
        sampleRate: Double,
        markers: [SpeechMarker],
        firstMarkers: [Int],
        speed: Double,
        isExact: Bool
    ) async throws -> RenderedSpeech {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw RenderError.couldNotMakeBuffer
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        let loudness = loudness(of: samples, sampleRate: sampleRate)
        var markers = markers
        for index in firstMarkers {
            let marker = markers[index]
            let start = KokoroWordTiming.firstWordStart(marker.time, loudness: loudness, frameDuration: SpeechLoudness.frameDuration)
            markers[index] = SpeechMarker(utf16Range: marker.utf16Range, time: start)
        }
        return RenderedSpeech(
            buffer: buffer,
            markers: markers,
            loudness: loudness,
            speed: speed,
            hasExactMarkers: isExact
        )
    }

    /// The RMS of `samples` in each ``SpeechLoudness/frameDuration``, the
    /// last frame however much of one is left.
    nonisolated static func loudness(of samples: [Float], sampleRate: Double) -> [Float] {
        let frameLength = max(1, Int((SpeechLoudness.frameDuration * sampleRate).rounded()))
        let count = (samples.count + frameLength - 1) / frameLength
        var loudness = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for frame in 0..<count {
                let start = frame * frameLength
                let length = min(frameLength, samples.count - start)
                vDSP_rmsqv(base + start, 1, &loudness[frame], vDSP_Length(length))
            }
        }
        return loudness
    }

    private enum RenderError: Error {
        case couldNotMakeBuffer
    }

    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.abdeen.strobe",
        category: "ReadAloud"
    )
}
