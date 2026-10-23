import Testing
import Foundation
import AVFAudio
@testable import Strobe

struct ReadAloudTimingTests {

    // MARK: - Helpers

    private func script(_ words: [String]) -> SpeechScript {
        SpeechScript(words: words, range: 0..<words.count)
    }

    /// A marker for the word at `position`.
    private func marker(_ script: SpeechScript, _ position: Int, at time: TimeInterval) -> SpeechMarker {
        SpeechMarker(utf16Range: script.wordRanges[position], time: time)
    }

    /// A marker for the first `part` of the script's text.
    private func marker(_ script: SpeechScript, _ part: String, at time: TimeInterval) -> SpeechMarker {
        let range = (script.text as NSString).range(of: part)
        return SpeechMarker(utf16Range: range.location..<range.location + range.length, time: time)
    }

    /// Loudness frames for `duration` seconds: loud during `speech`, all but
    /// silent elsewhere.
    private func loudness(_ speech: [ClosedRange<Double>], duration: TimeInterval) -> [Float] {
        let count = Int((duration / SpeechLoudness.frameDuration).rounded())
        return (0..<count).map { frame in
            let middle = (Double(frame) + 0.5) * SpeechLoudness.frameDuration
            return speech.contains { $0.contains(middle) } ? 0.2 : 0.0002
        }
    }

    private func isClose(_ times: [TimeInterval], _ expected: [TimeInterval], within tolerance: Double = 1e-6) -> Bool {
        times.count == expected.count && zip(times, expected).allSatisfy { abs($0 - $1) <= tolerance }
    }

    private func isNonDecreasing(_ times: [TimeInterval]) -> Bool {
        zip(times, times.dropFirst()).allSatisfy { $0 <= $1 }
    }

    // MARK: - One marker for each word

    @Test func wordsStartAtTheirMarkers() {
        let script = script(["The", "keeper", "rose", "early."])
        let markers = [0.10, 0.32, 0.72, 0.97].enumerated().map { marker(script, $0.offset, at: $0.element) }
        let loudness = loudness([0.10...0.30, 0.32...0.70, 0.72...0.95, 0.97...1.50], duration: 1.8)
        let schedule = SpeechSchedule(script: script, markers: markers, loudness: loudness, duration: 1.8)
        #expect(isClose(schedule.startTimes, [0.10, 0.32, 0.72, 0.97]))
        #expect(abs(schedule.speechStart - 0.10) < 1e-9)
        #expect(abs(schedule.speechEnd - 1.50) < 1e-9)
    }

    /// `2000 BCE` and `10:30 PM` get a marker for each half; the first counts.
    @Test func numberUnitsStartAtTheirFirstMarker() {
        let script = script(["around", "2000 BCE,", "and", "at", "10:30 PM", "the", "boat"])
        let markers = [
            marker(script, "around", at: 0.1),
            marker(script, "2000", at: 0.5),
            marker(script, "BCE", at: 0.9),
            marker(script, "and", at: 1.3),
            marker(script, "at", at: 1.5),
            marker(script, "10:30", at: 1.7),
            marker(script, "PM", at: 2.1),
            marker(script, "the", at: 2.4),
            marker(script, "boat", at: 2.6),
        ]
        let schedule = SpeechSchedule(script: script, markers: markers, loudness: [], duration: 3)
        #expect(isClose(schedule.startTimes, [0.1, 0.5, 1.3, 1.5, 1.7, 2.4, 2.6]))
    }

    /// Markers around `1990–2000` can overlap and go back; those that would
    /// move back are set aside.
    @Test func markersThatGoBackAreSetAside() {
        let script = script(["from", "1990\u{2013}2000", "the", "war"])
        #expect(script.text == "from 1990\u{2013}2000 the war")
        let markers = [
            marker(script, "from", at: 0.1),
            marker(script, "1990", at: 0.4),
            marker(script, "2000", at: 0.7),
            marker(script, "1990\u{2013}2000", at: 0.75),
            marker(script, "from 1990", at: 0.8),
            marker(script, "the", at: 1.0),
            marker(script, "war", at: 1.2),
        ]
        let schedule = SpeechSchedule(script: script, markers: markers, loudness: [], duration: 1.6)
        #expect(isClose(schedule.startTimes, [0.1, 0.4, 1.0, 1.2]))
    }

