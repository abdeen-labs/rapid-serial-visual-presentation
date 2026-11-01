import Testing
import Foundation
import SwiftUI
import CoreGraphics
@testable import Strobe

struct ContextWordsTests {

    // MARK: - Neighbors

    @Test func middleWordHasBothNeighbors() {
        let neighbors = ContextWords.neighbors(of: 1, in: ["reading", "the", "information"])
        #expect(neighbors == ContextWords.Neighbors(previous: "reading", next: "information"))
    }

    @Test func documentEdgesHaveOneNeighbor() {
        let words = ["Call", "me", "Ishmael."]
        #expect(ContextWords.neighbors(of: 0, in: words) == ContextWords.Neighbors(previous: nil, next: "me"))
        #expect(ContextWords.neighbors(of: 2, in: words) == ContextWords.Neighbors(previous: "me", next: nil))
    }

    @Test func singleWordAndEmptyDocumentsHaveNoNeighbors() {
        let none = ContextWords.Neighbors(previous: nil, next: nil)
        #expect(ContextWords.neighbors(of: 0, in: ["Only"]) == none)
        #expect(ContextWords.neighbors(of: 0, in: []) == none)
    }

    @Test func indexOutsideTheDocumentHasNoNeighbors() {
        let none = ContextWords.Neighbors(previous: nil, next: nil)
        #expect(ContextWords.neighbors(of: -1, in: ["a", "b"]) == none)
        #expect(ContextWords.neighbors(of: 2, in: ["a", "b"]) == none)
    }

    @Test func eachSideCanShowAlone() {
        let words = ["reading", "the", "information"]
        #expect(ContextWords.neighbors(of: 1, in: words, sides: .both) == .init(previous: "reading", next: "information"))
        #expect(ContextWords.neighbors(of: 1, in: words, sides: .previous) == .init(previous: "reading", next: nil))
        #expect(ContextWords.neighbors(of: 1, in: words, sides: .next) == .init(previous: nil, next: "information"))
        // A side that's off stays off at the document's edge too.
        #expect(ContextWords.neighbors(of: 0, in: words, sides: .previous) == .init(previous: nil, next: nil))
        // A stored choice the app doesn't know shows both.
        #expect(ContextWords.Sides.resolve("sideways") == .both)
    }

    // MARK: - Opacity

    /// The default, while playing, is each tone's dim text, as before the
    /// setting; paused, they're readable in the tone's faded text.
    @Test func defaultOpacityIsDimWhilePlayingAndFadedWhilePaused() {
        let level = ReaderSettings.Defaults.contextWordsOpacity
        for tone in ReaderTextTone.allCases {
            #expect(ContextWords.opacity(isPlaying: true, level: level, tone: tone) == tone.dimTextOpacity, "\(tone.rawValue)")
            #expect(ContextWords.opacity(isPlaying: false, level: level, tone: tone) == tone.fadedTextOpacity, "\(tone.rawValue)")
        }
    }

    /// Raised past faded text, they show as brightly while paused as while
    /// playing: pausing never makes them harder to read.
    @Test func pausedOpacityIsNeverBelowPlaying() {
        for tone in ReaderTextTone.allCases {
            for level in stride(from: 0.0, through: 1.0, by: 0.05) {
                let playing = ContextWords.opacity(isPlaying: true, level: level, tone: tone)
                let paused = ContextWords.opacity(isPlaying: false, level: level, tone: tone)
                #expect(playing == tone.opacity(level: level), "\(tone.rawValue), \(level)")
                #expect(paused >= tone.fadedTextOpacity, "\(tone.rawValue), \(level)")
                #expect(paused >= playing, "\(tone.rawValue), \(level)")
            }
            #expect(ContextWords.opacity(isPlaying: false, level: 1, tone: tone) == 1, "\(tone.rawValue)")
        }
    }

    // MARK: - Rendering

    private static let scale: CGFloat = 2
    /// A phone's reading width.
    private static let width: CGFloat = 393

    /// The word view as the reader shows it. Renders from its own defaults
    /// suite at the default Dynamic Type size, so no stored setting or device
    /// text size reaches the pixels.
    private struct Stage: View {
        let word: String
        let fontSize: CGFloat
        let context: ContextWords.Neighbors?
        var isRightToLeft = false
        var isDimmed = false
        let defaults: UserDefaults

        var body: some View {
            WordView(word: word, fontSize: fontSize, context: context,
                     contextIsRightToLeft: isRightToLeft, contextIsPlaying: isDimmed)
                .frame(width: ContextWordsTests.width)
                .background(Color.black)
                .defaultAppStorage(defaults)
                .dynamicTypeSize(.large)
        }
    }

