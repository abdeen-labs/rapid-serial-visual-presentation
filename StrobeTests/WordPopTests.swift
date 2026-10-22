import Testing
import Foundation
import SwiftUI
import CoreGraphics
@testable import Strobe

struct WordPopTests {

    /// One plain word's time at `wordsPerMinute`, as the engine times it.
    private static func baseInterval(_ wordsPerMinute: Int) -> TimeInterval {
        60 / Double(wordsPerMinute)
    }

    private static let speeds = Array(
        stride(from: Int(ReaderSettings.wpmRange.lowerBound),
               through: Int(ReaderSettings.wpmRange.upperBound),
               by: Int(ReaderSettings.wpmStep))
    )

    // MARK: - Duration

    /// At 300 wpm a word shows for 200 ms, and pops for the first half.
    @Test func defaultSpeedPopsForHalfAWord() {
        #expect(abs(WordPop.duration(wordsPerMinute: ReaderSettings.Defaults.defaultWPM) - 0.1) < 1e-9)
    }

    /// At 1000 wpm a word shows for 60 ms, and pops for 30.
    @Test func topSpeedPopsForHalfAWord() {
        #expect(abs(WordPop.duration(wordsPerMinute: 1000) - 0.03) < 1e-9)
    }

    /// At 100 wpm a word shows for 600 ms; the pop stays short.
    @Test func slowSpeedsTakeTheLongestPop() {
        #expect(WordPop.duration(wordsPerMinute: 100) == WordPop.maximumDuration)
        #expect(WordPop.duration(wordsPerMinute: 160) == WordPop.maximumDuration)
        #expect(WordPop.duration(wordsPerMinute: 170) < WordPop.maximumDuration)
        #expect(WordPop.maximumDuration <= 0.2)
    }

    /// At every speed the pop ends with at least half the word's time to
    /// spare, whether timing stretches the word or complexity timing
    /// shortens it, as far as its plainest words at full intensity.
    @Test func popEndsWellInsideEveryWord() {
        let shortest = RSVPEngine.complexityMultiplier(score: 0, intensity: 1)
        #expect(shortest < 1)
        for speed in Self.speeds {
            let base = Self.baseInterval(speed)
            #expect(WordPop.duration(wordsPerMinute: speed) <= base / 2 + 1e-12, "\(speed) wpm")
            for share in [shortest, 0.7, 1, 1.32, 2.25, 4] {
                let wordInterval = base * share
                let duration = WordPop.duration(wordsPerMinute: speed, wordInterval: wordInterval)
                #expect(duration > 0, "\(speed) wpm, \(share)")
                #expect(duration <= wordInterval / 2 + 1e-12, "\(speed) wpm, \(share)")
            }
        }
    }

    /// Smart timing and pauses keep a word longer, but its pop stays the
    /// length of a plain word's, so the rhythm stays even.
    @Test func longerWordsPopLikePlainOnes() {
        for speed in [100, 300, 1000] {
            let plain = WordPop.duration(wordsPerMinute: speed)
            #expect(WordPop.duration(wordsPerMinute: speed, wordInterval: Self.baseInterval(speed) * 1.5) == plain)
            #expect(WordPop.duration(wordsPerMinute: speed, wordInterval: Self.baseInterval(speed)) == plain)
        }
    }

    /// A word complexity timing shows for 0.4 of a base interval pops for
    /// half that.
    @Test func shortenedWordsPopForHalfTheirTime() {
        let duration = WordPop.duration(wordsPerMinute: 1000, wordInterval: 0.024)
        #expect(abs(duration - 0.012) < 1e-9)
    }

    @Test func fasterReadingNeverLengthensThePop() {
        let durations = Self.speeds.map { WordPop.duration(wordsPerMinute: $0) }
        #expect(zip(durations, durations.dropFirst()).allSatisfy { $0 >= $1 })
    }

    /// A speed of zero or less, which the engine reads as 1 wpm, gets the
    /// longest pop rather than dividing by zero.
    @Test func nonPositiveSpeedsTakeTheLongestPop() {
        #expect(WordPop.duration(wordsPerMinute: 0) == WordPop.maximumDuration)
        #expect(WordPop.duration(wordsPerMinute: -5) == WordPop.maximumDuration)
    }

