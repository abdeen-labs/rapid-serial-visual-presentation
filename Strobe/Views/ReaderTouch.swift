import Foundation

/// What a touch on the reader does to playback, at the three moments it can
/// change it: when the finger lifts, when SwiftUI cancels the touch, and
/// when a second finger lands.
///
/// A second finger is how hands-free reading starts. With Hold to Read on,
/// reading starts (or a hold's reading carries on) and keeps going after the
/// fingers lift, until a tap, two fingers again, or any other pause stops
/// it. With Hold to Read off, reading is already hands-free, and a second
/// finger counts as a tap.
nonisolated enum ReaderTouch {
    /// What the current touch is doing, decided as it moves.
    nonisolated enum Mode: Equatable {
        /// Down, but neither holding to read nor swiping yet.
        case undecided
        /// A hold that has started reading.
        case reading
        /// A horizontal swipe stepping through words.
        case scrubbing
        /// A second finger landed and did what this touch does. The rest
        /// of the touch, lifting the fingers included, changes nothing.
        case twoFinger
    }

    /// How the reader learns that a second finger joined a touch.
    nonisolated enum SecondFingerDetection: Equatable {
        /// The fingers down are counted (iOS 18 and later), apart from the
        /// touch's own gesture.
        case counted
        /// Nothing counts them (iOS 17), so a cancelled touch is taken for
        /// one: a second finger landing is what makes SwiftUI cancel a
        /// one-finger drag on the reader.
        case inferredFromCancellation
        /// There's no second finger (macOS).
        case unavailable
    }

    /// The reader's state, as far as what a touch does depends on it.
    nonisolated struct Situation: Equatable {
        var holdToRead: Bool
        var isPlaying: Bool
        var isAtEnd: Bool
        /// Reading started hands-free and hasn't paused since.
        var isHandsFree = false
        /// The completion card is up.
        var showsCompletion = false
    }

    /// A change to playback.
    nonisolated enum Outcome: Equatable {
        case unchanged
        case play
        case pause
        /// At the last word, where reading can't start.
        case showCompletion
        /// Start reading if it isn't already, and keep it going after the
        /// fingers lift.
        case readHandsFree
    }

    /// What lifting the finger does.
    static func release(of mode: Mode, in situation: Situation) -> Outcome {
        guard mode != .twoFinger else { return .unchanged }
        if situation.holdToRead {
            return situation.isPlaying ? .pause : .unchanged
        }
        // Tap to Read: a release without a horizontal swipe counts as a tap.
        guard mode != .scrubbing, !situation.showsCompletion else { return .unchanged }
        return tap(in: situation)
    }

    /// What a second finger joining the touch does, whatever the touch was
    /// doing until then.
    static func secondFinger(in situation: Situation) -> Outcome {
        guard !situation.showsCompletion else { return .unchanged }
        guard situation.holdToRead else { return tap(in: situation) }
        // Two fingers again stop hands-free reading, as a tap does.
        if situation.isHandsFree && situation.isPlaying { return .pause }
        if !situation.isPlaying && situation.isAtEnd { return .showCompletion }
        return .readHandsFree
    }

    /// What a touch does when SwiftUI cancels it. A cancelled touch never
    /// gets a release, so this stands in for one.
    static func cancellation(
        of mode: Mode,
        in situation: Situation,
        detection: SecondFingerDetection
    ) -> Outcome {
        switch detection {
        case .counted:
            // A second finger is reported on its own, possibly just after
            // the cancellation it causes; acting here too would act on it
            // twice. Anything else that takes a touch over (a system
            // gesture) leaves playback alone.
            return .unchanged
        case .inferredFromCancellation:
            // A swipe is never taken for two fingers.
            guard mode == .undecided || mode == .reading else { return .unchanged }
            return secondFinger(in: situation)
        case .unavailable:
            // Letting go, for Hold to Read, but never a tap.
            return situation.holdToRead && situation.isPlaying ? .pause : .unchanged
        }
    }

    /// A tap with Hold to Read off.
    private static func tap(in situation: Situation) -> Outcome {
        if situation.isPlaying { return .pause }
        // A tap at the last word can't start playback: show the completion
        // card rather than a false "playing" haptic with no visible change.
        return situation.isAtEnd ? .showCompletion : .play
    }
}
