import Foundation

/// Moves playback from word to word in place of the engine's timer, as
/// reading aloud does: the voice, not each word's own timing, decides when
/// the next word shows. Set on ``RSVPEngine/pacer``. The engine starts it on
/// play, stops it on pause (and so on seeking and scrubbing), passes on
/// speed and timing changes, and takes its events through
/// ``RSVPEngine/handle(_:)``.
protocol WordPacer: AnyObject {
    /// Starts reading at `context.startIndex`. Events go to `onEvent`, on
    /// the main actor, until `stop()`.
    func start(_ context: PacerContext)
    /// Stops at once. No events follow.
    func stop()
    /// The speed changed while reading.
    func speedDidChange(wordsPerMinute: Int)
    /// The timing settings changed while reading. Only the sentence breaks'
    /// apply to a voice (see ``PacerContext/timing``).
    func timingDidChange(_ timing: ReaderSettings.TimingSnapshot)
    var onEvent: ((PacerEvent) -> Void)? { get set }
}

/// What a pacer needs to read from where playback is.
nonisolated struct PacerContext {
    let words: [String]
    let startIndex: Int
    /// The chapters playback announces, by the index of their first word
    /// (``RSVPEngine/announcedChapters(_:wordCount:)``).
    let chapters: [Int: Chapter]
    /// Where reading goes on after each announced chapter's title: past the
    /// words that repeat it (``ChapterHeading``).
    let readingStarts: [Int: Int]
    /// Whether a chapter starting at `startIndex` is announced first. False
    /// when its title has already shown, as after pausing during it.
    let announcesChapterAtStart: Bool
    let wordsPerMinute: Int
    /// For sentence breaks (`sentenceBreakEnabled`, `sentenceBreakLength`);
    /// the per-word timing settings don't apply to a voice.
    let timing: ReaderSettings.TimingSnapshot
}

/// What a pacer tells the engine as it reads.
nonisolated enum PacerEvent: Equatable {
    /// The word at this index is being spoken, and shows for `interval`
    /// seconds until the next word, when the pacer knows. Only ever moves
    /// forward, and ends any chapter announcement or sentence break.
    case word(Int, interval: TimeInterval? = nil)
    /// The title of the chapter starting at this index is being spoken
    /// (`isVisible`), or fading out after it.
    case chapterTitle(at: Int, isVisible: Bool)
    /// A blank between sentences starts.
    case sentenceBreak
    /// The last word has been spoken.
    case finished
    /// Speech stopped working; playback pauses where it is.
    case failed
}
