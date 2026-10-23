import Foundation

/// The phonemes Kokoro reads for a run of words: each word's phonemes,
/// joined by single spaces, with the part of the line that reads each word.
///
/// Kokoro takes a phoneme string and predicts how many acoustic frames each
/// of its symbols lasts, so a word's span of the line is also its span of
/// the audio (``KokoroWordTiming``). Positions count Unicode scalars, as the
/// model's vocabulary encodes the line one scalar to one token.
nonisolated struct KokoroPhonemeLine: Equatable, Sendable {

    /// What the model is given.
    let text: String

    /// For each word, the scalar offsets of ``text`` that read it; nil for a
    /// word with no phonemes, which isn't read.
    let wordSpans: [Range<Int>?]

    /// The number of Unicode scalars in ``text``, which the model's limit
    /// counts.
    let length: Int

    /// The line for words with these phonemes. A word without phonemes adds
    /// nothing to it, not even a space.
    init(wordPhonemes: [String]) {
        var text = ""
        var spans: [Range<Int>?] = []
        var length = 0
        for phonemes in wordPhonemes {
            let count = phonemes.unicodeScalars.count
            guard count > 0 else {
                spans.append(nil)
                continue
            }
            if length > 0 {
                text += " "
                length += 1
            }
            text += phonemes
            spans.append(length..<length + count)
            length += count
        }
        self.text = text
        self.wordSpans = spans
        self.length = length
    }

    /// The runs of words, in order, whose lines fit in `limit` scalars, each
    /// as long as it can be. Words without phonemes go with the run they
    /// fall in. A word that alone runs past `limit` is the only word with
    /// phonemes in its run, though words without them can share it; it's
    /// cut down to the limit by ``lines(for:limit:)``. Empty only when there
    /// are no words.
    static func parts(for wordPhonemes: [String], limit: Int) -> [Range<Int>] {
        var parts: [Range<Int>] = []
        var start = 0
        var length = 0
        for (index, phonemes) in wordPhonemes.enumerated() {
            let count = phonemes.unicodeScalars.count
            guard count > 0 else { continue }
            let added = length > 0 ? count + 1 : count
            if length > 0, length + added > limit {
                parts.append(start..<index)
                start = index
                length = count
            } else {
                length += added
            }
        }
        if start < wordPhonemes.count {
            parts.append(start..<wordPhonemes.count)
        }
        return parts
    }

    /// The lines to render for words with these phonemes, one for each of
    /// their ``parts(for:limit:)``, with the words it reads. None is longer
    /// than `limit`: a word that alone runs past it is cut down with
    /// ``truncated(_:toLength:)``.
    static func lines(for wordPhonemes: [String], limit: Int) -> [(words: Range<Int>, line: KokoroPhonemeLine)] {
        parts(for: wordPhonemes, limit: limit).map { part in
            // Only a part with one word that has phonemes runs past the
            // limit. Its other words fit, or have no phonemes and add
            // nothing, so cutting every word cuts that one alone.
            let phonemes = wordPhonemes[part].map { truncated($0, toLength: limit) }
            return (words: part, line: KokoroPhonemeLine(wordPhonemes: phonemes))
        }
    }

    /// `phonemes` cut to at most `limit` scalars: after the last whole group
    /// (the phonemes between spaces) that fits, or at the limit itself when
    /// the first group alone doesn't fit.
    static func truncated(_ phonemes: String, toLength limit: Int) -> String {
        let scalars = Array(phonemes.unicodeScalars)
        guard scalars.count > limit else { return phonemes }
        var end = limit
        if let space = scalars[...limit].lastIndex(of: " "), space > 0 {
            end = space
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[..<end])
        return String(view).trimmingCharacters(in: .whitespaces)
    }

    /// A word's phonemes as the line takes them:
    ///
    /// - only symbols the model's vocabulary has, as `isEncodable` says, so
    ///   each scalar of the line is one token and none is dropped unseen;
    /// - groups split by single spaces, without spaces at the ends;
    /// - punctuation before the first group joined to it, as the phonemizer
    ///   writes punctuation inside a sentence: `“ həlˈO` becomes `“həlˈO`.
    static func cleaned(_ phonemes: String, isEncodable: (Unicode.Scalar) -> Bool) -> String {
        var groups: [String] = []
        var group = String.UnicodeScalarView()
        for scalar in phonemes.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !group.isEmpty {
                    groups.append(String(group))
                    group = String.UnicodeScalarView()
                }
            } else if isEncodable(scalar) {
                group.append(scalar)
            }
        }
        if !group.isEmpty {
            groups.append(String(group))
        }
        // Leading groups of punctuation alone join the next group.
        var leading = ""
        while groups.count > 1, !groups[0].unicodeScalars.contains(where: KokoroWordTiming.isSounding) {
            leading += groups.removeFirst()
        }
        if !leading.isEmpty {
            groups[0] = leading + groups[0]
        }
        return groups.joined(separator: " ")
    }
}

