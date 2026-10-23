import Foundation

/// Drives the word-by-word Rapid Serial Visual Presentation playback.
///
/// Manages a timer that advances through the word array at the configured
/// words-per-minute rate. Supports smart timing (longer display for long words)
/// and punctuation pauses (extra delay after punctuation, set per type). A
/// compound such as `wedge-shaped` and an acronym such as `FBI` always display
/// for longer than a single word; see ``CompoundWord`` and ``Acronym``. With
/// sentence breaks on, a blank screen follows each sentence's last word; see
/// ``SentenceBreak``.
///
/// With a ``pacer`` set, as while reading aloud, the pacer moves playback
/// from word to word instead of the timer, and the per-word timing settings
/// don't apply.
///
/// Conforms to `@Observable` so SwiftUI views automatically update when
/// `currentIndex`, `isPlaying`, or settings change.
@Observable
final class RSVPEngine {

    /// The full array of words to display.
    private(set) var words: [String]
    /// The index of the word currently being displayed.
    private(set) var currentIndex: Int
    /// Whether playback is currently running.
    private(set) var isPlaying: Bool = false

    /// Playback stays active during an announcement, so hold release, Space,
    /// and scene changes cancel it through the normal pause path. The title
    /// stands in for the words at the chapter's start that repeat it: once it
    /// has shown, or when playback pauses during it, reading goes on after
    /// them (see ``ChapterHeading``).
    private(set) var chapterAnnouncement: Chapter?
    private(set) var isChapterTitleVisible = false
    nonisolated static let chapterFadeDuration: TimeInterval = 0.25
    private var chaptersByIndex: [Int: Chapter] = [:]
    /// Where reading goes on after a chapter's announcement, for the chapters
    /// whose first words repeat their title.
    private var readingStarts: [Int: Int] = [:]
    private var lastAnnouncedIndex: Int?

    /// Whether playback is in the blank between two sentences: the last word
    /// of one has had its time and the first of the next isn't up yet.
    /// `currentIndex` still points at the last word. The word, and anything
    /// shown with it, hides while this is true; pausing or seeking ends it.
    private(set) var isInSentenceBreak = false

    /// Words playback has moved past since the count was last taken (see
    /// ``takePlayedWordCount()``). Seeking, scrubbing, and the words a
    /// chapter title stands in for don't count. Nothing displays it, so it
    /// isn't observed.
    @ObservationIgnored private var playedWordCount = 0

    /// The furthest word playback has moved to since the words were loaded,
    /// so the document's furthest-read marker keeps what was read before
    /// going back (scrubbing, "Read Again"). Seeking and scrubbing don't move
    /// it: jumping ahead to look and coming back isn't reading. Nothing
    /// displays it, so it isn't observed.
    @ObservationIgnored private(set) var furthestPlayedIndex = 0

    /// The display time the current word got when playback reached it, so
    /// the word's pop can fit inside it (see ``WordPop``): with a ``pacer``,
    /// the time it gave the word until the next. Nil before playback times
    /// a word, and while a pacer doesn't know. Not observed: it changes
    /// with the word, which views already follow.
    @ObservationIgnored private(set) var currentWordInterval: TimeInterval?

    /// Moves playback in place of the timer while set, as reading aloud
    /// does: `play()` starts it, `pause()` stops it, and its events come in
    /// through ``handle(_:)``. Replacing it pauses playback and stops the
    /// pacer it replaces.
    @ObservationIgnored var pacer: (any WordPacer)? {
        willSet {
            guard newValue !== pacer else { return }
            if isPlaying { pause() }
        }
        didSet {
            guard oldValue !== pacer else { return }
            oldValue?.onEvent = nil
            oldValue?.stop()
            pacer?.onEvent = { [weak self] event in
                self?.handle(event)
            }
        }
    }

    /// The speed the pacer was last given, so a settings change that leaves
    /// the speed alone doesn't reach it.
    @ObservationIgnored private var pacedWordsPerMinute: Int?

    /// The timing settings the pacer was last given, so a change to the
    /// speed alone doesn't pass them on again.
    @ObservationIgnored private var pacedTiming: ReaderSettings.TimingSnapshot?