    @Test func growingAndSettlingSplitThePop() {
        for speed in Self.speeds {
            let cue = WordPop.Cue(trigger: 0, style: .pop, duration: WordPop.duration(wordsPerMinute: speed))
            #expect(cue.riseDuration > 0, "\(speed) wpm")
            #expect(cue.settleDuration > 0, "\(speed) wpm")
            #expect(abs(cue.riseDuration + cue.settleDuration - cue.duration) < 1e-12, "\(speed) wpm")
        }
    }

    /// The word starts small, overshoots a little, and settles at its size.
    @Test func popOvershootsSlightly() {
        #expect(WordPop.startScale < 1)
        #expect(WordPop.peakScale > 1)
        #expect(WordPop.peakScale < 1.1)
        #expect(WordPop.fadeStartOpacity > 0 && WordPop.fadeStartOpacity < 1)
    }

    // MARK: - Keyframes

    /// The keyframes a cue of `style` starts, from `frame`: at rest, or
    /// partway through the last word's pop.
    private static func timeline(
        _ style: WordPop.Style,
        wordsPerMinute: Int = 300,
        from frame: WordPop.Frame = .rest
    ) -> (WordPop.Cue, KeyframeTimeline<WordPop.Frame>) {
        let cue = WordPop.Cue(trigger: 1, style: style, duration: WordPop.duration(wordsPerMinute: wordsPerMinute))
        return (cue, KeyframeTimeline(initialValue: frame) { WordPop.keyframes(for: cue) })
    }

    /// A frame partway through a pop or a fade.
    private static let midPop = WordPop.Frame(scale: 1.03, opacity: 0.7)

    /// The word shows small at once, even when the last word hadn't
    /// settled, grows fast, peaks a little past its size, and settles at it
    /// when the pop's time is up, never going smaller than it started or
    /// past the peak.
    @Test func popGrowsPastTheWordsSizeAndSettles() {
        for (speed, frame) in [(100, WordPop.Frame.rest), (300, .rest), (300, Self.midPop), (1000, .rest)] {
            let (cue, timeline) = Self.timeline(.pop, wordsPerMinute: speed, from: frame)
            #expect(abs(timeline.duration - cue.duration) < 1e-9, "\(speed) wpm")
            #expect(abs(timeline.value(time: 0).scale - WordPop.startScale) < 1e-9, "\(speed) wpm")
            #expect(abs(timeline.value(time: cue.riseDuration).scale - WordPop.peakScale) < 1e-6, "\(speed) wpm")
            #expect(abs(timeline.value(time: cue.duration).scale - 1) < 1e-6, "\(speed) wpm")
            // Eased out: a quarter of the way in, well over a quarter grown.
            let quarter = timeline.value(time: cue.riseDuration / 4).scale
            #expect(quarter > WordPop.startScale + (WordPop.peakScale - WordPop.startScale) / 2, "\(speed) wpm")
            var previous = WordPop.startScale
            for step in 0...100 {
                let time = cue.duration * Double(step) / 100
                let frame = timeline.value(time: time)
                #expect(frame.scale >= WordPop.startScale - 1e-9 && frame.scale <= WordPop.peakScale + 1e-9, "\(speed) wpm, \(time)s")
                #expect(frame.opacity == 1, "\(speed) wpm, \(time)s")
                if time <= cue.riseDuration {
                    #expect(frame.scale >= previous - 1e-9, "\(speed) wpm, \(time)s")
                } else {
                    #expect(frame.scale <= previous + 1e-9, "\(speed) wpm, \(time)s")
                }
                previous = frame.scale
            }
        }
    }

