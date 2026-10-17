import Testing
@testable import Strobe

struct HandsFreeReadingTests {

    private typealias Situation = ReaderTouch.Situation

    // Hold to Read on.
    private static let holdPaused = Situation(holdToRead: true, isPlaying: false, isAtEnd: false)
    private static let holding = Situation(holdToRead: true, isPlaying: true, isAtEnd: false)
    private static let handsFree = Situation(holdToRead: true, isPlaying: true, isAtEnd: false, isHandsFree: true)
    private static let holdAtLastWord = Situation(holdToRead: true, isPlaying: false, isAtEnd: true)

    // Hold to Read off.
    private static let tapPaused = Situation(holdToRead: false, isPlaying: false, isAtEnd: false)
    private static let tapPlaying = Situation(holdToRead: false, isPlaying: true, isAtEnd: false)
    private static let tapAtLastWord = Situation(holdToRead: false, isPlaying: false, isAtEnd: true)

    private static let allModes: [ReaderTouch.Mode] = [.undecided, .reading, .scrubbing, .twoFinger]

    // MARK: - Second finger with Hold to Read

    @Test func secondFingerStartsHandsFreeReading() {
        #expect(ReaderTouch.secondFinger(in: Self.holdPaused) == .readHandsFree)
    }

    @Test func secondFingerTurnsAHoldHandsFree() {
        #expect(ReaderTouch.secondFinger(in: Self.holding) == .readHandsFree)
    }

    @Test func secondFingerDuringHandsFreeReadingStopsIt() {
        #expect(ReaderTouch.secondFinger(in: Self.handsFree) == .pause)
    }

    @Test func handsFreeOnlyCountsWhileReading() {
        // The pause that ends hands-free reading can land just before the
        // flag clears; two fingers then start reading again.
        var paused = Self.handsFree
        paused.isPlaying = false
        #expect(ReaderTouch.secondFinger(in: paused) == .readHandsFree)
    }

    @Test func secondFingerAtTheLastWordShowsCompletion() {
        #expect(ReaderTouch.secondFinger(in: Self.holdAtLastWord) == .showCompletion)
    }

    @Test func secondFingerOnTheLastWordWhileReadingGoesHandsFree() {
        // The last word is still showing; reading stops on its own after it.
        var lastWord = Self.holding
        lastWord.isAtEnd = true
        #expect(ReaderTouch.secondFinger(in: lastWord) == .readHandsFree)
    }

    @Test func secondFingerDoesNothingOverTheCompletionCard() {
        var finished = Self.holdAtLastWord
        finished.showsCompletion = true
        #expect(ReaderTouch.secondFinger(in: finished) == .unchanged)
        finished.holdToRead = false
        #expect(ReaderTouch.secondFinger(in: finished) == .unchanged)
    }

    // MARK: - Second finger with Tap to Read

    @Test func secondFingerCountsAsATapWithoutHoldToRead() {
        #expect(ReaderTouch.secondFinger(in: Self.tapPaused) == .play)
        #expect(ReaderTouch.secondFinger(in: Self.tapPlaying) == .pause)
        #expect(ReaderTouch.secondFinger(in: Self.tapAtLastWord) == .showCompletion)
    }

    // MARK: - Release

    @Test func releasingAHoldPauses() {
        #expect(ReaderTouch.release(of: .reading, in: Self.holding) == .pause)
    }

    @Test func aQuickTapWithHoldToReadDoesNothing() {
        #expect(ReaderTouch.release(of: .undecided, in: Self.holdPaused) == .unchanged)
    }

    @Test func aTapStopsHandsFreeReading() {
        #expect(ReaderTouch.release(of: .undecided, in: Self.handsFree) == .pause)
        // A hold that took over hands-free reading pauses when it lets go.
        #expect(ReaderTouch.release(of: .reading, in: Self.handsFree) == .pause)
    }

    @Test func liftingTwoFingersKeepsReading() {
        #expect(ReaderTouch.release(of: .twoFinger, in: Self.handsFree) == .unchanged)
        #expect(ReaderTouch.release(of: .twoFinger, in: Self.tapPlaying) == .unchanged)
        #expect(ReaderTouch.release(of: .twoFinger, in: Self.tapPaused) == .unchanged)
    }

    @Test func tapToReadReleaseToggles() {
        #expect(ReaderTouch.release(of: .undecided, in: Self.tapPaused) == .play)
        #expect(ReaderTouch.release(of: .undecided, in: Self.tapPlaying) == .pause)
        #expect(ReaderTouch.release(of: .undecided, in: Self.tapAtLastWord) == .showCompletion)
    }

    @Test func tapToReadSwipeIsNotATap() {
        #expect(ReaderTouch.release(of: .scrubbing, in: Self.tapPaused) == .unchanged)
    }

    @Test func tapToReadReleaseOverTheCompletionCardDoesNothing() {
        var finished = Self.tapAtLastWord
        finished.showsCompletion = true
        #expect(ReaderTouch.release(of: .undecided, in: finished) == .unchanged)
    }

    // MARK: - Cancellation

    @Test func countedFingersLeaveCancellationToCleanUpOnly() {
        for mode in Self.allModes {
            for situation in [Self.holdPaused, Self.holding, Self.handsFree, Self.tapPaused, Self.tapPlaying] {
                #expect(ReaderTouch.cancellation(of: mode, in: situation, detection: .counted) == .unchanged)
            }
        }
    }

    @Test func inferredCancellationActsAsASecondFinger() {
        let inferred = ReaderTouch.SecondFingerDetection.inferredFromCancellation
        #expect(ReaderTouch.cancellation(of: .undecided, in: Self.holdPaused, detection: inferred) == .readHandsFree)
        #expect(ReaderTouch.cancellation(of: .reading, in: Self.holding, detection: inferred) == .readHandsFree)
        #expect(ReaderTouch.cancellation(of: .undecided, in: Self.handsFree, detection: inferred) == .pause)
        #expect(ReaderTouch.cancellation(of: .undecided, in: Self.holdAtLastWord, detection: inferred) == .showCompletion)
        #expect(ReaderTouch.cancellation(of: .undecided, in: Self.tapPaused, detection: inferred) == .play)
        #expect(ReaderTouch.cancellation(of: .undecided, in: Self.tapPlaying, detection: inferred) == .pause)
    }

    @Test func inferredCancellationOfASwipeChangesNothing() {
        let inferred = ReaderTouch.SecondFingerDetection.inferredFromCancellation
        #expect(ReaderTouch.cancellation(of: .scrubbing, in: Self.holdPaused, detection: inferred) == .unchanged)
        #expect(ReaderTouch.cancellation(of: .scrubbing, in: Self.tapPaused, detection: inferred) == .unchanged)
    }

    @Test func cancellationWithoutMultiTouchLetsGoOfAHold() {
        #expect(ReaderTouch.cancellation(of: .reading, in: Self.holding, detection: .unavailable) == .pause)
        #expect(ReaderTouch.cancellation(of: .undecided, in: Self.holdPaused, detection: .unavailable) == .unchanged)
    }

    @Test func cancellationWithoutMultiTouchIsNeverATap() {
        #expect(ReaderTouch.cancellation(of: .undecided, in: Self.tapPaused, detection: .unavailable) == .unchanged)
        #expect(ReaderTouch.cancellation(of: .undecided, in: Self.tapPlaying, detection: .unavailable) == .unchanged)
    }
}