    /// The target reading speed. Changing this during playback reschedules the timer.
    var wordsPerMinute: Int {
        didSet { onPlaybackSettingChanged() }
    }

    /// Temporary speed while the hold-to-read finger drags vertically.
    /// Cleared on `pause()` so every hold starts at `wordsPerMinute`.
    var wpmOverride: Int? {
        didSet { onPlaybackSettingChanged() }
    }

    /// The fastest playback may run, whatever the speed and the hold
    /// override say: reading aloud caps it at
    /// ``ReaderSettings/readAloudWPMRange``'s top. Nil leaves the speed as
    /// it is.
    var speedCap: Int? {
        didSet { onPlaybackSettingChanged() }
    }

    /// The speed playback actually runs at: the hold override if one is
    /// active, otherwise the configured speed, held to ``speedCap``.
    var effectiveWordsPerMinute: Int {
        min(wpmOverride ?? wordsPerMinute, speedCap ?? .max)
    }

    /// When enabled, longer words are displayed for proportionally more time.
    var smartTimingEnabled: Bool {
        didSet { onPlaybackSettingChanged() }
    }

    /// When enabled, words carrying punctuation receive extra display time:
    /// `sentencePauseMultiplier` at a sentence end, `punctuationPauses` at
    /// every other type. Named after its persisted settings key.
    var sentencePauseEnabled: Bool {
        didSet { onPlaybackSettingChanged() }
    }

    /// Percentage points added to the display interval per letter when smart timing is on.
    /// E.g. 4.0 means a 10-letter word gets +40% duration (1.4× base interval).
    var smartTimingPercentPerLetter: Double {
        didSet { onPlaybackSettingChanged() }
    }

    /// Minimum letter count (punctuation excluded) a word needs before the
    /// per-letter slowdown applies; shorter words display at the base rate so
    /// the overall pace stays close to the configured WPM. 1 slows every word.
    var smartTimingMinimumWordLength: Int {
        didSet { onPlaybackSettingChanged() }
    }

    /// Multiplier applied to the interval at sentence-ending punctuation when punctuation pauses are on.
    var sentencePauseMultiplier: Double {
        didSet { onPlaybackSettingChanged() }
    }

    /// Multipliers for clause marks, dashes, ellipses, and closing brackets
    /// and quotes when punctuation pauses are on.
    var punctuationPauses: PunctuationPauses {
        didSet { onPlaybackSettingChanged() }
    }

    /// When enabled, a blank screen follows a word that ends a sentence (see
    /// ``SentenceBreak``). The blank adds to the word's own time, punctuation
    /// pause included.
    var sentenceBreakEnabled: Bool {
        didSet { onPlaybackSettingChanged() }
    }

    /// The blank's length in base intervals: one word's time at the playback
    /// speed, so it follows WPM and the hold-to-read override but none of the
    /// word's own timing.
    var sentenceBreakLength: Double {
        didSet { onPlaybackSettingChanged() }
    }

    /// When enabled, per-word display time scales with cognitive complexity.
    var complexityTimingEnabled: Bool {
        didSet { onPlaybackSettingChanged() }
    }

    /// How strongly complexity affects timing (0.0 = no effect, 1.0 = full effect).
    var complexityIntensity: Double {
        didSet { onPlaybackSettingChanged() }
    }

    /// Pre-computed complexity scores, parallel to the `words` array. Nil for legacy documents.
    private(set) var complexityScores: [Float]?

    /// The word at the current playback position, or an empty string if out of bounds.
    var currentWord: String {
        guard currentIndex >= 0, currentIndex < words.count else { return "" }
        return words[currentIndex]
    }

    /// Whether the playback position is at the last word. `false` when the
    /// word array is empty (e.g. still loading) so an unloaded engine never
    /// reports a finished document.
    var isAtEnd: Bool {
        guard !words.isEmpty else { return false }
        return currentIndex >= words.count - 1
    }

