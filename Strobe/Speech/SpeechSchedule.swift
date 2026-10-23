import Foundation

/// When each word of a rendered chunk starts, worked out from the voice's
/// markers and the loudness of its audio.
///
/// Exact markers (``RenderedSpeech/hasExactMarkers``), timed from the voice
/// model's own durations, stand as they are. Lining one up with the loudness
/// would only move it late: a word that opens on a quiet sound (`so`, `far`,
/// `here`) starts before its audio is loud enough to tell from silence. A
/// marker that would move back is still set aside, and words without one
/// are spread as below.
///
/// Other markers are taken as evidence rather than as the schedule itself:
///
/// - Most words get one marker. A number unit (`2000 BCE`, `10:30 PM`) can
///   get one for each half, and the first counts. A marker that would move
///   back, to an earlier word or an earlier time, is set aside: a range like
///   `1990–2000` can draw markers out of order. Of the markers, the most that
///   move forward together are kept.
/// - One marker can cover several words, up to a whole sentence, and some
///   voices report only phrases or nothing at all. Words without a marker of
///   their own share the time until the next marker, or until the voice falls
///   silent, by how long each takes to say (``weight(of:)``).
/// - A marker can come up to about 200 ms early, in the silence before its
///   word. One that lands in a silence moves to where the voice is next heard
///   if that's within ``earlyMarkerWindow``.
/// - Nothing is said before the voice is first heard or after it's last
///   heard, so leading and trailing silence come from the loudness alone.
nonisolated struct SpeechSchedule: Equatable, Sendable {

    /// When each word of the script starts, in seconds into the chunk's
    /// audio at the speed it was rendered: one for each of the script's
    /// words, never decreasing. A word that isn't read starts with the next
    /// word that is.
    let startTimes: [TimeInterval]

    /// When the voice is first heard, in seconds into the chunk's audio.
    /// With exact markers, no later than the first.
    let speechStart: TimeInterval

    /// When the voice is last heard. The rest of the chunk is silence. With
    /// exact markers, no earlier than the last.
    let speechEnd: TimeInterval

    /// How long after an early marker the voice may start for the marker to
    /// move there. Early markers measured 170–210 ms before their word.
    static let earlyMarkerWindow: TimeInterval = 0.25

    /// The voice is heard in a frame louder than this share of the chunk's
    /// loudest frame: 34 dB down, below a word's quietest sounds and above
    /// the silence between words.
    static let silenceLevel: Float = 0.02

    /// Frames this quiet are silent whatever the loudest frame is.
    static let minimumSilenceThreshold: Float = 0.001

    init(script: SpeechScript, speech: RenderedSpeech) {
        self.init(script: script, markers: speech.markers, loudness: speech.loudness, duration: speech.duration,
                  hasExactMarkers: speech.hasExactMarkers)
    }

    /// - Parameters:
    ///   - markers: The voice's markers for `script.text`, in the order it
    ///     reported them.
    ///   - loudness: The audio's loudness in each
    ///     ``SpeechLoudness/frameDuration``, as in ``RenderedSpeech``.
    ///   - duration: The audio's length in seconds.
    ///   - hasExactMarkers: Whether the markers are exact, as in
    ///     ``RenderedSpeech/hasExactMarkers``.
    init(
        script: SpeechScript,
        markers: [SpeechMarker],
        loudness: [Float],
        duration: TimeInterval,
        hasExactMarkers: Bool = false
    ) {
        let envelope = Envelope(loudness, duration: duration.isFinite ? max(0, duration) : 0)
        var speechStart = envelope.speechStart
        var speechEnd = max(envelope.speechEnd, speechStart)

        var anchors = Self.anchors(from: markers, in: script)
        if hasExactMarkers {
            for index in anchors.indices {
                anchors[index].time = min(anchors[index].time, envelope.length)
            }
            // A word starts at its marker even where the audio is quiet, so
            // the voice is heard from the first one at the latest.
            if let first = anchors.first, let last = anchors.last {
                speechStart = min(speechStart, first.time)
                speechEnd = max(speechEnd, last.time)
            }
        } else {
            for index in anchors.indices {
                var time = anchors[index].time
                let nextTime = index + 1 < anchors.count ? anchors[index + 1].time : speechEnd
                if let onset = envelope.onset(after: time, within: Self.earlyMarkerWindow), onset <= nextTime {
                    time = onset
                }
                anchors[index].time = min(max(time, speechStart), speechEnd)
            }
        }

        let shares = script.words.indices.map { position in
            script.wordRanges[position].isEmpty ? Share.none : Share(of: script.words[position])
        }
        var starts = [TimeInterval]()
        starts.reserveCapacity(shares.count)
        if let first = anchors.first {
            starts += Self.spread(shares[..<first.position], from: speechStart, to: first.time, endsSpeech: false)
            for (index, anchor) in anchors.enumerated() {
                let isLast = index + 1 == anchors.count
                let end = isLast ? shares.count : anchors[index + 1].position
                let endTime = isLast ? speechEnd : anchors[index + 1].time
                starts += Self.spread(shares[anchor.position..<end], from: anchor.time, to: endTime, endsSpeech: isLast)
            }
        } else {
            starts = Self.spread(shares[...], from: speechStart, to: speechEnd, endsSpeech: true)
        }
        for index in starts.indices.dropFirst() where starts[index] < starts[index - 1] {
            starts[index] = starts[index - 1]
        }

        self.startTimes = starts
        self.speechStart = speechStart
        self.speechEnd = speechEnd
    }

    /// The word being read `time` seconds into the chunk, as a position in
    /// the script's words: the last one whose start has come. `nil` before
    /// the first word starts.
    func wordPosition(at time: TimeInterval) -> Int? {
        var low = 0
        var high = startTimes.count
        while low < high {
            let middle = (low + high) / 2
            if startTimes[middle] <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? low - 1 : nil
    }

    /// How long `word` takes to say, together with the pause after it, in
    /// about the time of one spoken letter.
    ///
    /// A voice's time grows with the sounds in a word, about one for each
    /// letter. A digit is read as a whole word or part of one (`2000` is
    /// "two thousand"), a Han character or Hangul block as a syllable, and a
    /// kana as most of one. A pause is a stretch of silence, the same after a
    /// short word as after a long one. Weights only divide up a stretch of
    /// time between two known points, so they need to be in proportion, not
    /// exact. Measured on three voices, spreading each sentence's words by
    /// these weights alone put them 35–100 ms from their markers on average,
    /// about half as far as spreading by letters alone or evenly.
    static func weight(of word: String) -> Double {
        Share(of: word).total
    }

    // MARK: - Markers

    /// A word whose start a marker gives, as a position in the script.
    private struct Anchor {
        let position: Int
        var time: TimeInterval
    }

    /// The markers that place words, as the start of the first word each
    /// touches: the longest run, in the order they were reported, that only
    /// moves forward to later words at the same time or later. Of two equal
    /// runs, the one with the earlier markers wins, so a word's first marker
    /// counts.
    private static func anchors(from markers: [SpeechMarker], in script: SpeechScript) -> [Anchor] {
        let candidates = markers.compactMap { marker -> Anchor? in
            guard marker.time.isFinite,
                  let position = script.wordPositions(touching: marker.utf16Range).first else { return nil }
            return Anchor(position: position, time: max(0, marker.time))
        }
        var runLength = [Int](repeating: 1, count: candidates.count)
        var previous = [Int?](repeating: nil, count: candidates.count)
        for index in candidates.indices {
            for earlier in 0..<index
            where candidates[earlier].position < candidates[index].position
                && candidates[earlier].time <= candidates[index].time
                && runLength[earlier] + 1 > runLength[index] {
                runLength[index] = runLength[earlier] + 1
                previous[index] = earlier
            }
        }
        guard let longest = runLength.max(), var cursor = runLength.firstIndex(of: longest) else { return [] }
        var run = [candidates[cursor]]
        while let earlier = previous[cursor] {
            run.append(candidates[earlier])
            cursor = earlier
        }
        return run.reversed()
    }

    // MARK: - Spreading

    /// A word's share of the time, split into saying it and the pause after.
    private struct Share {
        let sound: Double
        let pause: Double

        var total: Double { sound + pause }

        /// A word that isn't read.
        static let none = Share(sound: 0, pause: 0)

        private init(sound: Double, pause: Double) {
            self.sound = sound
            self.pause = pause
        }

        init(of word: String) {
            var units = 0.0
            for scalar in word.unicodeScalars {
                switch scalar.value {
                case 0xAC00...0xD7A3:                   // Hangul syllables
                    units += 3
                case 0x3040...0x30FF:                   // kana
                    units += 2
                default:
                    if CJKUtilities.isHanIdeograph(scalar) || scalar.properties.numericType != nil {
                        units += 3
                    } else if scalar.properties.isAlphabetic {
                        units += 1
                    } else if scalar.properties.isEmojiPresentation {
                        units += 6                      // read out by name
                    }
                }
            }
            guard units > 0 else {
                self = .none
                return
            }
            sound = units

            let marks = PunctuationMarks.marks(in: word)
            if !marks.isDisjoint(with: [.sentenceEnd, .ellipsis]) {
                pause = 6
            } else if !marks.isDisjoint(with: [.clause, .dash]) {
                pause = 4
            } else {
                pause = 0
            }
        }
    }

    /// Start times for words that share the stretch from `start` to `end`,
    /// each after the ones before it have had their share. When the stretch
    /// `endsSpeech`, the last word read has no pause after it.
    private static func spread(
        _ shares: ArraySlice<Share>,
        from start: TimeInterval,
        to end: TimeInterval,
        endsSpeech: Bool
    ) -> [TimeInterval] {
        var weights = shares.map(\.total)
        if endsSpeech, let last = weights.lastIndex(where: { $0 > 0 }) {
            weights[last] = shares[shares.startIndex + last].sound
        }
        let total = weights.reduce(0, +)
        guard total > 0 else {
            return Array(repeating: end, count: weights.count)
        }
        // Weighted this way, a word after all the weight starts exactly at
        // `end`, with the word there.
        var elapsed = 0.0
        return weights.map { weight in
            defer { elapsed += weight }
            let fraction = elapsed / total
            return start * (1 - fraction) + end * fraction
        }
    }
}

// MARK: - Loudness

/// A chunk's loudness, read for when the voice is heard.
nonisolated private struct Envelope {
    /// Empty when nothing in the chunk is loud enough to be the voice.
    let frames: [Float]
    let threshold: Float
    /// The audio's length in seconds: its duration, or else the loudness's.
    let length: TimeInterval
    let speechStart: TimeInterval
    let speechEnd: TimeInterval

    init(_ frames: [Float], duration: TimeInterval) {
        let frameDuration = SpeechLoudness.frameDuration
        let peak = frames.max() ?? 0
        let threshold = max(SpeechSchedule.minimumSilenceThreshold, peak * SpeechSchedule.silenceLevel)
        let heard = peak > threshold ? frames : []
        self.frames = heard
        self.threshold = threshold
        let length = duration > 0 ? duration : Double(frames.count) * frameDuration
        self.length = length
        if let first = heard.firstIndex(where: { $0 > threshold }),
           let last = heard.lastIndex(where: { $0 > threshold }) {
            speechStart = min(Double(first) * frameDuration, length)
            speechEnd = min(Double(last + 1) * frameDuration, length)
        } else {
            speechStart = 0
            speechEnd = length
        }
    }

    /// When the voice is next heard, if `time` falls in a silence that ends
    /// within `window` after it.
    func onset(after time: TimeInterval, within window: TimeInterval) -> TimeInterval? {
        let frameDuration = SpeechLoudness.frameDuration
        // A little over, so a time on a frame's edge lands in that frame.
        let frame = Int((time / frameDuration + 1e-6).rounded(.down))
        guard frames.indices.contains(frame), frames[frame] <= threshold else { return nil }
        let lastFrame = min(frames.count - 1, frame + Int((window / frameDuration).rounded()))
        guard frame < lastFrame,
              let onset = frames[(frame + 1)...lastFrame].firstIndex(where: { $0 > threshold }) else { return nil }
        return Double(onset) * frameDuration
    }
}