    /// Under Reduce Motion the word keeps its size and only fades in.
    @Test func fadeKeepsTheWordsSize() {
        let (cue, timeline) = Self.timeline(.fade, from: Self.midPop)
        #expect(abs(timeline.value(time: 0).opacity - WordPop.fadeStartOpacity) < 1e-9)
        #expect(abs(timeline.value(time: cue.duration).opacity - 1) < 1e-6)
        for step in 0...20 {
            let frame = timeline.value(time: cue.duration * Double(step) / 20)
            #expect(frame.scale == 1)
            #expect(frame.opacity >= WordPop.fadeStartOpacity - 1e-9 && frame.opacity <= 1 + 1e-9)
        }
    }

    /// A word changed while paused, or hidden, shows at rest straight away,
    /// even one caught mid-pop.
    @Test func stillWordsRestAtOnce() {
        for frame in [WordPop.Frame.rest, Self.midPop] {
            let (_, timeline) = Self.timeline(.still, from: frame)
            #expect(timeline.duration == 0)
            #expect(timeline.value(time: 0).scale == 1)
            #expect(timeline.value(time: 0).opacity == 1)
        }
    }

    // MARK: - Reader cue

    private static func cue(
        index: Int = 4,
        isShown: Bool = true,
        isPlaying: Bool = true,
        reduceMotion: Bool = false,
        wordsPerMinute: Int = 300
    ) -> WordPop.Cue {
        WordPop.readerCue(
            index: index,
            isShown: isShown,
            isPlaying: isPlaying,
            reduceMotion: reduceMotion,
            wordsPerMinute: wordsPerMinute
        )
    }

    @Test func eachNewWordPopsWhilePlaying() {
        let current = Self.cue(index: 4)
        let next = Self.cue(index: 5)
        #expect(current.style == .pop)
        #expect(next.style == .pop)
        #expect(current.trigger != next.trigger)
    }

    /// "that that": the trigger follows the position, not the text, so a
    /// repeated word pops again.
    @Test func repeatedWordPopsAgain() {
        let words = ["that", "that"]
        let first = Self.cue(index: 0)
        let second = Self.cue(index: 1)
        #expect(words[0] == words[1])
        #expect(first.trigger != second.trigger)
        #expect(second.style == .pop)
    }

    /// Scrubbing, stepping, and seeking change the word without a pop.
    @Test func wordsChangedWhilePausedDoNotPop() {
        #expect(Self.cue(index: 9, isPlaying: false).style == .still)
        #expect(Self.cue(index: 9, isPlaying: false, reduceMotion: true).style == .still)
    }

    /// Playing and pausing on a word keep its trigger, so neither pops the
    /// word already showing.
    @Test func playingAndPausingDoNotPopTheShownWord() {
        #expect(Self.cue(index: 4, isPlaying: true).trigger == Self.cue(index: 4, isPlaying: false).trigger)
    }

    /// A chapter title or a sentence break hides the word: nothing pops
    /// while it's hidden, and its trigger changes so it pops on coming back.
    @Test func hiddenWordPopsOnComingBack() {
        let hidden = Self.cue(index: 12, isShown: false)
        let back = Self.cue(index: 12, isShown: true)
        #expect(hidden.trigger == nil)
        #expect(hidden.style == .still)
        #expect(back.trigger != hidden.trigger)
        #expect(back.style == .pop)
    }

    /// Paused during a chapter title, reading moves past it without a pop.
    @Test func wordShownByPausingDoesNotPop() {
        let back = Self.cue(index: 12, isShown: true, isPlaying: false)
        #expect(back.trigger != Self.cue(index: 12, isShown: false).trigger)
        #expect(back.style == .still)
    }

    @Test func reduceMotionFadesInstead() {
        #expect(Self.cue(reduceMotion: true).style == .fade)
        #expect(WordPop.style(reduceMotion: true) == .fade)
        #expect(WordPop.style(reduceMotion: false) == .pop)
    }

    /// The pop follows the speed playback runs at, a hold's speed drag
    /// included, and the word's own time.
    @Test func cueTakesItsWordsDuration() {
        for speed in [100, 300, 640, 1000] {
            #expect(Self.cue(wordsPerMinute: speed).duration == WordPop.duration(wordsPerMinute: speed))
        }
        let shortened = WordPop.readerCue(
            index: 3, isShown: true, isPlaying: true, reduceMotion: false,
            wordsPerMinute: 300, wordInterval: 0.08
        )
        #expect(abs(shortened.duration - 0.04) < 1e-9)
    }