    /// Playback progress as a value from 0.0 to 1.0.
    var progress: Double {
        guard words.count > 1 else { return isAtEnd ? 1 : 0 }
        return Double(currentIndex) / Double(words.count - 1)
    }

    private var timerSource: DispatchSourceTimer?
    /// The deadline the timer is currently scheduled for. Advancing anchors
    /// the next tick to this value (not `.now()`) so per-tick handler latency
    /// doesn't accumulate into drift at high WPM. Internal so tests can check
    /// a deadline without waiting for it.
    private(set) var scheduledDeadline: DispatchTime?

    private var baseInterval: TimeInterval {
        60.0 / Double(max(1, effectiveWordsPerMinute))
    }

    init(
        words: [String],
        currentIndex: Int = 0,
        wordsPerMinute: Int = 300,
        smartTimingEnabled: Bool = false,
        sentencePauseEnabled: Bool = false,
        smartTimingPercentPerLetter: Double = 4.0,
        smartTimingMinimumWordLength: Int = 1,
        sentencePauseMultiplier: Double = 1.5,
        punctuationPauses: PunctuationPauses = PunctuationPauses(),
        sentenceBreakEnabled: Bool = false,
        sentenceBreakLength: Double = 1.0,
        complexityTimingEnabled: Bool = false,
        complexityIntensity: Double = 0.5,
        complexityScores: [Float]? = nil,
        chapters: [Chapter] = []
    ) {
        self.words = words
        self.currentIndex = words.isEmpty ? 0 : max(0, min(currentIndex, words.count - 1))
        self.wordsPerMinute = wordsPerMinute
        self.smartTimingEnabled = smartTimingEnabled
        self.sentencePauseEnabled = sentencePauseEnabled
        self.smartTimingPercentPerLetter = smartTimingPercentPerLetter
        self.smartTimingMinimumWordLength = smartTimingMinimumWordLength
        self.sentencePauseMultiplier = sentencePauseMultiplier
        self.punctuationPauses = punctuationPauses
        self.sentenceBreakEnabled = sentenceBreakEnabled
        self.sentenceBreakLength = sentenceBreakLength
        self.complexityTimingEnabled = complexityTimingEnabled
        self.complexityIntensity = complexityIntensity
        self.complexityScores = complexityScores
        setChapters(chapters)
    }

    /// Replaces the word array, position, and complexity scores after
    /// asynchronous loading. The position is clamped to the new bounds.
    /// Intended to be called once, while paused, on an engine created empty.
    func load(words: [String], currentIndex: Int, complexityScores: [Float]?, chapters: [Chapter] = []) {
        pause()
        self.words = words
        self.complexityScores = complexityScores
        self.currentIndex = words.isEmpty ? 0 : max(0, min(currentIndex, words.count - 1))
        furthestPlayedIndex = 0
        lastAnnouncedIndex = nil
        setChapters(chapters)
    }

    private func setChapters(_ chapters: [Chapter]) {
        chaptersByIndex = Self.announcedChapters(chapters, wordCount: words.count)
        readingStarts = ChapterHeading.readingStarts(for: chaptersByIndex, in: words)
    }