    @Test func markerEarlierThanTheOneBeforeIsSetAside() {
        let script = script(["a", "bright", "cold", "day"])
        let markers = [marker(script, 0, at: 0.1), marker(script, 1, at: 0.5),
                       marker(script, 2, at: 0.3), marker(script, 3, at: 1.0)]
        let schedule = SpeechSchedule(script: script, markers: markers, loudness: [], duration: 1.4)
        #expect(schedule.startTimes[1] == 0.5)
        #expect(schedule.startTimes[2] > 0.5 && schedule.startTimes[2] < 1.0)
        #expect(schedule.startTimes[3] == 1.0)
    }

    /// One marker far ahead of its time can't outvote the markers after it.
    @Test func strayMarkerAheadIsSetAside() {
        let script = script(["one", "two", "three", "four", "five", "six"])
        let markers = [
            marker(script, 0, at: 0.0), marker(script, 1, at: 0.3), marker(script, 5, at: 0.35),
            marker(script, 2, at: 0.6), marker(script, 3, at: 0.9), marker(script, 4, at: 1.2),
            marker(script, 5, at: 1.5),
        ]
        let schedule = SpeechSchedule(script: script, markers: markers, loudness: [], duration: 2)
        #expect(isClose(schedule.startTimes, [0.0, 0.3, 0.6, 0.9, 1.2, 1.5]))
    }

    /// Markers whose range lies past the text place nothing.
    @Test func markersPastTheTextAreIgnored() {
        let script = script(["Hello", "there."])
        let markers = [marker(script, 0, at: 0.1), SpeechMarker(utf16Range: 40..<45, time: 0.3),
                       marker(script, 1, at: 0.6)]
        let schedule = SpeechSchedule(script: script, markers: markers, loudness: [], duration: 1)
        #expect(isClose(schedule.startTimes, [0.1, 0.6]))
    }

    // MARK: - One marker for several words

    /// A voice can report a whole sentence as one word. Its words share the
    /// time until the next marker by how long each takes to say.
    @Test func mergedSentenceIsSpreadByWeight() {
        let words = ["He", "climbed", "the", "narrow", "stair.", "Below", "him", "the", "harbor", "lay", "still."]
        let script = script(words)
        let stair = script.wordRanges[4]
        var markers = [SpeechMarker(utf16Range: 0..<stair.upperBound, time: 0.2)]
        for (position, time) in zip(5..., [1.6, 1.9, 2.05, 2.2, 2.6, 2.8]) {
            markers.append(marker(script, position, at: time))
        }
        let schedule = SpeechSchedule(script: script, markers: markers, loudness: [], duration: 3.4)
        let starts = schedule.startTimes

        #expect(starts.count == words.count)
        #expect(starts[0] == 0.2)
        #expect(starts[5] == 1.6)
        #expect(zip(starts[0...5], starts[1...5]).allSatisfy { $0 < $1 })
        // `climbed` takes longer than `He`, and `stair.` keeps its pause.
        #expect(starts[2] - starts[1] > starts[1] - starts[0])
        #expect(starts[5] - starts[4] > starts[3] - starts[2])

        let shares = words[0..<5].map(SpeechSchedule.weight(of:))
        let expected = 0.2 + 1.4 * (shares[0] + shares[1]) / shares.reduce(0, +)
        #expect(abs(starts[2] - expected) < 1e-9)
    }

    /// Some voices report phrases rather than words.
    @Test func phraseMarkersSpreadTheirWords() {
        let words = ["The", "boats", "tilted", "in", "the", "mud", "like", "sleeping", "animals", "and", "the", "gulls."]
        let script = script(words)
        let markers = [(0, 0.2), (4, 1.4), (8, 2.6)].map { first, time in
            SpeechMarker(utf16Range: script.wordRanges[first].lowerBound..<script.wordRanges[first + 3].upperBound,
                         time: time)
        }
        let loudness = loudness([0.2...3.8], duration: 4)
        let schedule = SpeechSchedule(script: script, markers: markers, loudness: loudness, duration: 4)
        let starts = schedule.startTimes
        #expect(starts.count == 12)
        #expect(isClose([starts[0], starts[4], starts[8]], [0.2, 1.4, 2.6]))
        #expect(zip(starts, starts.dropFirst()).allSatisfy { $0 < $1 })
        #expect(starts[11] < 3.8)
    }

    // MARK: - Words without a marker

    @Test func skippedWordFallsBetweenItsNeighbours() {
        let script = script(["We", "walked", "slowly", "home."])
        let markers = [marker(script, 0, at: 0.1), marker(script, 1, at: 0.3), marker(script, 3, at: 0.9)]
        let schedule = SpeechSchedule(script: script, markers: markers, loudness: [], duration: 1.4)
        #expect(schedule.startTimes[1] == 0.3)
        #expect(schedule.startTimes[2] > 0.3 && schedule.startTimes[2] < 0.9)
        #expect(schedule.startTimes[3] == 0.9)
    }

