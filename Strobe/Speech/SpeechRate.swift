import Foundation

/// Converts between reading speeds and the speed the voice model renders at.
///
/// Kokoro renders at a speed multiplier, 1 being the voice's natural pace,
/// by dividing the duration it predicts for every sound by it. Sounds last
/// whole 25 ms frames, at least one each, so a voice's words per minute grow
/// a little less than the speed (``paceCurve``). A voice is described by its
/// words per minute at 1 (``VoicePace``), and the curve scales that.
///
/// Within ``renderSpeedRange`` the voice still sounds natural. A reading
/// speed past either end renders at that end and stretches playback the rest
/// of the way (``playbackSpeed(wordsPerMinute:renderedFor:)``).
nonisolated enum SpeechRate {

    /// The speeds a chunk is rendered at. Past about 1.33, most sounds reach
    /// the one-frame floor at once: the pace jumps, then hardly grows, and
    /// the voice runs its sounds together. Slower than the bottom, it drags
    /// them out. Time stretching keeps them clearer past either end.
    static let renderSpeedRange: ClosedRange<Double> = 0.85...1.3

    /// The most a chunk is stretched or squeezed to play at another speed.
    /// The top lets a voice as slow as 140 wpm reach the read-aloud cap from
    /// the fastest render speed.
    static let playbackSpeedRange: ClosedRange<Double> = 0.5...3.0

    /// How a voice's pace grows with the render speed, as a multiple of its
    /// natural pace, measured on Kokoro's `af_heart` reading sentence by
    /// sentence. Straight between the points, and in proportion to the speed
    /// past the ends.
    static let paceCurve: [(speed: Double, pace: Double)] = [
        (0.8, 0.80), (0.85, 0.88), (0.9, 0.93), (1.0, 1.0), (1.1, 1.06), (1.2, 1.15), (1.3, 1.24),
    ]

    /// The multiple of its natural pace a voice reads at when rendered at
    /// `speed`.
    static func paceMultiplier(atSpeed speed: Double) -> Double {
        interpolate(speed, along: paceCurve.map { ($0.speed, $0.pace) })
    }

    /// The render speed at which a voice reads at `multiplier` times its
    /// natural pace: the inverse of ``paceMultiplier(atSpeed:)``.
    static func speed(forPaceMultiplier multiplier: Double) -> Double {
        interpolate(multiplier, along: paceCurve.map { ($0.pace, $0.speed) })
    }

    /// The speed to render at so a voice whose pace is `pace` reads at
    /// `wordsPerMinute`, held to ``renderSpeedRange``.
    /// ``wordsPerMinute(atSpeed:pace:)`` gives the reading speed it reaches.
    static func renderSpeed(forWordsPerMinute wordsPerMinute: Double, pace: VoicePace) -> Double {
        let multiplier = wordsPerMinute / pace.naturalWordsPerMinute
        guard multiplier.isFinite else { return 1 }
        let speed = speed(forPaceMultiplier: multiplier)
        return min(max(speed, renderSpeedRange.lowerBound), renderSpeedRange.upperBound)
    }

    /// The reading speed of a voice whose pace is `pace`, rendered at
    /// `speed`.
    static func wordsPerMinute(atSpeed speed: Double, pace: VoicePace) -> Double {
        pace.naturalWordsPerMinute * paceMultiplier(atSpeed: speed)
    }

    /// How much faster than recorded to play a chunk rendered to read at
    /// `renderedFor` words per minute so it reads at `wordsPerMinute`, as
    /// past the ends of ``renderSpeedRange``, or when the speed changes
    /// during reading. Clamped to ``playbackSpeedRange``; 1 when either
    /// speed isn't positive.
    static func playbackSpeed(wordsPerMinute: Double, renderedFor: Double) -> Double {
        guard wordsPerMinute > 0, renderedFor > 0 else { return 1 }
        return min(max(wordsPerMinute / renderedFor, playbackSpeedRange.lowerBound), playbackSpeedRange.upperBound)
    }

    /// The value of the line through `points` (sorted by `x`, both
    /// increasing) at `x`; past either end, `x` in proportion to that end.
    private static func interpolate(_ x: Double, along points: [(x: Double, y: Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return x }
        if x <= first.x { return x * first.y / first.x }
        if x >= last.x { return x * last.y / last.x }
        for (lower, upper) in zip(points, points.dropFirst()) where x <= upper.x {
            return lower.y + (x - lower.x) / (upper.x - lower.x) * (upper.y - lower.y)
        }
        return x * last.y / last.x
    }
}

/// How fast a voice reads at its natural pace (render speed 1), learned
/// from the chunks it renders.
///
/// Voices differ, and so do texts: long words and many pauses read slower.
/// Each rendered chunk is a measurement, counted by its length at the
/// natural pace, so a short chunk with proportionally more silence around it
/// moves the estimate little, and the speed a chunk was rendered at doesn't
/// change how much it counts. The estimate remembers about ``memory``
/// seconds of speech, so it follows the text as it changes.
nonisolated struct VoicePace: Hashable, Codable, Sendable {

    /// The estimate before a voice has read anything. Kokoro's `af_heart`
    /// reads 167 wpm sentence by sentence, silences included, and
    /// `am_michael` 147.
    static let initialWordsPerMinute = 165.0

    /// How many seconds of speech the initial estimate counts as.
    static let initialEvidence: TimeInterval = 5

    /// The most speech, in seconds at the natural pace, the estimate is
    /// based on. Past this, a new chunk of `d` such seconds moves the
    /// estimate `d / (memory + d)` of the way to its own measurement.
    static let memory: TimeInterval = 60

    /// Speeds at the natural pace a measurement is held to, so a chunk that
    /// is mostly silence, or one long number, can't throw the estimate off.
    static let plausibleWordsPerMinute: ClosedRange<Double> = 80...400

    /// Chunks shorter than this, in seconds at the natural pace, aren't
    /// measured.
    static let minimumDuration: TimeInterval = 0.25

    /// The voice's estimated speed at render speed 1, in the reader's words
    /// per minute of audio, pauses included.
    private(set) var naturalWordsPerMinute: Double

    /// The seconds of speech at the natural pace behind the estimate, up to
    /// ``memory``.
    private(set) var evidence: TimeInterval

    init(naturalWordsPerMinute: Double = VoicePace.initialWordsPerMinute) {
        self.naturalWordsPerMinute = naturalWordsPerMinute
        self.evidence = Self.initialEvidence
    }

    /// Counts a chunk of `wordCount` words that took `duration` seconds of
    /// audio, silence included, rendered at `speed`.
    mutating func learn(wordCount: Int, duration: TimeInterval, speed: Double) {
        guard wordCount > 0, duration.isFinite, speed.isFinite, speed > 0 else { return }
        // How long the chunk would have taken at the natural pace.
        let naturalDuration = duration * SpeechRate.paceMultiplier(atSpeed: speed)
        guard naturalDuration >= Self.minimumDuration else { return }
        let measured = Double(wordCount) / naturalDuration * 60
        let observed = min(max(measured, Self.plausibleWordsPerMinute.lowerBound),
                           Self.plausibleWordsPerMinute.upperBound)
        naturalWordsPerMinute = (naturalWordsPerMinute * evidence + observed * naturalDuration)
            / (evidence + naturalDuration)
        evidence = min(evidence + naturalDuration, Self.memory)
    }
}