    // MARK: - Engine

    /// The engine keeps each word's display time as playback reaches it,
    /// for the reader to fit the word's pop inside.
    @MainActor
    @Test func engineKeepsTheCurrentWordsTime() {
        let engine = RSVPEngine(
            words: ["A", "plain", "sentence,", "slowly."],
            wordsPerMinute: 1,
            smartTimingEnabled: true,
            sentencePauseEnabled: true
        )
        #expect(engine.currentWordInterval == nil)
        engine.play()
        defer { engine.pause() }
        for _ in 0..<3 {
            #expect(engine.currentWordInterval == engine.nextInterval(), "\(engine.currentWord)")
            engine.advance()
        }
        #expect(engine.currentWord == "slowly.")
        #expect(engine.currentWordInterval == engine.nextInterval())
    }

    // MARK: - Anchor

    @Test func popScalesAroundTheAnchorLettersCenter() {
        let x = WordPop.anchorX(beforeWidth: 30, anchorWidth: 10, afterWidth: 60, isRightToLeft: false)
        #expect(abs(x - 0.35) < 1e-9)
    }

    /// Right to left, the letters before the anchor sit on its right.
    @Test func rightToLeftWordsCountFromTheirRightEdge() {
        let x = WordPop.anchorX(beforeWidth: 30, anchorWidth: 10, afterWidth: 60, isRightToLeft: true)
        #expect(abs(x - 0.65) < 1e-9)
    }

    @Test func singleLettersAndEmptyWordsScaleAroundTheirMiddle() {
        #expect(WordPop.anchorX(beforeWidth: 0, anchorWidth: 24, afterWidth: 0, isRightToLeft: false) == 0.5)
        #expect(WordPop.anchorX(beforeWidth: 0, anchorWidth: 0, afterWidth: 0, isRightToLeft: false) == 0.5)
    }

    // MARK: - Rendering

    /// The word view as the reader shows it, with the neighbours beside it.
    /// Renders from its own defaults suite at the default Dynamic Type size,
    /// so no stored setting or device text size reaches the pixels.
    private struct Stage: View {
        let word: String
        let pop: WordPop.Cue?
        let defaults: UserDefaults

        var body: some View {
            WordView(word: word, fontSize: 40, context: .init(previous: "was", next: "slowly"), pop: pop)
                .frame(width: 393)
                .background(Color.black)
                .defaultAppStorage(defaults)
                .dynamicTypeSize(.large)
        }
    }

    @MainActor
    private static func render(_ stage: Stage) throws -> [UInt8] {
        let renderer = ImageRenderer(content: stage)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        return bytes
    }

    /// Renders `stage` after a few warm-up renders: early renders in a
    /// process can differ from later ones.
    @MainActor
    private static func settledRender(_ stage: Stage) throws -> [UInt8] {
        for _ in 0..<2 { _ = try render(stage) }
        return try render(stage)
    }

    /// Between pops the word, its anchor letter, and its neighbours are
    /// drawn just as without the setting, in either reading direction.
    @MainActor
    @Test func wordAtRestIsDrawnAsWithoutPops() throws {
        let suiteName = "WordPopTests.render"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let cue = WordPop.Cue(trigger: 7, style: .pop, duration: WordPop.duration(wordsPerMinute: 300))
        for word in ["reading", "كتاب"] {
            let plain = try Self.settledRender(Stage(word: word, pop: nil, defaults: defaults))
            let popping = try Self.settledRender(Stage(word: word, pop: cue, defaults: defaults))
            try #require(plain.count == popping.count, "\(word)")
            // Scanned only when they differ: tests build without
            // optimization, where a byte-by-byte scan is slow.
            guard plain != popping else { continue }
            // A channel moving by more than this is a change; rendering can
            // vary by a few levels from run to run.
            let changed = zip(plain, popping).filter { abs(Int($0) - Int($1)) > 32 }.count
            #expect(changed == 0, "\(word)")
        }
    }
}