    /// A word that isn't read starts with the next word that is, or where
    /// speech ends when none follows.
    @Test func wordsLeftOutStartWithTheNextWord() {
        let script = script(["end.", "***", "Then", "more"])
        let markers = [marker(script, 0, at: 0.1), marker(script, 2, at: 0.9), marker(script, 3, at: 1.2)]
        let schedule = SpeechSchedule(script: script, markers: markers, loudness: [], duration: 1.5)
        #expect(isClose(schedule.startTimes, [0.1, 0.9, 0.9, 1.2]))

        let leading = self.script(["***", "Then", "now"])
        let leadingSchedule = SpeechSchedule(script: leading, markers: [marker(leading, 1, at: 0.4)],
                                             loudness: [], duration: 1)
        #expect(leadingSchedule.startTimes[0] == 0.4)

        let trailing = self.script(["Then", "now", "\u{2022}"])
        let trailingSchedule = SpeechSchedule(script: trailing, markers: [], loudness: [], duration: 1)
        #expect(trailingSchedule.startTimes[2] == 1)
    }

    // MARK: - No markers

    /// Words spread over the time the voice is heard, by weight; leading and
    /// trailing silence come from the loudness, and the last word's pause
    /// isn't part of the speech.
    @Test func noMarkersSpreadTheWordsOverTheSpeech() {
        let words = ["One", "extraordinary", "day", "began."]
        let script = script(words)
        let loudness = loudness([0.3...2.0], duration: 2.4)
        let schedule = SpeechSchedule(script: script, markers: [], loudness: loudness, duration: 2.4)
        let starts = schedule.startTimes
        #expect(abs(schedule.speechStart - 0.3) < 1e-9)
        #expect(abs(schedule.speechEnd - 2.0) < 1e-9)
        #expect(abs(starts[0] - 0.3) < 1e-9)
        #expect(zip(starts, starts.dropFirst()).allSatisfy { $0 < $1 })
        #expect(starts[2] - starts[1] > starts[1] - starts[0])

        let weights = ["One", "extraordinary", "day", "began"].map(SpeechSchedule.weight(of:))
        let expected = 0.3 + 1.7 * weights[0] / weights.reduce(0, +)
        #expect(abs(starts[1] - expected) < 1e-9)
    }

    @Test func noMarkersOrLoudnessSpreadOverTheWholeChunk() {
        let script = script(["Somewhere", "a", "bell", "rang."])
        let schedule = SpeechSchedule(script: script, markers: [], loudness: [], duration: 2)
        #expect(schedule.speechStart == 0)
        #expect(schedule.speechEnd == 2)
        #expect(schedule.startTimes[0] == 0)
        #expect(schedule.startTimes[3] < 2)
        #expect(isNonDecreasing(schedule.startTimes))
    }

    /// Audio that is silent throughout says nothing about where speech is.
    @Test func silentAudioCountsAsNoLoudness() {
        let script = script(["Somewhere", "a", "bell", "rang."])
        let silent = [Float](repeating: 0, count: 200)
        let schedule = SpeechSchedule(script: script, markers: [], loudness: silent, duration: 2)
        #expect(schedule.speechStart == 0)
        #expect(schedule.speechEnd == 2)
    }

    // MARK: - Early markers

    private let harbor = ["The", "harbor", "lay", "still."]
    private var harborLoudness: [Float] {
        loudness([0.10...0.40, 0.60...0.90, 1.30...1.60, 1.62...2.00], duration: 2.3)
    }

    /// Markers up to about 200 ms early land in the silence before their
    /// word, and move to where it's heard.
    @Test func earlyMarkersMoveToTheirWord() {
        let script = script(harbor)
        let markers = [marker(script, 0, at: 0.10), marker(script, 1, at: 0.42),
                       marker(script, 2, at: 1.10), marker(script, 3, at: 1.62)]
        let schedule = SpeechSchedule(script: script, markers: markers, loudness: harborLoudness, duration: 2.3)
        #expect(isClose(schedule.startTimes, [0.10, 0.60, 1.30, 1.62]))
    }

