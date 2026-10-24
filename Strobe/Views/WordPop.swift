import SwiftUI

/// How a new word pops in while Pop Words In is on, like the word-by-word
/// captions of short videos: it starts a little small, grows a little past
/// its size, and settles. It scales around its anchor letter, so the
/// fixation point never moves, and only the word pops: the guide line and
/// the neighbours hold still. Reduce Motion turns it off.
nonisolated enum WordPop {
    /// What a word view needs to pop its word.
    struct Cue: Equatable {
        /// Changes whenever a new word shows. Each change starts the pop
        /// `style` gives.
        let trigger: Int?
        let style: Style
        let duration: TimeInterval

        /// Time spent growing to `peakScale`.
        var riseDuration: TimeInterval { duration * WordPop.riseFraction }
        /// Time spent settling back to full size.
        var settleDuration: TimeInterval { duration - riseDuration }
    }

    enum Style: Equatable {
        /// The word changes in place.
        case still
        /// The word grows in, a little past its size, and settles.
        case pop
    }

    /// The size a word pops in at, as a fraction of its own.
    static let startScale: CGFloat = 0.8
    /// The size it grows to before settling.
    static let peakScale: CGFloat = 1.06
    /// The share of a pop spent growing to `peakScale`.
    static let riseFraction: Double = 0.55

    /// The share of a word's time a pop takes, so the word holds still for
    /// the rest of it, even at the top speed.
    static let intervalFraction: Double = 0.5
    /// The longest a pop takes, reached below about 170 wpm, so slow
    /// reading doesn't get a sluggish pop.
    static let maximumDuration: TimeInterval = 0.18

    /// How long a pop takes at `wordsPerMinute` for a word shown for
    /// `wordInterval`: half a base interval (one plain word's time), up to
    /// `maximumDuration`. Words shown for longer pop the same, so the
    /// rhythm stays even; a word shown for less, which complexity timing
    /// can make of the plainest words and a voice of its quickest, pops for
    /// half its own time.
    static func duration(wordsPerMinute: Int, wordInterval: TimeInterval? = nil) -> TimeInterval {
        let baseInterval = 60 / Double(max(1, wordsPerMinute))
        let time = max(0, min(baseInterval, wordInterval ?? baseInterval))
        return min(maximumDuration, time * intervalFraction)
    }

    /// How a word that shows while playing comes in: it pops, unless Reduce
    /// Motion is on.
    static func style(reduceMotion: Bool) -> Style {
        reduceMotion ? .still : .pop
    }

    /// The reader's cue for its word at `index`, shown for `wordInterval`.
    /// The trigger changes with every new word, a repeated word included,
    /// and when the word comes back after a chapter title or a sentence
    /// break, which hide it. Only a change while playing pops: scrubbing,
    /// stepping, and seeking change the word in place, and a hidden word
    /// has nothing to show.
    static func readerCue(
        index: Int,
        isShown: Bool,
        isPlaying: Bool,
        reduceMotion: Bool,
        wordsPerMinute: Int,
        wordInterval: TimeInterval? = nil
    ) -> Cue {
        Cue(
            trigger: isShown ? index : nil,
            style: isPlaying && isShown ? style(reduceMotion: reduceMotion) : .still,
            duration: duration(wordsPerMinute: wordsPerMinute, wordInterval: wordInterval)
        )
    }

    /// The anchor letter's center across the word, from 0 at its left edge
    /// to 1 at its right, from the widths of the text before the anchor,
    /// the anchor, and the text after it. A right-to-left word has the text
    /// before its anchor on the right. A word with no width scales around
    /// its middle.
    static func anchorX(
        beforeWidth: CGFloat,
        anchorWidth: CGFloat,
        afterWidth: CGFloat,
        isRightToLeft: Bool
    ) -> CGFloat {
        let width = beforeWidth + anchorWidth + afterWidth
        guard width > 0 else { return 0.5 }
        let leading = isRightToLeft ? afterWidth : beforeWidth
        return (leading + anchorWidth / 2) / width
    }

    /// One moment of a pop.
    struct Frame {
        var scale: CGFloat

        static let rest = Frame(scale: 1)
    }

    /// The pop `cue` starts. A pop eases out from `startScale` to
    /// `peakScale`, then eases back to full size. It starts at once,
    /// whatever was showing, so a word that comes before the last one
    /// settled still pops.
    @KeyframesBuilder<Frame>
    static func keyframes(for cue: Cue) -> some Keyframes<Frame> {
        KeyframeTrack(\.scale) {
            if cue.style == .pop {
                MoveKeyframe(startScale)
                CubicKeyframe(
                    peakScale,
                    duration: cue.riseDuration,
                    startVelocity: easeOutVelocity(from: startScale, to: peakScale, over: cue.riseDuration),
                    endVelocity: 0
                )
                CubicKeyframe(1, duration: cue.settleDuration, startVelocity: 0, endVelocity: 0)
            } else {
                MoveKeyframe(1)
            }
        }
    }

    /// The starting speed of a cubic ease-out from `start` to `end` over
    /// `duration`: fast at first, slowing to a stop.
    private static func easeOutVelocity<Value: BinaryFloatingPoint>(
        from start: Value,
        to end: Value,
        over duration: TimeInterval
    ) -> Value {
        guard duration > 0 else { return 0 }
        return 3 * (end - start) / Value(duration)
    }
}

/// Pops the content each time its cue's trigger changes, scaling it around
/// `anchor`, the anchor letter's center. A nil cue leaves the content as
/// it is.
struct WordPopEffect: ViewModifier {
    let cue: WordPop.Cue?
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        if let cue {
            // Only the content closure runs on each frame of a pop, so the
            // word isn't laid out again while it scales.
            content.keyframeAnimator(initialValue: WordPop.Frame.rest, trigger: cue.trigger) { [anchor] word, frame in
                word
                    .scaleEffect(frame.scale, anchor: anchor)
            } keyframes: { _ in
                WordPop.keyframes(for: cue)
            }
        } else {
            content
        }
    }
}