    /// The chapters playback announces, by the index of their first word:
    /// those with a title that start inside the document. The first of two
    /// at one index wins.
    nonisolated static func announcedChapters(_ chapters: [Chapter], wordCount: Int) -> [Int: Chapter] {
        Dictionary(
            chapters.filter { (0..<max(0, wordCount)).contains($0.wordIndex) && !$0.title.isEmpty }
                .map { ($0.wordIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Where reading goes on after the announcement of the chapter starting
    /// at `index`: past the words there that repeat its title, if any.
    func readingStart(ofChapterAt index: Int) -> Int {
        readingStarts[index] ?? index
    }

    /// Replaces the complexity scores (e.g. after a background backfill for a
    /// legacy document) without touching playback state.
    func updateComplexityScores(_ scores: [Float]?) {
        complexityScores = scores
    }

    /// Starts playback from the current position. No-op if already playing,
    /// at the end, or if no words are loaded. With a ``pacer``, starts it
    /// instead of announcing a chapter or timing the word.
    func play() {
        guard !isPlaying, !words.isEmpty, !isAtEnd else { return }
        isPlaying = true
        if let pacer {
            currentWordInterval = nil
            let context = pacerContext()
            pacedWordsPerMinute = context.wordsPerMinute
            pacedTiming = context.timing
            pacer.start(context)
            return
        }
        if !announceChapterIfNeeded() { scheduleNextWord() }
    }

    /// Where the pacer starts reading and what it needs to know to read
    /// on, from the engine's state.
    private func pacerContext() -> PacerContext {
        PacerContext(
            words: words,
            startIndex: currentIndex,
            chapters: chaptersByIndex,
            readingStarts: readingStarts,
            // The rule `announceChapterIfNeeded()` follows.
            announcesChapterAtStart: lastAnnouncedIndex != currentIndex
                && chaptersByIndex[currentIndex] != nil,
            wordsPerMinute: effectiveWordsPerMinute,
            timing: timing
        )
    }

    /// Stops playback, invalidates the timer (or stops the pacer), and
    /// discards any hold-to-read speed override so the next play resumes at
    /// the configured speed. Pausing during a chapter announcement moves the
    /// position past the words its title stands in for.
    func pause() {
        isPlaying = false
        stopTimer()
        pacer?.stop()
        if let chapter = chapterAnnouncement {
            currentIndex = readingStart(ofChapterAt: chapter.wordIndex)
        }
        chapterAnnouncement = nil
        isChapterTitleVisible = false
        isInSentenceBreak = false
        wpmOverride = nil
    }

    /// Jumps to a specific word index, clamped to valid bounds.
    func seek(to index: Int) {
        pause()
        lastAnnouncedIndex = nil
        currentIndex = max(0, min(index, words.count - 1))
    }

    /// Moves the position by `delta` words. Returns `true` if the move was clamped (hit a boundary).
    @discardableResult
    func scrub(by delta: Int) -> Bool {
        let target = currentIndex + delta
        seek(to: target)
        return currentIndex != target
    }

    /// Resets playback to the beginning of the word array.
    func restart() {
        seek(to: 0)
    }

    /// Returns the words played since the last call, and starts the count
    /// over.
    func takePlayedWordCount() -> Int {
        defer { playedWordCount = 0 }
        return playedWordCount
    }

    private func onPlaybackSettingChanged() {
        if let pacer {
            // The voice times each word itself, so only the speed and the
            // sentence breaks matter to it; it takes what it needs.
            guard isPlaying else { return }
            let speed = effectiveWordsPerMinute
            if speed != pacedWordsPerMinute {
                pacedWordsPerMinute = speed
                pacer.speedDidChange(wordsPerMinute: speed)
            }
            let timing = self.timing
            // Answering the speed can stop reading, as a failure does.
            guard isPlaying, timing != pacedTiming else { return }
            pacedTiming = timing
            pacer.timingDidChange(timing)
            return
        }
        guard isPlaying, chapterAnnouncement == nil else { return }
        // During a blank the deadline belongs to the blank, not to the word
        // still at `currentIndex`.
        let interval = isInSentenceBreak ? sentenceBreakInterval() : nextInterval()
        guard let source = timerSource, let scheduled = scheduledDeadline else {
            scheduleTimer(after: interval)
            return
        }
        // Only ever pull the current word's deadline earlier. Pushing it out
        // would let a continuously dragged settings slider (each didSet lands
        // here) stall playback on one word indefinitely.
        let candidate = DispatchTime.now() + interval
        if candidate < scheduled {
            scheduledDeadline = candidate
            source.schedule(deadline: candidate)
        }
    }

    /// Schedules (or reschedules) the single reusable timer for the next word
    /// advance. When `anchor` is set (the previous tick's deadline), the next
    /// deadline is measured from it so scheduling latency doesn't compound —
    /// clamped to now so a long stall (app suspension) can't cause a burst of
    /// catch-up ticks.
    private func scheduleNextWord(anchor: DispatchTime? = nil) {
        let interval = nextInterval()
        currentWordInterval = interval
        scheduleTimer(after: interval, anchor: anchor)
    }

    private func scheduleTimer(after interval: TimeInterval, anchor: DispatchTime? = nil) {
        guard isPlaying else { return }
        if timerSource == nil {
            let source = DispatchSource.makeTimerSource(queue: .main)
            source.setEventHandler { [weak self] in
                self?.advance()
            }
            source.resume()
            timerSource = source
        }
        let now = DispatchTime.now()
        let deadline = max((anchor ?? now) + interval, now)
        scheduledDeadline = deadline
        timerSource?.schedule(deadline: deadline)
    }

    private func stopTimer() {
        guard let source = timerSource else { return }
        source.setEventHandler {}
        source.cancel()
        timerSource = nil
        scheduledDeadline = nil
    }

    /// Handles one timer deadline. Internal so phase transitions can be
    /// exercised deterministically without wall-clock sleeps in tests.
    func advance() {
        guard isPlaying else { return }
        if let chapter = chapterAnnouncement {
            if isChapterTitleVisible {
                isChapterTitleVisible = false
                scheduleTimer(after: Self.chapterFadeDuration)
            } else {
                chapterAnnouncement = nil
                // Another chapter can start where this one's heading ends.
                // Otherwise the first word gets its full interval after the fade.
                currentIndex = readingStart(ofChapterAt: chapter.wordIndex)
                furthestPlayedIndex = max(furthestPlayedIndex, currentIndex)
                if !announceChapterIfNeeded() { scheduleNextWord() }
            }
            return
        }
        if currentIndex < words.count - 1 {
            let previousDeadline = scheduledDeadline
            if isInSentenceBreak {
                isInSentenceBreak = false
            } else if breaksAfterCurrentWord() {
                isInSentenceBreak = true
                scheduleTimer(after: sentenceBreakInterval(), anchor: previousDeadline)
                return
            }
            currentIndex += 1
            playedWordCount += 1
            furthestPlayedIndex = max(furthestPlayedIndex, currentIndex)
            if !announceChapterIfNeeded() { scheduleNextWord(anchor: previousDeadline) }
        } else {
            pause()
        }
    }

    /// Takes an event from the ``pacer``, which moves playback the way
    /// ``advance()`` does for the timer. Ignored while paused, so an event
    /// already on its way when playback paused changes nothing.
    func handle(_ event: PacerEvent) {
        guard isPlaying else { return }
        switch event {
        case .word(let index, let interval):
            guard words.indices.contains(index), index >= currentIndex else { return }
            movePaced(to: index)
            currentWordInterval = interval
            chapterAnnouncement = nil
            isChapterTitleVisible = false
            isInSentenceBreak = false
        case .chapterTitle(let index, let isVisible):
            guard index >= currentIndex, let chapter = chaptersByIndex[index] else { return }
            movePaced(to: index)
            isInSentenceBreak = false
            chapterAnnouncement = chapter
            isChapterTitleVisible = isVisible
            lastAnnouncedIndex = index
        case .sentenceBreak:
            isInSentenceBreak = true
        case .finished:
            // On the last word, so the reader shows that the document is done.
            if !words.isEmpty { movePaced(to: words.count - 1) }
            chapterAnnouncement = nil
            isChapterTitleVisible = false
            isInSentenceBreak = false
            pause()
        case .failed:
            pause()
        }
    }

    /// Moves playback forward to `index` for the pacer, counting the words
    /// passed as played the way ``advance()`` does. During a chapter
    /// announcement, the words its title stands in for don't count.
    private func movePaced(to index: Int) {
        guard index >= currentIndex else { return }
        var countedFrom = currentIndex
        if let chapter = chapterAnnouncement {
            countedFrom = max(countedFrom, readingStart(ofChapterAt: chapter.wordIndex))
        }
        playedWordCount += max(0, index - countedFrom)
        currentIndex = index
        furthestPlayedIndex = max(furthestPlayedIndex, index)
    }

    private func breaksAfterCurrentWord() -> Bool {
        Self.breaksAfterWord(
            at: currentIndex,
            in: words,
            nextWordStartsChapter: chaptersByIndex[currentIndex + 1] != nil,
            timing: timing
        )
    }

    /// The blank's time after a sentence. Internal so it can be verified
    /// without wall-clock sleeps in tests.
    func sentenceBreakInterval() -> TimeInterval {
        Self.sentenceBreakInterval(timing: timing, baseInterval: baseInterval)
    }

    /// Whether a blank follows the word at `index`: it ends a sentence and the
    /// next word doesn't open a chapter, whose announcement is a break of its
    /// own.
    nonisolated static func breaksAfterWord(
        at index: Int,
        in words: [String],
        nextWordStartsChapter: Bool,
        timing: ReaderSettings.TimingSnapshot
    ) -> Bool {
        guard timing.sentenceBreakEnabled, timing.sentenceBreakLength > 0,
              !nextWordStartsChapter else { return false }
        return SentenceBreak.endsSentence(at: index, in: words)
    }

    /// The blank's time after a sentence, at `baseInterval` per word: one
    /// word's time at the playback speed, so it follows WPM but none of the
    /// word's own timing.
    nonisolated static func sentenceBreakInterval(
        timing: ReaderSettings.TimingSnapshot,
        baseInterval: TimeInterval
    ) -> TimeInterval {
        guard timing.sentenceBreakEnabled else { return 0 }
        return baseInterval * max(0, timing.sentenceBreakLength)
    }

    private func announceChapterIfNeeded() -> Bool {
        guard lastAnnouncedIndex != currentIndex,
              let chapter = chaptersByIndex[currentIndex] else { return false }
        lastAnnouncedIndex = currentIndex
        chapterAnnouncement = chapter
        isChapterTitleVisible = true
        let titleWords = chapter.title.split(whereSeparator: \.isWhitespace).count
        scheduleTimer(after: max(1.6, min(4.0, Double(titleWords) * 0.3)))
        return true
    }

    /// The display time for the current word. Internal so the way the timing
    /// features compose can be verified without wall-clock sleeps in tests.
    func nextInterval() -> TimeInterval {
        Self.interval(
            forWordAt: currentIndex,
            in: words,
            complexityScores: complexityScores,
            timing: timing,
            baseInterval: baseInterval
        )
    }

    /// The timing settings as one value, for the shared per-word math.
    private var timing: ReaderSettings.TimingSnapshot {
        ReaderSettings.TimingSnapshot(
            smartTimingEnabled: smartTimingEnabled,
            sentencePauseEnabled: sentencePauseEnabled,
            smartTimingPercentPerLetter: smartTimingPercentPerLetter,
            smartTimingMinimumWordLength: smartTimingMinimumWordLength,
            sentencePauseMultiplier: sentencePauseMultiplier,
            complexityTimingEnabled: complexityTimingEnabled,
            complexityIntensity: complexityIntensity,
            punctuationPauses: punctuationPauses,
            sentenceBreakEnabled: sentenceBreakEnabled,
            sentenceBreakLength: sentenceBreakLength
        )
    }

    /// The display time for the word at `index` under `timing`, at
    /// `baseInterval` per plain word. Playback and ``ReadingPace``'s
    /// estimates both time words here, so the two can't drift apart. Every
    /// term scales with `baseInterval`, so a word takes the same number of
    /// base intervals at any speed.
    nonisolated static func interval(
        forWordAt index: Int,
        in words: [String],
        complexityScores: [Float]?,
        timing: ReaderSettings.TimingSnapshot,
        baseInterval: TimeInterval
    ) -> TimeInterval {
        let word = words.indices.contains(index) ? words[index] : ""
        var interval = baseInterval
        var wordTime = 1.0

        // Punctuation pauses own all punctuation timing while they are on, so
        // smart timing drops its own trailing-punctuation bonus rather than
        // pausing twice for the same mark.
        if timing.smartTimingEnabled {
            wordTime = smartTimingMultiplier(
                for: word,
                percentPerLetter: timing.smartTimingPercentPerLetter,
                minimumWordLength: timing.smartTimingMinimumWordLength,
                punctuationBonus: !timing.sentencePauseEnabled
            )
        }

        // A compound's further parts add to the word's time instead of scaling
        // it: smart timing has already counted every letter, so each part
        // contributes only its per-word share. Pauses and complexity then
        // scale the whole word.
        wordTime += CompoundWord.additionalIntervals(for: word)
        // An acronym's further letter names add their share the same way.
        wordTime += Acronym.additionalIntervals(at: index, in: words)
        interval *= wordTime

        if timing.sentencePauseEnabled {
            interval *= timing.punctuationPauses.multiplier(
                for: PunctuationMarks.marks(in: word),
                sentenceEnd: timing.sentencePauseMultiplier
            )
        }

        if timing.complexityTimingEnabled, let scores = complexityScores,
           scores.indices.contains(index) {
            let score = Double(scores[index])
            interval *= complexityMultiplier(score: score, intensity: timing.complexityIntensity)
        }

        return interval
    }

    /// Maps a complexity score (0.0–1.0) and intensity (0.0–1.0) to a timing multiplier.
    ///
    /// At score 0.0 (trivial word) and full intensity: 0.7× (30% faster).
    /// At score 0.5 (average word): 1.0× (no change).
    /// At score 1.0 (complex word) and full intensity: 1.6× (60% slower).
    /// At zero intensity, the multiplier is always 1.0.
    nonisolated static func complexityMultiplier(score: Double, intensity: Double) -> Double {
        1.0 + (score - 0.5) * 1.2 * intensity
    }

    /// Returns a timing multiplier based on word length.
    /// Each letter contributes `percentPerLetter`% to the interval increase,
    /// but only for words with at least `minimumWordLength` letters (after
    /// trimming punctuation) — shorter words return 1.0 so they display at
    /// exactly the base rate. E.g. at 4%, an 8-letter word yields 1.32×.
    /// Trailing punctuation (commas, etc.) adds a fixed 0.2 bonus when
    /// `percentPerLetter > 0` regardless of length — it marks a clause
    /// boundary, not a long word. Pass `punctuationBonus: false` when
    /// punctuation pauses already time that boundary.
    nonisolated static func smartTimingMultiplier(
        for word: String,
        percentPerLetter: Double = 4.0,
        minimumWordLength: Int = 1,
        punctuationBonus: Bool = true
    ) -> Double {
        let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
        // The space inside a number unit (`2000 BCE`) is not a letter.
        let letterCount = trimmed.reduce(into: 0) { count, character in
            if character != " " { count += 1 }
        }

        var multiplier = 1.0
        if letterCount >= minimumWordLength {
            multiplier += Double(letterCount) * (percentPerLetter / 100.0)
        }

        if punctuationBonus, percentPerLetter > 0, hasTrailingPunctuation(word) {
            multiplier += 0.2
        }

        return multiplier
    }

    /// Maps a hold-to-read vertical drag to a temporary WPM. Movement within
    /// ±15pt of the touch-down point changes nothing; beyond that dead zone,
    /// each point is worth 2.5 WPM (up = faster), measured from the dead-zone
    /// edge. The result is always snapped to `ReaderSettings.wpmStep` and
    /// clamped to `ReaderSettings.wpmRange`.
    nonisolated static func holdSpeedWPM(baseWPM: Int, verticalTranslation: Double) -> Int {
        let deadZone = 15.0
        let wpmPerPoint = 2.5
        let magnitude = abs(verticalTranslation)
        let delta = magnitude > deadZone
            ? (magnitude - deadZone) * wpmPerPoint * (verticalTranslation < 0 ? 1 : -1)
            : 0
        let step = ReaderSettings.wpmStep
        let snapped = ((Double(baseWPM) + delta) / step).rounded() * step
        return Int(min(ReaderSettings.wpmRange.upperBound,
                       max(ReaderSettings.wpmRange.lowerBound, snapped)))
    }

    nonisolated private static func hasTrailingPunctuation(_ word: String) -> Bool {
        guard let last = word.unicodeScalars.last else { return false }
        return CharacterSet.punctuationCharacters.contains(last)
    }

    deinit {
        stopTimer()
    }
}