/// What the phonemizer is given for a word, around the readings it gets
/// wrong.
///
/// - Accents are dropped outside CJK text: the lexicon spells English
///   without them, and its fallback mangles letters it doesn't know
///   (`café` reads as "caff", `cafe` right).
/// - A `~` before a number reads as "about": the phonemizer turns `~5` into
///   "approximately" and drops the number.
/// - The lexicon reads the designators `AD`, `AH`, and `AM` as the words
///   "ad", "ah", and "am", so a number unit with one is said around them:
///   an era's letter names follow or lead the year, read on its own, and a
///   time is read with `PM`, whose letter names then become those of `AM`,
///   so that `12:00` reads as "twelve" rather than "twelve o'clock". The
///   other designators (`BCE`, `BC`, `CE`, `PM`) read right as they are.
nonisolated enum KokoroSpokenText {

    /// How to phonemize a word's spoken text.
    struct Plan: Equatable, Sendable {
        /// What the phonemizer is given; empty when there's nothing to give it.
        var text: String
        /// Phonemes said before the phonemizer's.
        var leading = ""
        /// Phonemes said after the phonemizer's.
        var trailing = ""
        /// Phonemes in the phonemizer's output to replace, the last time
        /// they occur, with ``replacement``; empty for none.
        var replaced = ""
        var replacement = ""

        /// The word's phonemes, from the phonemizer's `output` for ``text``;
        /// nil when ``replaced`` isn't in it, so the word should be read as
        /// written instead.
        func phonemes(fromPhonemizerOutput output: String) -> String? {
            var output = output
            if !replaced.isEmpty {
                guard let range = output.range(of: replaced, options: .backwards) else { return nil }
                output.replaceSubrange(range, with: replacement)
            }
            return [leading, output, trailing].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    /// The letter names of the era designators the lexicon reads as words.
    static let eraNames = ["AD": "ˌAdˈi", "AH": "ˌAˈAʧ"]
    /// The letter names of `AM`.
    static let antemeridiemName = "ˌAˈɛm"
    /// How the phonemizer says `PM`.
    static let postmeridiemPhonemes = "pˌiˈɛm"

    /// How to phonemize `spoken`, a word's text in a ``SpeechScript``.
    static func plan(for spoken: String) -> Plan {
        let text = readingApproximations(in: withoutAccents(spoken))
        let halves = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard halves.count == 2 else { return Plan(text: text) }
        let (first, second) = (halves[0], halves[1])

        // A year and its era, or a time and its meridiem: `79 AD`, `9 a.m.`
        if first.contains(where: \.isNumber), let designator = designator(in: second) {
            if designator.letters == "AM" {
                return Plan(
                    text: first + " PM" + designator.after,
                    replaced: postmeridiemPhonemes,
                    replacement: antemeridiemName
                )
            }
            if let name = eraNames[designator.letters] {
                return Plan(text: first, trailing: name + designator.after)
            }
        }
        // An era before its year: `AD 79`, `(A.D. 79`
        let marks = String(first.prefix { !$0.isLetter && !$0.isNumber })
        if second.contains(where: \.isNumber),
           let designator = designator(in: String(first.dropFirst(marks.count))),
           designator.after.isEmpty,
           let name = eraNames[designator.letters] {
            return Plan(text: second, leading: marks + name)
        }
        return Plan(text: text)
    }

    /// `text` without accents, unless it has CJK characters, whose marks
    /// (kana's voicing marks) are part of the letter.
    static func withoutAccents(_ text: String) -> String {
        guard !text.unicodeScalars.contains(where: CJKUtilities.isCJK) else { return text }
        return text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// `text` with each `~` right before a digit written as "about ".
    static func readingApproximations(in text: String) -> String {
        var result = ""
        var characters = text.makeIterator()
        var current = characters.next()
        while let character = current {
            let next = characters.next()
            if character == "~", let next, next.isASCII, next.isNumber {
                result += "about "
            } else {
                result.append(character)
            }
            current = next
        }
        return result
    }

    /// The designator `token` is, uppercased without its dots, with the
    /// marks after it: `A.M.,` is `AM` and `,`. Undotted designators count
    /// in capitals only, as the tokenizer joins them: `am` and `ad` are
    /// words. A dotted form's last period is its own, so it isn't kept.
    static func designator(in token: String) -> (letters: String, after: String)? {
        var core = Substring(token)
        var after = ""
        while let last = core.last, !last.isLetter, last != "." {
            after = String(last) + after
            core.removeLast()
        }
        let isDotted = core.dropLast(core.hasSuffix(".") ? 1 : 0).contains(".")
        if core.hasSuffix(".") {
            core.removeLast()
            if !isDotted { after = "." + after }
        }
        let letters = String(core.filter { $0 != "." })
        guard (2...3).contains(letters.count), letters.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        if isDotted {
            guard core == letters.map(String.init).joined(separator: ".") else { return nil }
        } else {
            guard letters == letters.uppercased() else { return nil }
        }
        return (letters.uppercased(), after)
    }
}

/// When each word starts in audio Kokoro rendered from a ``KokoroPhonemeLine``.
///
/// Kokoro gives every token of its input (a start token, one for each scalar
/// of the line, and an end token) a whole number of acoustic frames, and
/// builds the audio frame by frame, the same number of samples to each. The
/// voice is heard starting a word during the space before it: measured
/// after pauses, at speeds from 0.85 to 1.3, the sound resumes within about
/// 20 ms of the space's first frame, and 30 to 100 ms before the word's own
/// first frame. So a word starts with the frames of the space before it.
/// The first word has no space before it, and starts with its first sound:
/// its first phoneme or stress mark, after any punctuation before it, or
/// where the audio is first heard (``firstWordStart(_:loudness:frameDuration:)``).
///
/// The mapping is exact when there is one duration for each token. When
/// there isn't, as when the model dropped a symbol, each word starts in
/// proportion to its place in the line, between the start and end tokens.
nonisolated enum KokoroWordTiming {

    /// Where the words of a line start.
    struct Result: Equatable, Sendable {
        /// For each word, when it starts, in seconds into the audio; nil for a
        /// word the line has no phonemes for.
        let startTimes: [TimeInterval?]
        /// Whether the times come from each word's own tokens rather than
        /// from its place in the line.
        let isExact: Bool
    }

    /// Kokoro's audio has this many samples for each acoustic frame: 25 ms
    /// at 24 kHz.
    static let samplesPerFrame = 600

    /// - Parameters:
    ///   - line: The phonemes the audio was rendered from.
    ///   - durations: The frames Kokoro gave each token: the start token,
    ///     each scalar of `line.text`, then the end token.
    ///   - audioDuration: The audio's length in seconds. The frames divide
    ///     it evenly.
    static func startTimes(
        for line: KokoroPhonemeLine,
        durations: [Int32],
        audioDuration: TimeInterval
    ) -> Result {
        let totalFrames = durations.reduce(0) { $0 + Int(max(0, $1)) }
        guard totalFrames > 0, audioDuration > 0 else {
            return proportional(line, startFrame: 0, frames: 1, secondsPerFrame: max(0, audioDuration))
        }
        let secondsPerFrame = audioDuration / Double(totalFrames)
        guard durations.count == line.length + 2 else {
            let first = durations.first.map { Double(max(0, $0)) } ?? 0
            let last = durations.count > 1 ? Double(max(0, durations[durations.count - 1])) : 0
            let between = max(0, Double(totalFrames) - first - last)
            return proportional(line, startFrame: first, frames: between, secondsPerFrame: secondsPerFrame)
        }

        // The frame each token starts on; token 0 is the start token.
        var tokenStarts = [Int](repeating: 0, count: durations.count)
        var elapsed = 0
        for (index, duration) in durations.enumerated() {
            tokenStarts[index] = elapsed
            elapsed += Int(max(0, duration))
        }
        let scalars = Array(line.text.unicodeScalars)
        let starts = line.wordSpans.map { span -> TimeInterval? in
            guard let span else { return nil }
            // The model starts saying a word during the space before it, so
            // the word starts with that space; the first word starts with
            // its first sound.
            let first = span.lowerBound > 0 && scalars[span.lowerBound - 1] == " "
                ? span.lowerBound - 1
                : span.first { isSounding(scalars[$0]) } ?? span.lowerBound
            return Double(tokenStarts[first + 1]) * secondsPerFrame
        }
        return Result(startTimes: starts, isExact: true)
    }

    /// How far before its first sound's frames the first word of a line can
    /// start: a nasal or a hiss starts softly, up to about 120 ms early at
    /// slow speeds.
    static let onsetWindow: TimeInterval = 0.15

    /// The audio is heard in a loudness frame louder than this share of its
    /// loudest, as ``SpeechSchedule`` hears it.
    static let silenceLevel: Float = 0.02

    /// Where a line's first word starts: `start`, the start of its first
    /// sound's frames, or where the audio is first heard if that's earlier,
    /// within ``onsetWindow`` before it, after silence. A later word starts
    /// with the space before it, which is exact to about 20 ms, but there's
    /// no space before the first: it follows the silence the model leads
    /// each line with.
    /// - Parameter loudness: The audio's loudness in each `frameDuration`.
    static func firstWordStart(_ start: TimeInterval, loudness: [Float], frameDuration: TimeInterval) -> TimeInterval {
        guard frameDuration > 0, !loudness.isEmpty else { return start }
        let threshold = max(0.001, (loudness.max() ?? 0) * silenceLevel)
        let end = min(loudness.count - 1, Int((start / frameDuration).rounded(.down)))
        let begin = max(0, Int(((start - onsetWindow) / frameDuration).rounded(.down)))
        guard begin < end, loudness[begin] <= threshold,
              let onset = (begin...end).first(where: { loudness[$0] > threshold }) else { return start }
        return min(start, Double(onset) * frameDuration)
    }

    /// Whether a phoneme symbol is heard rather than marking a pause: a
    /// letter, including stress and length marks.
    static func isSounding(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic
    }

    /// Start times in proportion to each word's place in the line, over
    /// `frames` frames from `startFrame`.
    private static func proportional(
        _ line: KokoroPhonemeLine,
        startFrame: Double,
        frames: Double,
        secondsPerFrame: TimeInterval
    ) -> Result {
        let length = Double(max(1, line.length))
        let starts = line.wordSpans.map { span -> TimeInterval? in
            guard let span else { return nil }
            return (startFrame + Double(span.lowerBound) / length * frames) * secondsPerFrame
        }
        return Result(startTimes: starts, isExact: false)
    }
}