    @Test func markersStayWhenTheVoiceIsntHeardSoon() {
        let script = script(harbor)
        // `lay` is heard 350 ms after its marker, too late to be its word.
        let late = [marker(script, 0, at: 0.10), marker(script, 1, at: 0.60),
                    marker(script, 2, at: 0.95), marker(script, 3, at: 1.62)]
        let lateSchedule = SpeechSchedule(script: script, markers: late, loudness: harborLoudness, duration: 2.3)
        #expect(isClose(lateSchedule.startTimes, [0.10, 0.60, 0.95, 1.62]))

        // A marker where the voice is heard stays.
        let loud = [marker(script, 0, at: 0.10), marker(script, 1, at: 0.65)]
        let loudSchedule = SpeechSchedule(script: script, markers: loud, loudness: harborLoudness, duration: 2.3)
        #expect(abs(loudSchedule.startTimes[1] - 0.65) < 1e-9)

        // A marker never moves past the next one.
        let crowded = [marker(script, 0, at: 0.10), marker(script, 1, at: 0.42), marker(script, 2, at: 0.55)]
        let crowdedSchedule = SpeechSchedule(script: script, markers: crowded, loudness: harborLoudness, duration: 2.3)
        #expect(abs(crowdedSchedule.startTimes[1] - 0.42) < 1e-9)
        #expect(isNonDecreasing(crowdedSchedule.startTimes))
    }

    /// Nothing is said before the voice is first heard.
    @Test func firstMarkerWaitsForTheVoice() {
        let script = script(["Hello", "there."])
        let soon = loudness([0.15...0.50, 0.55...0.90], duration: 1.2)
        let soonSchedule = SpeechSchedule(script: script, markers: [marker(script, 0, at: 0), marker(script, 1, at: 0.55)],
                                          loudness: soon, duration: 1.2)
        #expect(isClose(soonSchedule.startTimes, [0.15, 0.55]))

        let late = loudness([0.50...0.80, 0.85...1.10], duration: 1.2)
        let lateSchedule = SpeechSchedule(script: script, markers: [marker(script, 0, at: 0), marker(script, 1, at: 0.85)],
                                          loudness: late, duration: 1.2)
        #expect(isClose(lateSchedule.startTimes, [0.50, 0.85]))
    }

    // MARK: - Any markers

    /// However the markers come, every word gets a start, in order, inside
    /// the chunk.
    @Test func everyWordIsCoveredInOrder() {
        let script = script(["The", "lighthouse", "keeper", "rose", "before", "dawn,", "as", "he", "had", "done."])
        let marked = (0..<10).map { marker(script, $0, at: 0.2 + Double($0) * 0.25) }
        let sets: [[SpeechMarker]] = [
            [],
            marked,
            Array(marked.reversed()),
            marked.enumerated().filter { $0.offset % 3 == 0 }.map(\.element),
            marked.map { SpeechMarker(utf16Range: $0.utf16Range, time: 2.6 - $0.time) },
            marked + marked,
            [SpeechMarker(utf16Range: 0..<script.text.utf16.count, time: 0.4)],
            [SpeechMarker(utf16Range: 3..<4, time: .nan), SpeechMarker(utf16Range: 0..<3, time: -1)],
        ]
        for markers in sets {
            let schedule = SpeechSchedule(script: script, markers: markers,
                                          loudness: loudness([0.15...2.7], duration: 3), duration: 3)
            #expect(schedule.startTimes.count == 10)
            #expect(isNonDecreasing(schedule.startTimes))
            #expect(schedule.startTimes.allSatisfy { $0 >= 0.15 && $0 <= 2.7 })

            let exact = SpeechSchedule(script: script, markers: markers,
                                       loudness: loudness([0.15...2.7], duration: 3), duration: 3,
                                       hasExactMarkers: true)
            #expect(exact.startTimes.count == 10)
            #expect(isNonDecreasing(exact.startTimes))
            #expect(exact.startTimes.allSatisfy { $0 >= 0 && $0 <= 3 })
            #expect(exact.speechStart <= exact.startTimes[0])
        }
    }

    @Test func titleScriptHasNoStarts() {
        let schedule = SpeechSchedule(script: SpeechScript(title: "Chapter One"), markers: [],
                                      loudness: [], duration: 1)
        #expect(schedule.startTimes.isEmpty)
        #expect(schedule.wordPosition(at: 0.5) == nil)
    }