    /// RGBA pixels of a render, top row first.
    private struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func channels(_ x: Int, _ y: Int) -> (red: Int, green: Int, blue: Int) {
            let offset = (y * width + x) * 4
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
        }

        /// The brightest channel: 0 on the black background.
        func ink(_ x: Int, _ y: Int) -> Int {
            let pixel = channels(x, y)
            return max(pixel.red, pixel.green, pixel.blue)
        }
    }

    /// Text is brighter than this; the faint guide line is not.
    private static let inkThreshold = 48
    /// A pixel changed between two renders when a channel moved by more than
    /// this. Rendering can vary by a few levels from run to run.
    private static let changeThreshold = 32

    /// A suite of its own for each test: tests set the font or tone in it,
    /// and one that yields mid-run mustn't find another test's setting.
    private static func isolatedDefaults(_ test: String = #function) throws -> UserDefaults {
        let suiteName = "ContextWordsTests.render.\(test)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @MainActor
    private static func render(_ stage: Stage) throws -> Bitmap {
        let renderer = ImageRenderer(content: stage)
        renderer.scale = scale
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
        return Bitmap(width: width, height: height, bytes: bytes)
    }

    /// The columns the text of a render covers.
    private static func inkColumns(_ bitmap: Bitmap) -> ClosedRange<Int>? {
        let columns = (0..<bitmap.width).filter { x in
            (0..<bitmap.height).contains { y in bitmap.ink(x, y) > inkThreshold }
        }
        guard let first = columns.first, let last = columns.last else { return nil }
        return first...last
    }

    /// The pixels that changed between two renders of the same size.
    private static func changedPixels(_ a: Bitmap, _ b: Bitmap) -> [(x: Int, y: Int)] {
        var changed: [(x: Int, y: Int)] = []
        for y in 0..<a.height {
            for x in 0..<a.width {
                let before = a.channels(x, y), after = b.channels(x, y)
                if abs(before.red - after.red) > changeThreshold
                    || abs(before.green - after.green) > changeThreshold
                    || abs(before.blue - after.blue) > changeThreshold {
                    changed.append((x, y))
                }
            }
        }
        return changed
    }

    /// Renders `stage` after a few warm-up renders: early renders in a
    /// process can differ from later ones.
    @MainActor
    private static func settledRender(_ stage: Stage) throws -> Bitmap {
        for _ in 0..<2 { _ = try render(stage) }
        return try render(stage)
    }

    private static let samples: [(word: String, context: ContextWords.Neighbors, isRightToLeft: Bool, fits: Bool)] = [
        ("the", .init(previous: "reading", next: "information"), false, true),
        ("internationalization", .init(previous: "of", next: "efforts,"), false, false),
        ("كتاب", .init(previous: "هذا", next: "جميل"), true, true),
    ]

    /// Whatever the neighbours, every pixel of the word, its anchor letter
    /// included, stays where it is: context only draws in other columns.
    /// Yields between cases so the renders don't hold the main actor for the
    /// whole test.
    @MainActor
    @Test func wordPixelsDoNotChangeWhenContextShows() async throws {
        let defaults = try Self.isolatedDefaults()
        for font in ReaderFont.allCases {
            defaults.set(font.rawValue, forKey: ReaderFont.storageKey)
            for fontSize: CGFloat in [24, 40, 72] {
                for sample in Self.samples {
                    await Task.yield()
                    let label = "\(font.rawValue), \(fontSize)pt, \(sample.word)"
                    let alone = try Self.settledRender(Stage(
                        word: sample.word, fontSize: fontSize, context: nil,
                        isRightToLeft: sample.isRightToLeft, defaults: defaults
                    ))
                    let beside = try Self.settledRender(Stage(
                        word: sample.word, fontSize: fontSize, context: sample.context,
                        isRightToLeft: sample.isRightToLeft, defaults: defaults
                    ))
                    let word = try #require(Self.inkColumns(alone), "\(label)")
                    let changed = Self.changedPixels(alone, beside)
                    #expect(changed.allSatisfy { !word.contains($0.x) }, "\(label): context drew over the word")
                    if sample.fits && fontSize <= 40 {
                        #expect(!changed.isEmpty, "\(label): no context drawn")
                    }
                }
            }
        }
    }

    @MainActor
    @Test func previousWordSitsOnTheLeftAndNextOnTheRight() throws {
        let defaults = try Self.isolatedDefaults()
        func render(_ context: ContextWords.Neighbors?) throws -> Bitmap {
            try Self.settledRender(Stage(word: "the", fontSize: 40, context: context, defaults: defaults))
        }
        let alone = try render(nil)
        let word = try #require(Self.inkColumns(alone))
        let previous = Self.changedPixels(alone, try render(.init(previous: "read", next: nil)))
        let next = Self.changedPixels(alone, try render(.init(previous: nil, next: "book")))
        #expect(!previous.isEmpty)
        #expect(previous.allSatisfy { $0.x < word.lowerBound })
        #expect(!next.isEmpty)
        #expect(next.allSatisfy { $0.x > word.upperBound })
    }

    @MainActor
    @Test func rightToLeftDocumentsPutThePreviousWordOnTheRight() throws {
        let defaults = try Self.isolatedDefaults()
        func render(_ context: ContextWords.Neighbors?) throws -> Bitmap {
            try Self.settledRender(Stage(word: "كتاب", fontSize: 40, context: context, isRightToLeft: true, defaults: defaults))
        }
        let alone = try render(nil)
        let word = try #require(Self.inkColumns(alone))
        let previous = Self.changedPixels(alone, try render(.init(previous: "هذا", next: nil)))
        let next = Self.changedPixels(alone, try render(.init(previous: nil, next: "جميل")))
        #expect(!previous.isEmpty)
        #expect(previous.allSatisfy { $0.x > word.upperBound })
        #expect(!next.isEmpty)
        #expect(next.allSatisfy { $0.x < word.lowerBound })
    }

    /// In every tone the neighbours are fainter than the word, and none of
    /// their pixels takes the anchor letter's red.
    @MainActor
    @Test func contextIsDimmerThanTheWordAndHasNoAnchorLetter() throws {
        let defaults = try Self.isolatedDefaults()
        for tone in ReaderTextTone.allCases {
            defaults.set(tone.rawValue, forKey: ReaderTextTone.storageKey)
            let alone = try Self.settledRender(Stage(word: "reading", fontSize: 40, context: nil, defaults: defaults))
            let beside = try Self.settledRender(Stage(
                word: "reading", fontSize: 40, context: .init(previous: "was", next: "slowly"), defaults: defaults
            ))
            let word = try #require(Self.inkColumns(alone), "\(tone.rawValue)")
            var brightestWord = 0
            var brightestContext = 0
            var reddish = 0
            for y in 0..<beside.height {
                for x in 0..<beside.width {
                    let ink = beside.ink(x, y)
                    if word.contains(x) {
                        brightestWord = max(brightestWord, ink)
                    } else {
                        brightestContext = max(brightestContext, ink)
                        let pixel = beside.channels(x, y)
                        if pixel.red - max(pixel.green, pixel.blue) > 60 { reddish += 1 }
                    }
                }
            }
            #expect(brightestContext > Self.inkThreshold, "\(tone.rawValue): no context drawn")
            #expect(brightestContext < brightestWord, "\(tone.rawValue)")
            #expect(reddish == 0, "\(tone.rawValue)")
        }
    }

    /// Dimmed, as during playback, the neighbours in every tone are still
    /// drawn but stay under the text threshold, well below their paused
    /// brightness, and the word's pixels don't change.
    @MainActor
    @Test func dimmedContextIsBarelyVisibleAndLeavesTheWordAlone() throws {
        let defaults = try Self.isolatedDefaults()
        let context = ContextWords.Neighbors(previous: "was", next: "slowly")
        for tone in ReaderTextTone.allCases {
            defaults.set(tone.rawValue, forKey: ReaderTextTone.storageKey)
            let alone = try Self.settledRender(Stage(word: "reading", fontSize: 40, context: nil, defaults: defaults))
            let paused = try Self.settledRender(Stage(word: "reading", fontSize: 40, context: context, defaults: defaults))
            let dimmed = try Self.settledRender(Stage(
                word: "reading", fontSize: 40, context: context, isDimmed: true, defaults: defaults
            ))
            let word = try #require(Self.inkColumns(alone), "\(tone.rawValue)")
            var brightestPaused = 0
            var brightestDimmed = 0
            for y in 0..<dimmed.height {
                for x in 0..<dimmed.width where !word.contains(x) {
                    // The word's anti-aliased edge reaches into the columns
                    // beside it at up to `inkThreshold`.
                    let wordEdge = alone.ink(x, y)
                    brightestPaused = max(brightestPaused, paused.ink(x, y) - wordEdge)
                    brightestDimmed = max(brightestDimmed, dimmed.ink(x, y) - wordEdge)
                }
            }
            #expect(brightestDimmed > 16, "\(tone.rawValue): no context drawn")
            #expect(brightestDimmed < Self.inkThreshold, "\(tone.rawValue): \(brightestDimmed)")
            #expect(brightestDimmed * 2 < brightestPaused, "\(tone.rawValue): \(brightestDimmed) vs \(brightestPaused)")
            let changed = Self.changedPixels(paused, dimmed)
            #expect(changed.allSatisfy { !word.contains($0.x) }, "\(tone.rawValue): dimming changed the word")
        }
    }
}