    @Test func scheduleFromRenderedSpeech() throws {
        let script = script(["Hello", "there."])
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
        buffer.frameLength = 24_000
        // `there` is heard 60 ms after its marker.
        let markers = [marker(script, 0, at: 0.1), marker(script, 1, at: 0.44)]
        let loudness = loudness([0.1...0.4, 0.5...0.9], duration: 1)
        for exact in [false, true] {
            let speech = RenderedSpeech(buffer: buffer, markers: markers, loudness: loudness, speed: 1.2,
                                        hasExactMarkers: exact)
            #expect(SpeechSchedule(script: script, speech: speech)
                == SpeechSchedule(script: script, markers: markers, loudness: loudness, duration: 1,
                                  hasExactMarkers: exact))
        }
        let inexact = SpeechSchedule(script: script, markers: markers, loudness: loudness, duration: 1)
        let exact = SpeechSchedule(script: script, markers: markers, loudness: loudness, duration: 1,
                                   hasExactMarkers: true)
        #expect(isClose(inexact.startTimes, [0.1, 0.5]))
        #expect(isClose(exact.startTimes, [0.1, 0.44]))
    }

    // MARK: - Exact markers

    /// The voice model's markers stand where they are, though the loudness
    /// would move them: a word opening on a quiet sound starts before it's
    /// loud enough to be heard.
    @Test func exactMarkersStandAsGiven() {
        let script = script(["So", "far,", "she", "said."])
        let times = [0.08, 0.42, 1.04, 1.31]
        let markers = times.enumerated().map { marker(script, $0.offset, at: $0.element) }
        // Each word is heard 30–80 ms after its marker.
        let loudness = loudness([0.14...0.38, 0.47...0.80, 1.12...1.28, 1.34...1.70], duration: 2)
        let exact = SpeechSchedule(script: script, markers: markers, loudness: loudness, duration: 2,
                                   hasExactMarkers: true)
        #expect(isClose(exact.startTimes, times))
        // The voice is heard from the first marker, and until the loudness
        // falls silent.
        #expect(abs(exact.speechStart - 0.08) < 1e-9)
        #expect(abs(exact.speechEnd - 1.70) < 1e-9)

        // Taken as evidence, the same markers move to where each word is
        // heard.
        let inexact = SpeechSchedule(script: script, markers: markers, loudness: loudness, duration: 2)
        #expect(isClose(inexact.startTimes, [0.14, 0.47, 1.12, 1.34]))
    }

    /// Exact markers still go through the rest: one that goes back is set
    /// aside, a word without one is spread by weight, and a word that isn't
    /// read starts with the next.
    @Test func exactMarkersStillSpreadWordsWithoutOne() {
        let script = script(["***", "The", "lighthouse", "keeper", "slept."])
        let markers = [
            marker(script, 1, at: 0.10),
            marker(script, 2, at: 0.30),
            marker(script, 1, at: 0.35),
            marker(script, 4, at: 1.20),
        ]
        let schedule = SpeechSchedule(script: script, markers: markers, loudness: loudness([0.2...1.6], duration: 2),
                                      duration: 2, hasExactMarkers: true)
        let starts = schedule.startTimes
        #expect(starts[0] == 0.10)
        #expect(starts[1] == 0.10)
        #expect(starts[2] == 0.30)
        #expect(starts[4] == 1.20)
        let shares = ["lighthouse", "keeper"].map(SpeechSchedule.weight(of:))
        #expect(abs(starts[3] - (0.30 + 0.90 * shares[0] / shares.reduce(0, +))) < 1e-9)
    }

    /// An exact marker past the audio's end is held to it, and the last
    /// word started counts as heard.
    @Test func exactMarkersStayInsideTheAudio() {
        let script = script(["Hush", "now."])
        let markers = [marker(script, 0, at: 0.05), marker(script, 1, at: 1.4)]
        let schedule = SpeechSchedule(script: script, markers: markers, loudness: loudness([0.1...0.5], duration: 1),
                                      duration: 1, hasExactMarkers: true)
        #expect(isClose(schedule.startTimes, [0.05, 1.0]))
        #expect(schedule.speechEnd == 1.0)
    }

    // MARK: - Looking up a time

    @Test func wordPositionIsTheLastWordStarted() {
        let script = script(["end.", "***", "Then", "more"])
        let markers = [marker(script, 0, at: 0.1), marker(script, 2, at: 0.9), marker(script, 3, at: 1.2)]
        let schedule = SpeechSchedule(script: script, markers: markers, loudness: [], duration: 1.5)
        #expect(schedule.wordPosition(at: 0.05) == nil)
        #expect(schedule.wordPosition(at: 0.1) == 0)
        #expect(schedule.wordPosition(at: 0.5) == 0)
        // `***` starts with `Then`, and is passed over.
        #expect(schedule.wordPosition(at: 0.9) == 2)
        #expect(schedule.wordPosition(at: 1.0) == 2)
        #expect(schedule.wordPosition(at: 9) == 3)
    }

    // MARK: - Weights

    @Test func longerWordsWeighMore() {
        #expect(SpeechSchedule.weight(of: "a") < SpeechSchedule.weight(of: "the"))
        #expect(SpeechSchedule.weight(of: "the") < SpeechSchedule.weight(of: "extraordinary"))
        #expect(SpeechSchedule.weight(of: "2000") > SpeechSchedule.weight(of: "year"))
        #expect(SpeechSchedule.weight(of: "公园") == 6)
    }

    @Test func pausesWeighOnTheWordBeforeThem() {
        let plain = SpeechSchedule.weight(of: "end")
        #expect(SpeechSchedule.weight(of: "end,") > plain)
        #expect(SpeechSchedule.weight(of: "end\u{2014}") == SpeechSchedule.weight(of: "end,"))
        #expect(SpeechSchedule.weight(of: "end.") > SpeechSchedule.weight(of: "end,"))
        #expect(SpeechSchedule.weight(of: "end...") == SpeechSchedule.weight(of: "end."))
    }

    @Test func symbolsAloneWeighNothing() {
        #expect(SpeechSchedule.weight(of: "***") == 0)
        #expect(SpeechSchedule.weight(of: "\u{2014}") == 0)
    }

    // MARK: - Render speed

    private let natural = VoicePace.initialWordsPerMinute

    /// Within the render speeds, a voice reads at the multiple of its
    /// natural pace the measured curve gives for the speed.
    @Test func renderSpeedFollowsThePaceCurve() {
        let pace = VoicePace()
        #expect(SpeechRate.renderSpeed(forWordsPerMinute: natural, pace: pace) == 1)
        // At speed 1.2 a voice reads 1.15 times its natural pace.
        #expect(abs(SpeechRate.renderSpeed(forWordsPerMinute: natural * 1.15, pace: pace) - 1.2) < 1e-9)
        let slow = VoicePace(naturalWordsPerMinute: 160)
        #expect(abs(SpeechRate.wordsPerMinute(atSpeed: 1.2, pace: slow) - 184) < 1e-9)
        #expect(SpeechRate.wordsPerMinute(atSpeed: 1, pace: pace) == natural)
    }

    /// Sounds last whole frames, so above 1 the pace grows less than the
    /// speed, and the curve never turns back.
    @Test func paceGrowsWithTheSpeedButLessAboveOne() {
        let speeds = stride(from: 0.5, through: 2.0, by: 0.01).map { $0 }
        let multipliers = speeds.map(SpeechRate.paceMultiplier(atSpeed:))
        #expect(zip(multipliers, multipliers.dropFirst()).allSatisfy { $0 < $1 })
        for (speed, multiplier) in zip(speeds, multipliers) where speed > 1.05 {
            #expect(multiplier < speed)
        }
        for speed in speeds {
            let back = SpeechRate.speed(forPaceMultiplier: SpeechRate.paceMultiplier(atSpeed: speed))
            #expect(abs(back - speed) < 1e-9)
        }
    }

    @Test func fasterReadingRendersFaster() {
        let pace = VoicePace()
        let speeds = stride(from: 100.0, through: 450, by: 10).map {
            SpeechRate.renderSpeed(forWordsPerMinute: $0, pace: pace)
        }
        #expect(zip(speeds, speeds.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(speeds.allSatisfy(SpeechRate.renderSpeedRange.contains))
    }

    /// Inside the range, rendering reaches the speed asked for.
    @Test func renderSpeedReachesTheReadingSpeedInsideTheRange() {
        let pace = VoicePace(naturalWordsPerMinute: 170)
        let range = SpeechRate.renderSpeedRange
        let slowest = 170 * SpeechRate.paceMultiplier(atSpeed: range.lowerBound)
        let fastest = 170 * SpeechRate.paceMultiplier(atSpeed: range.upperBound)
        for wordsPerMinute in stride(from: slowest, through: fastest, by: 5) {
            let speed = SpeechRate.renderSpeed(forWordsPerMinute: wordsPerMinute, pace: pace)
            #expect(abs(SpeechRate.wordsPerMinute(atSpeed: speed, pace: pace) - wordsPerMinute) < 1e-9)
        }
    }

    /// Past the range, rendering goes as far as it can, and playback
    /// stretches the rest of the way.
    @Test func renderSpeedIsClampedAndPlaybackMakesUpTheRest() {
        let pace = VoicePace()
        let range = SpeechRate.renderSpeedRange
        #expect(SpeechRate.renderSpeed(forWordsPerMinute: 450, pace: pace) == range.upperBound)
        #expect(SpeechRate.renderSpeed(forWordsPerMinute: 2000, pace: pace) == range.upperBound)
        #expect(SpeechRate.renderSpeed(forWordsPerMinute: 100, pace: pace) == range.lowerBound)
        #expect(SpeechRate.renderSpeed(forWordsPerMinute: 0, pace: pace) == range.lowerBound)

        let top = SpeechRate.wordsPerMinute(atSpeed: range.upperBound, pace: pace)
        #expect(abs(SpeechRate.playbackSpeed(wordsPerMinute: 450, renderedFor: top) - 450 / top) < 1e-12)
        let bottom = SpeechRate.wordsPerMinute(atSpeed: range.lowerBound, pace: pace)
        #expect(abs(SpeechRate.playbackSpeed(wordsPerMinute: 100, renderedFor: bottom) - 100 / bottom) < 1e-12)
    }

    /// The reader's read-aloud speeds stay within what rendering and
    /// stretching reach together, for a voice up to 15% slower or faster
    /// than the initial estimate.
    @Test func readAloudSpeedsNeedNoMoreThanThePlaybackRange() {
        let range = SpeechRate.renderSpeedRange
        for voice in [natural * 0.85, natural, natural * 1.15] {
            let pace = VoicePace(naturalWordsPerMinute: voice)
            for wordsPerMinute in [ReaderSettings.readAloudWPMRange.lowerBound, ReaderSettings.readAloudWPMRange.upperBound] {
                let speed = SpeechRate.renderSpeed(forWordsPerMinute: wordsPerMinute, pace: pace)
                #expect(range.contains(speed))
                let stretch = wordsPerMinute / SpeechRate.wordsPerMinute(atSpeed: speed, pace: pace)
                #expect(SpeechRate.playbackSpeedRange.contains(stretch), "\(voice) wpm voice at \(wordsPerMinute)")
            }
        }
    }

    @Test func slowerVoiceRendersFaster() {
        let slow = VoicePace(naturalWordsPerMinute: 160)
        let fast = VoicePace(naturalWordsPerMinute: 200)
        #expect(SpeechRate.renderSpeed(forWordsPerMinute: 220, pace: slow)
            > SpeechRate.renderSpeed(forWordsPerMinute: 220, pace: fast))
    }

    @Test func unusablePaceRendersAtTheNaturalPace() {
        #expect(SpeechRate.renderSpeed(forWordsPerMinute: 300, pace: VoicePace(naturalWordsPerMinute: 0)) == 1)
        #expect(SpeechRate.renderSpeed(forWordsPerMinute: .nan, pace: VoicePace()) == 1)
    }

    // MARK: - Voice pace

    @Test func paceStartsAtTheInitialEstimate() {
        #expect(VoicePace().naturalWordsPerMinute == VoicePace.initialWordsPerMinute)
        #expect(VoicePace().evidence == VoicePace.initialEvidence)
    }

    @Test func paceLearnsWeightedByDuration() {
        var pace = VoicePace()
        // 30 words in 9 s at the natural pace is 200 wpm.
        pace.learn(wordCount: 30, duration: 9, speed: 1)
        #expect(abs(pace.naturalWordsPerMinute - (natural * 5 + 200 * 9) / 14) < 1e-9)
        #expect(pace.evidence == 14)
    }

    /// A chunk counts for its length only up to the most one chunk counts
    /// for, so a long one, as of a list of years, moves the pace no further
    /// than two sentences would.
    @Test func longChunksCountNoMoreThanTheMostOneCountsFor() {
        var long = VoicePace()
        long.learn(wordCount: 60, duration: 30, speed: 1)    // 120 wpm
        var short = VoicePace()
        short.learn(wordCount: 20, duration: 10, speed: 1)   // 120 wpm
        #expect(long == short)
        #expect(abs(long.naturalWordsPerMinute - (natural * 5 + 120 * VoicePace.maximumWeight) / 15) < 1e-9)
        #expect(long.evidence == VoicePace.initialEvidence + VoicePace.maximumWeight)
    }

    /// With the pace well learned, one slow chunk of 33 s moves it only a
    /// little, and one too slow to be prose (40 years read out in full)
    /// not at all, so the prose after it still reads at its speed.
    @Test func oneLongSlowChunkCantThrowThePaceOff() {
        var pace = VoicePace()
        for _ in 0..<12 {
            pace.learn(wordCount: 20, duration: 20 * 60 / natural, speed: 1)
        }
        #expect(pace.evidence == VoicePace.memory)
        #expect(abs(pace.naturalWordsPerMinute - natural) < 1e-9)

        var years = pace
        years.learn(wordCount: 40, duration: 33, speed: 1)    // 73 wpm
        #expect(years == pace)

        var slow = pace
        slow.learn(wordCount: 50, duration: 33, speed: 1)     // 91 wpm
        let measured = 50.0 / 33 * 60
        let expected = (natural * VoicePace.memory + measured * VoicePace.maximumWeight)
            / (VoicePace.memory + VoicePace.maximumWeight)
        #expect(abs(slow.naturalWordsPerMinute - expected) < 1e-9)
        // About 6% slow, where counting all 33 s made it 16%.
        #expect(slow.naturalWordsPerMinute > natural * 0.93)
    }

    /// A chunk rendered faster is measured at the natural pace: at speed
    /// 1.2 a voice reads 1.15 times as fast, so 50 words in 15 / 1.15 s is
    /// 200 wpm at speed 1. It counts as long as it would have taken at 1.
    @Test func paceLearnsAtTheNaturalPaceFromAnySpeed() {
        var fast = VoicePace()
        fast.learn(wordCount: 50, duration: 15 / 1.15, speed: 1.2)
        var atOne = VoicePace()
        atOne.learn(wordCount: 50, duration: 15, speed: 1)
        #expect(abs(fast.naturalWordsPerMinute - atOne.naturalWordsPerMinute) < 1e-9)
        #expect(abs(fast.evidence - atOne.evidence) < 1e-9)

        var slow = VoicePace()
        slow.learn(wordCount: 50, duration: 15 / 0.88, speed: 0.85)
        #expect(abs(slow.naturalWordsPerMinute - atOne.naturalWordsPerMinute) < 1e-9)
    }

    @Test func paceFollowsTheVoiceAtAnySpeed() {
        var pace = VoicePace()
        // A 160 wpm voice at speed 1.2 reads 184 wpm.
        for _ in 0..<40 {
            pace.learn(wordCount: 20, duration: 20 * 60 / 184, speed: 1.2)
        }
        #expect(abs(pace.naturalWordsPerMinute - 160) < 1)
        #expect(pace.evidence == VoicePace.memory)
    }

    @Test func shortChunksMoveThePaceLess() {
        var short = VoicePace()
        short.learn(wordCount: 2, duration: 0.8, speed: 1)   // 150 wpm
        var long = VoicePace()
        long.learn(wordCount: 25, duration: 10, speed: 1)    // 150 wpm
        #expect(short.naturalWordsPerMinute > long.naturalWordsPerMinute)
        #expect(long.naturalWordsPerMinute > 150)
    }

    @Test func paceIgnoresEmptyAndImplausibleChunks() {
        var pace = VoicePace()
        pace.learn(wordCount: 0, duration: 5, speed: 1)
        pace.learn(wordCount: 10, duration: 0.1, speed: 1)
        pace.learn(wordCount: 10, duration: .nan, speed: 1)
        pace.learn(wordCount: 10, duration: 5, speed: 0)
        pace.learn(wordCount: 10, duration: 5, speed: .infinity)
        // 0.2 s at speed 1.1 would take 0.212 s at speed 1: too short.
        pace.learn(wordCount: 1, duration: 0.2, speed: 1.1)
        // One word in 10 s is too slow to be speech, and 20 in 2 s too fast.
        pace.learn(wordCount: 1, duration: 10, speed: 1)
        pace.learn(wordCount: 20, duration: 2, speed: 1)
        #expect(pace == VoicePace())

        // Slow speech still counts: 9 words in 6 s is 90 wpm.
        pace.learn(wordCount: 9, duration: 6, speed: 1)
        #expect(abs(pace.naturalWordsPerMinute - (natural * 5 + 90 * 6) / 11) < 1e-9)
    }

    @Test func paceRoundTripsThroughCoding() throws {
        var pace = VoicePace()
        pace.learn(wordCount: 40, duration: 12, speed: 1.2)
        let data = try JSONEncoder().encode(pace)
        #expect(try JSONDecoder().decode(VoicePace.self, from: data) == pace)
    }

    // MARK: - Playback speed

    @Test func playbackSpeedStretchesToTheNewSpeed() {
        #expect(SpeechRate.playbackSpeed(wordsPerMinute: 300, renderedFor: 300) == 1)
        #expect(SpeechRate.playbackSpeed(wordsPerMinute: 450, renderedFor: 300) == 1.5)
        #expect(SpeechRate.playbackSpeed(wordsPerMinute: 200, renderedFor: 250) == 0.8)
    }

    @Test func playbackSpeedIsClamped() {
        #expect(SpeechRate.playbackSpeed(wordsPerMinute: 1200, renderedFor: 300) == 3)
        #expect(SpeechRate.playbackSpeed(wordsPerMinute: 100, renderedFor: 400) == 0.5)
        #expect(SpeechRate.playbackSpeed(wordsPerMinute: 0, renderedFor: 300) == 1)
        #expect(SpeechRate.playbackSpeed(wordsPerMinute: 300, renderedFor: 0) == 1)
    }
}
