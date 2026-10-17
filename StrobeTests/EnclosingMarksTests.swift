import Testing
import Foundation
import SwiftUI
import CoreGraphics
@testable import Strobe

struct EnclosingMarksTests {

    /// The marks shown on each word of `words`.
    private func marks(_ words: [String], chapters: [Chapter] = []) -> [String] {
        let enclosing = EnclosingMarks(words: words, chapters: chapters)
        return words.indices.map { enclosing.stack(at: $0).marks }
    }

    /// The marks shown on each word of `text`, split as the tokenizer splits it.
    private func marks(_ text: String) -> [String] {
        marks(Tokenizer.tokenize(text))
    }

    private static func filler(_ count: Int) -> [String] {
        Array(repeating: "word", count: count)
    }

    // MARK: - Mark families

    @Test func parenthesesCoverTheirWordsFromOpeningToClosing() {
        #expect(marks("He said (as I recall) that it rained.") == ["", "", "(", "(", "(", "", "", ""])
    }

    @Test func squareBrackets() {
        #expect(marks("The note [added later by the editor] is here.")
                == ["", "", "[", "[", "[", "[", "[", "", ""])
    }

    @Test func curlyDoubleQuotes() {
        #expect(marks("She said “come here right now” and left.") == ["", "", "“", "“", "“", "“", "", ""])
    }

    @Test func curlySingleQuotes() {
        #expect(marks("She said ‘come here right now,’ and left.") == ["", "", "‘", "‘", "‘", "‘", "", ""])
    }

    @Test func straightDoubleQuotes() {
        #expect(marks("She said \"come here right now\" and left.") == ["", "", "\"", "\"", "\"", "\"", "", ""])
    }

    @Test func frenchGuillemets() {
        #expect(marks("Il a dit «viens ici tout de suite» et partit.")
                == ["", "", "", "«", "«", "«", "«", "«", "", ""])
    }

    /// French sets a space inside guillemets, and the tokenizer glues each
    /// spaced mark onto the word before it.
    @Test func spacedFrenchGuillemets() {
        let words = Tokenizer.tokenize("Il a dit « viens ici tout de suite » et partit.")
        #expect(words == ["Il", "a", "dit«", "viens", "ici", "tout", "de", "suite»", "et", "partit."])
        #expect(marks(words) == ["", "", "«", "«", "«", "«", "«", "«", "", ""])
    }

    @Test func reversedGuillemetsOpenGermanQuotations() {
        #expect(marks("Er sagte »komm sofort hierher« und ging.") == ["", "", "»", "»", "»", "", ""])
    }

    @Test func singleGuillemets() {
        #expect(marks("Il a dit ‹viens ici maintenant› et partit.") == ["", "", "", "‹", "‹", "‹", "", ""])
    }

    /// `“` closes a German quotation opened with `„`.
    @Test func germanLowOpeningQuote() {
        #expect(marks("Er sagte „komm sofort hierher“ und ging.") == ["", "", "„", "„", "„", "", ""])
    }

    @Test func polishLowOpeningQuote() {
        #expect(marks("Powiedział „chodź tu natychmiast” i wyszedł.") == ["", "„", "„", "„", "", ""])
    }

    @Test func swedishQuotesOpenAndCloseWithTheSameMark() {
        #expect(marks("Han sa ”kom hit genast” och gick.") == ["", "", "”", "”", "”", "", ""])
    }

    @Test func germanSingleQuotesInsideDoubleQuotes() {
        #expect(marks("Er sagte „sie rief ‚komm sofort her‘ und ging“ dann.")
                == ["", "", "„", "„", "„‚", "„‚", "„‚", "„", "„", ""])
    }

    /// The CJK tokenizer glues punctuation onto the word before it, opening
    /// brackets included.
    @Test func cjkBracketsOpenWhereverTheyAreGlued() {
        #expect(marks(["他说：「", "我们", "的", "系统。」", "然后"]) == ["「", "「", "「", "「", ""])
        #expect(marks(["她说：『", "我们", "的", "系统。』", "然后"]) == ["『", "『", "『", "『", ""])
        for (open, close) in [("（", "）"), ("《", "》"), ("〈", "〉"), ("【", "】"), ("〔", "〕"), ("［", "］")] {
            #expect(marks(["见" + open + "我们", "的", "系统" + close, "然后"]) == [open, open, open, ""], "\(open)\(close)")
        }
    }

    @Test func fullwidthAndHalfwidthParenthesesPair() {
        #expect(marks(["（as", "I", "recall)", "that"]) == ["（", "（", "（", ""])
    }

    // MARK: - Nesting

    @Test func nestedSpansShowOutermostFirst() {
        #expect(marks("“It tells you: ‘Stop lying to yourself,’ he said.”")
                == ["“", "“", "“", "“‘", "“‘", "“‘", "“‘", "“", "“"])
        #expect(marks("He said (“one in, one out”) and left.") == ["", "", "(“", "(“", "(“", "(“", "", ""])
    }

    @Test func showsTheThreeOutermostLevels() {
        #expect(marks("“a (b [c ‘d e f’ g] h) i”")
                == ["“", "“(", "“([", "“([", "“([", "“([", "“([", "“(", "“"])
    }

    @Test func spansThatCloseAndOpenOnOneWordBothCoverIt() {
        #expect(marks(["(a", "b", "c)(d", "e", "f)"]) == ["(", "(", "((", "(", "("])
    }

    // MARK: - Unmatched and runaway marks

    @Test func unmatchedOpeningMarkNeverShows() {
        #expect(marks("He said (as I recall that it rained all day.").allSatisfy { $0.isEmpty })
        #expect(marks("She said “come here right now and left.").allSatisfy { $0.isEmpty })
    }

    @Test func strayClosingMarksAreIgnored() {
        #expect(marks("Items a) b) and c) are listed here.").allSatisfy { $0.isEmpty })
        #expect(marks("Done.” He left the room.”").allSatisfy { $0.isEmpty })
    }

    /// A span still open when an outer one closes never closed itself.
    @Test func closingAnOuterSpanDropsAnUnclosedInnerOne() {
        #expect(marks("“He said (as I recall that it rained,” she said.")
                == ["“", "“", "“", "“", "“", "“", "“", "“", "", ""])
    }

    @Test func oneAndTwoWordSpansShowNothing() {
        #expect(marks("He wrote (sic) here.").allSatisfy { $0.isEmpty })
        #expect(marks("He said (for example) that.").allSatisfy { $0.isEmpty })
        #expect(marks("She said “Good morning,” and left.").allSatisfy { $0.isEmpty })
        #expect(marks("He said (for another example) that.") == ["", "", "(", "(", "(", ""])
    }

    @Test func spanClosedWithoutPunctuationIsCappedShorter() {
        let limit = EnclosingMarks.maximumUnpunctuatedSpanLength
        let atLimit = ["(start"] + Self.filler(limit - 2) + ["end)"]
        let pastLimit = ["(start"] + Self.filler(limit - 1) + ["end)"]
        #expect(marks(atLimit).allSatisfy { $0 == "(" })
        #expect(marks(pastLimit).allSatisfy { $0.isEmpty })
    }

    @Test func spanClosedAfterPunctuationMayRunLonger() {
        let limit = EnclosingMarks.maximumSpanLength
        let punctuated = ["“start"] + Self.filler(limit - 2) + ["end.”"]
        let tooLong = ["“start"] + Self.filler(limit - 1) + ["end.”"]
        let clause = ["“start"] + Self.filler(100) + ["end,”", "she", "said."]
        #expect(marks(punctuated).allSatisfy { $0 == "“" })
        #expect(marks(tooLong).allSatisfy { $0.isEmpty })
        #expect(marks(clause).prefix(102).allSatisfy { $0 == "“" })
    }

    // MARK: - Apostrophes

    @Test func apostrophesOpenAndCloseNothing() {
        #expect(marks("The dogs’ owners don’t know what ’90s rock ’n’ roll was like.").allSatisfy { $0.isEmpty })
        #expect(marks("The dogs' owners don't know what '90s rock 'n' roll was like.").allSatisfy { $0.isEmpty })
    }

    @Test func misprintedLeadingApostrophesOpenNothing() {
        #expect(marks("In the ‘90s we played ‘em all ‘til dawn, the girls’ band.").allSatisfy { $0.isEmpty })
    }

    @Test func straightSingleQuotesAreIgnored() {
        #expect(marks("She said 'come here right now' and left.").allSatisfy { $0.isEmpty })
    }

    @Test func possessiveOutsideASingleQuotationClosesNothing() {
        #expect(marks("“The girls’ band played all night,” he said.")
                == ["“", "“", "“", "“", "“", "“", "", ""])
    }

    // MARK: - Repeated opening marks

    /// Each paragraph of a long quotation opens it again, and only the last
    /// one closes it; paragraph breaks aren't kept.
    @Test func quotationReopenedAfterASentenceContinues() {
        #expect(marks("“First paragraph ends here. “Second paragraph ends here.”")
                == Array(repeating: "“", count: 8))
    }

    @Test func quotationReopenedMidSentenceDropsTheUnclosedOne() {
        #expect(marks("“First one never closed and “Second one is here.”")
                == ["", "", "", "", "", "“", "“", "“", "“"])
    }

    @Test func bracketsNestInThemselves() {
        #expect(marks("He said (as (it was noted) before) then.")
                == ["", "", "(", "((", "((", "((", "(", ""])
    }

    // MARK: - Chapters

    @Test func nothingStaysOpenAcrossAChapterStart() {
        let words = ["“It", "was", "a", "dark", "night", "and", "cold.”", "(a", "long", "aside)"]
        let chapters = [Chapter(title: "One", wordIndex: 0), Chapter(title: "Two", wordIndex: 5)]
        #expect(marks(words, chapters: chapters) == ["", "", "", "", "", "", "", "(", "(", "("])
        #expect(marks(words) == ["“", "“", "“", "“", "“", "“", "“", "(", "(", "("])
    }

    @Test func untitledChapterEntriesAreNotChapterStarts() {
        let words = ["“It", "was", "a", "dark", "night.”"]
        #expect(marks(words, chapters: [Chapter(title: " ", wordIndex: 2)]) == Array(repeating: "“", count: 5))
    }

    // MARK: - Direction

    @Test func rightToLeftSpansAreMarked() {
        let quoted = EnclosingMarks(words: ["قال", "«هذا", "هو", "الكتاب»", "ثم"], chapters: [])
        #expect(quoted.stack(at: 2) == EnclosingMarks.Stack(marks: "«", isRightToLeft: true))
        let aside = EnclosingMarks(words: ["قال", "(1990", "كان", "عاما)", "ثم"], chapters: [])
        #expect(aside.stack(at: 2) == EnclosingMarks.Stack(marks: "(", isRightToLeft: true))
        let english = EnclosingMarks(words: Tokenizer.tokenize("He said (as I recall) that."), chapters: [])
        #expect(english.stack(at: 3) == EnclosingMarks.Stack(marks: "(", isRightToLeft: false))
    }

    // MARK: - Lookup

    /// Every lookup stands alone, so a seek, scrub, chapter jump, or restart
    /// reads the right marks at once.
    @Test func lookupsInAnyOrderMatchReadingOrder() {
        let words = Tokenizer.tokenize("""
            He said (as I recall) that “the storm [the big one] ended,” and \
            then “we left (quietly, and in a hurry) for the coast.” The end.
            """)
        let enclosing = EnclosingMarks(words: words, chapters: [])
        let inOrder = words.indices.map { enclosing.stack(at: $0) }
        var generator = SeededGenerator(seed: 7)
        for index in words.indices.shuffled(using: &generator) {
            #expect(enclosing.stack(at: index) == inOrder[index], "index \(index)")
        }
        #expect(inOrder.contains { !$0.isEmpty })
    }

    @Test func indicesOutsideTheDocumentHaveNoMarks() {
        let enclosing = EnclosingMarks(words: ["(as", "I", "recall)"], chapters: [])
        #expect(enclosing.stack(at: -1) == .empty)
        #expect(enclosing.stack(at: 3) == .empty)
        #expect(EnclosingMarks(words: [], chapters: []).stack(at: 0) == .empty)
    }

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    // MARK: - Sizing

    private static let textSizes = Array(stride(from: CGFloat(24), through: 72, by: 2))

    /// Whatever the room, the marks' slot starts past the end of the word's
    /// guide line and ends before the bar margin.
    @Test func slotStaysAboveTheWordAndClearOfTheBars() {
        for size in Self.textSizes {
            for room in stride(from: CGFloat(0), through: 400, by: 2.5) {
                guard let metrics = EnclosingMarksLayout.metrics(wordFontSize: size, clearHalfHeight: room) else { continue }
                let bottom = metrics.offset - metrics.slotHeight / 2
                #expect(bottom > size * WordView.guideLineHeightRatio / 2, "size \(size), room \(room)")
                #expect(metrics.reach <= room - EnclosingMarksLayout.barMargin + 0.001, "size \(size), room \(room)")
                #expect(metrics.fontSize >= EnclosingMarksLayout.minimumFontSize)
                #expect(metrics.fontSize <= EnclosingMarksLayout.preferredFontSize(wordFontSize: size))
            }
        }
    }

    @Test func tightRoomShrinksTheMarksThenHidesThem() throws {
        let size: CGFloat = 40
        let full = try #require(EnclosingMarksLayout.metrics(wordFontSize: size, clearHalfHeight: 1_000))
        #expect(abs(full.fontSize - size * EnclosingMarksLayout.fontSizeRatio) < 0.001)
        let fullRoom = full.reach + EnclosingMarksLayout.barMargin
        let minimumRoom = EnclosingMarksLayout.innerEdge(wordFontSize: size)
            + EnclosingMarksLayout.minimumFontSize * EnclosingMarksLayout.slotHeightRatio
            + EnclosingMarksLayout.barMargin
        let shrunk = try #require(EnclosingMarksLayout.metrics(
            wordFontSize: size, clearHalfHeight: (fullRoom + minimumRoom) / 2
        ))
        #expect(shrunk.fontSize < full.fontSize)
        #expect(EnclosingMarksLayout.metrics(wordFontSize: size, clearHalfHeight: minimumRoom + 0.5) != nil)
        #expect(EnclosingMarksLayout.metrics(wordFontSize: size, clearHalfHeight: minimumRoom - 0.5) == nil)
    }

    // MARK: - Size setting

    /// Across the size setting's range, ends included.
    private static let sizeScales = Array(stride(
        from: CGFloat(EnclosingMarksLayout.sizeRange.lowerBound),
        through: CGFloat(EnclosingMarksLayout.sizeRange.upperBound),
        by: 0.25
    ))

    /// The default draws the marks at the size they had before the setting.
    @Test func defaultSizeIsTheStandardSize() throws {
        for size in Self.textSizes {
            let standard = max(EnclosingMarksLayout.preferredMinimumFontSize, size * EnclosingMarksLayout.fontSizeRatio)
            let scale = CGFloat(ReaderSettings.Defaults.enclosingMarksSize)
            #expect(EnclosingMarksLayout.preferredFontSize(wordFontSize: size, scale: scale) == standard, "size \(size)")
            let metrics = try #require(EnclosingMarksLayout.metrics(wordFontSize: size, clearHalfHeight: 1_000, scale: scale))
            #expect(metrics.fontSize == standard, "size \(size)")
        }
    }

    /// At every size the slot starts past the end of the word's guide line
    /// and ends before the bar margin, however little room there is.
    @Test func everySizeStaysAboveTheWordAndClearOfTheBars() {
        for scale in Self.sizeScales {
            for size in Self.textSizes {
                for room in stride(from: CGFloat(0), through: 400, by: 5) {
                    guard let metrics = EnclosingMarksLayout.metrics(
                        wordFontSize: size, clearHalfHeight: room, scale: scale
                    ) else { continue }
                    let label = "scale \(scale), size \(size), room \(room)"
                    let bottom = metrics.offset - metrics.slotHeight / 2
                    #expect(bottom > size * WordView.guideLineHeightRatio / 2, "\(label)")
                    #expect(metrics.reach <= room - EnclosingMarksLayout.barMargin + 0.001, "\(label)")
                    #expect(metrics.fontSize >= EnclosingMarksLayout.minimumFontSize, "\(label)")
                    #expect(metrics.fontSize <= EnclosingMarksLayout.preferredFontSize(wordFontSize: size, scale: scale) + 0.001,
                            "\(label)")
                }
            }
        }
    }

    /// The setting changes how big the marks are, never whether they show:
    /// the smallest stops at the size they hide below, and the largest
    /// shrinks to the room.
    @Test func sizeNeverDecidesWhetherTheMarksShow() {
        for scale in Self.sizeScales {
            for size in Self.textSizes {
                for room in stride(from: CGFloat(0), through: 400, by: 2.5) {
                    let scaled = EnclosingMarksLayout.metrics(wordFontSize: size, clearHalfHeight: room, scale: scale)
                    let standard = EnclosingMarksLayout.metrics(wordFontSize: size, clearHalfHeight: room)
                    #expect((scaled != nil) == (standard != nil), "scale \(scale), size \(size), room \(room)")
                }
            }
        }
    }

    @Test func largerSizesGrowUntilTheRoomCapsThem() throws {
        let size: CGFloat = 40
        let lowest = CGFloat(EnclosingMarksLayout.sizeRange.lowerBound)
        let highest = CGFloat(EnclosingMarksLayout.sizeRange.upperBound)
        let standard = try #require(EnclosingMarksLayout.metrics(wordFontSize: size, clearHalfHeight: 1_000))
        let smallest = try #require(EnclosingMarksLayout.metrics(wordFontSize: size, clearHalfHeight: 1_000, scale: lowest))
        let largest = try #require(EnclosingMarksLayout.metrics(wordFontSize: size, clearHalfHeight: 1_000, scale: highest))
        #expect(abs(smallest.fontSize - standard.fontSize * lowest) < 0.001)
        #expect(abs(largest.fontSize - standard.fontSize * highest) < 0.001)

        // Room for the standard size but not the largest: the largest fills it.
        let room = standard.reach + EnclosingMarksLayout.barMargin + 10
        let capped = try #require(EnclosingMarksLayout.metrics(wordFontSize: size, clearHalfHeight: room, scale: highest))
        #expect(capped.fontSize > standard.fontSize)
        #expect(capped.fontSize < largest.fontSize)
        #expect(abs(capped.reach - (room - EnclosingMarksLayout.barMargin)) < 0.001)
        // The slot grows upward only.
        #expect(abs((capped.offset - capped.slotHeight / 2) - (standard.offset - standard.slotHeight / 2)) < 0.001)
    }

    /// At the smallest text size the standard size is already near the
    /// floor, so the smallest setting stops there rather than hiding them.
    @Test func smallestSizeStopsAtTheMinimum() throws {
        let metrics = try #require(EnclosingMarksLayout.metrics(
            wordFontSize: 24, clearHalfHeight: 1_000, scale: CGFloat(EnclosingMarksLayout.sizeRange.lowerBound)
        ))
        #expect(metrics.fontSize == EnclosingMarksLayout.minimumFontSize)
    }

    // MARK: - Opacity setting

    /// The default draws the marks in each tone's faded text, as before the
    /// setting.
    @Test func defaultOpacityIsEachTonesFadedText() {
        for tone in ReaderTextTone.allCases {
            let opacity = EnclosingMarksLayout.opacity(level: ReaderSettings.Defaults.enclosingMarksOpacity, tone: tone)
            #expect(opacity == tone.fadedTextOpacity, "\(tone.rawValue)")
        }
    }

    /// From the tone's dim text, faint but visible, up to its full text
    /// color, brightening at every step.
    @Test func opacityRunsFromDimTextToTheFullTextColor() {
        for tone in ReaderTextTone.allCases {
            #expect(EnclosingMarksLayout.opacity(level: 0, tone: tone) == tone.dimTextOpacity, "\(tone.rawValue)")
            #expect(EnclosingMarksLayout.opacity(level: 1, tone: tone) == 1, "\(tone.rawValue)")
            #expect(EnclosingMarksLayout.opacity(level: -1, tone: tone) == tone.dimTextOpacity, "\(tone.rawValue)")
            #expect(EnclosingMarksLayout.opacity(level: 2, tone: tone) == 1, "\(tone.rawValue)")

            let opacities = stride(from: 0.0, through: 1.0, by: 0.05).map {
                EnclosingMarksLayout.opacity(level: $0, tone: tone)
            }
            #expect(zip(opacities, opacities.dropFirst()).allSatisfy { $0 < $1 }, "\(tone.rawValue)")
        }
    }

    // Measured reader chrome, as in ReaderLayoutTests.
    private static let topBar: CGFloat = 140
    private static let bottomBarWithChapters: CGFloat = 166

    private static func wordSlotHeight(fontSize: CGFloat) -> CGFloat {
        max(120, fontSize * 2.3)
    }

    private static func room(boundsHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat, fontSize: CGFloat) -> CGFloat {
        let center = ReaderStageLayout.fixationCenterY(
            boundsHeight: boundsHeight, topInset: topInset, bottomInset: bottomInset,
            contentHeight: wordSlotHeight(fontSize: fontSize),
            topBarHeight: topBar, bottomBarHeight: bottomBarWithChapters
        )
        return ReaderStageLayout.clearHalfHeight(
            centerY: center, boundsHeight: boundsHeight,
            topBarHeight: topBar, bottomBarHeight: bottomBarWithChapters
        )
    }

    @Test func marksShowFullSizeOnADynamicIslandPhone() throws {
        for size in Self.textSizes {
            let room = Self.room(boundsHeight: 759, topInset: 59, bottomInset: 34, fontSize: size)
            let metrics = try #require(EnclosingMarksLayout.metrics(wordFontSize: size, clearHalfHeight: room))
            #expect(abs(metrics.fontSize - EnclosingMarksLayout.preferredFontSize(wordFontSize: size)) < 0.001, "size \(size)")
        }
    }

    /// Down to a zoomed iPhone SE, which shrinks them at the largest sizes.
    @Test func marksShowOnPortraitPhonesAtEveryTextSize() {
        for (boundsHeight, topInset, bottomInset): (CGFloat, CGFloat, CGFloat) in [(759, 59, 34), (667, 0, 0), (568, 0, 0)] {
            for size in Self.textSizes {
                let room = Self.room(boundsHeight: boundsHeight, topInset: topInset, bottomInset: bottomInset, fontSize: size)
                #expect(EnclosingMarksLayout.metrics(wordFontSize: size, clearHalfHeight: room) != nil,
                        "phone \(boundsHeight), size \(size)")
            }
        }
    }

    // MARK: - Rendering

    private enum Variant {
        case absent, disabled, invisible, visible
    }

    /// One reader screen: its full size and safe-area insets.
    private struct Screen {
        let width: CGFloat
        let height: CGFloat
        let topInset: CGFloat
        let bottomInset: CGFloat

        var stageHeight: CGFloat { height - topInset - bottomInset }

        static let phone = Screen(width: 393, height: 852, topInset: 59, bottomInset: 34)
        static let smallWindow = Screen(width: 700, height: 500, topInset: 32, bottomInset: 0)
    }

    private static let scale: CGFloat = 2

    /// The reader stage as ReaderView arranges it, with plain bars. Renders
    /// from its own defaults suite at the default Dynamic Type size, so no
    /// stored setting or device text size reaches the pixels.
    private struct Stage: View {
        let screen: Screen
        let engine: RSVPEngine
        let marks: EnclosingMarks
        let fontSize: CGFloat
        let variant: Variant
        let defaults: UserDefaults

        var body: some View {
            ReaderStageLayout(topInset: screen.topInset, bottomInset: screen.bottomInset) {
                Color.gray
                    .frame(height: EnclosingMarksTests.topBar)
                    .readerStageRole(.topBar)

                WordView(word: engine.currentWord, fontSize: fontSize)

                switch variant {
                case .absent:
                    EmptyView()
                case .disabled:
                    marksView(isEnabled: false)
                        .readerStageRole(.fixationSurround)
                case .invisible:
                    marksView(isEnabled: true)
                        .opacity(0)
                        .readerStageRole(.fixationSurround)
                case .visible:
                    marksView(isEnabled: true)
                        .readerStageRole(.fixationSurround)
                }

                Color.gray
                    .frame(height: EnclosingMarksTests.bottomBarWithChapters)
                    .readerStageRole(.bottomBar)
            }
            .padding(.top, screen.topInset)
            .padding(.bottom, screen.bottomInset)
            .frame(width: screen.width, height: screen.height)
            .background(Color.black)
            .defaultAppStorage(defaults)
            .dynamicTypeSize(.large)
        }

        private func marksView(isEnabled: Bool) -> EnclosingMarksView {
            EnclosingMarksView(
                engine: engine,
                marks: marks,
                fontSize: fontSize,
                isEnabled: isEnabled
            )
        }
    }

    /// RGBA rows of a rendered stage, top row first.
    private struct Bitmap: Equatable {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    /// A cleared defaults suite. A test that stores settings in it takes a
    /// `name` of its own, so tests running alongside never render them.
    private static func isolatedDefaults(_ name: String = "render") throws -> UserDefaults {
        let suiteName = "EnclosingMarksTests.\(name)"
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

    /// The pixel rows of the marks' slot at the size setting `sizeScale`, or
    /// nil when there is no room for one, measured from the top of the screen.
    private static func slotRows(_ screen: Screen, fontSize: CGFloat, sizeScale: CGFloat = 1) -> ClosedRange<Int>? {
        let center = ReaderStageLayout.fixationCenterY(
            boundsHeight: screen.stageHeight, topInset: screen.topInset, bottomInset: screen.bottomInset,
            contentHeight: wordSlotHeight(fontSize: fontSize),
            topBarHeight: topBar, bottomBarHeight: bottomBarWithChapters
        )
        let room = ReaderStageLayout.clearHalfHeight(
            centerY: center, boundsHeight: screen.stageHeight,
            topBarHeight: topBar, bottomBarHeight: bottomBarWithChapters
        )
        guard let metrics = EnclosingMarksLayout.metrics(wordFontSize: fontSize, clearHalfHeight: room, scale: sizeScale) else {
            return nil
        }
        let middle = screen.topInset + center - metrics.offset
        let top = Int(((middle - metrics.slotHeight / 2) * scale).rounded(.down))
        let bottom = Int(((middle + metrics.slotHeight / 2) * scale).rounded(.up)) - 1
        return top...bottom
    }

    /// A channel moving by more than this between two renders is a change;
    /// rendering can vary by a few levels from run to run.
    private static let changeThreshold: UInt8 = 32

    /// How many pixels changed in each row that changed, between two renders
    /// of the same screen. Tests build without optimization, where scanning
    /// every byte of a screen takes over a second, so rows whose bytes are
    /// all equal are skipped with `memcmp`.
    private static func changedPixelsByRow(_ a: Bitmap, _ b: Bitmap) -> [Int: Int] {
        precondition(a.bytes.count == b.bytes.count)
        let rowBytes = a.width * 4
        var counts: [Int: Int] = [:]
        a.bytes.withUnsafeBufferPointer { before in
            b.bytes.withUnsafeBufferPointer { after in
                for y in 0..<a.height {
                    let start = y * rowBytes
                    guard memcmp(before.baseAddress! + start, after.baseAddress! + start, rowBytes) != 0 else {
                        continue
                    }
                    var changed = 0
                    for pixel in stride(from: start, to: start + rowBytes, by: 4) {
                        for channel in pixel..<(pixel + 4) {
                            let old = before[channel], new = after[channel]
                            if max(old, new) - min(old, new) > changeThreshold {
                                changed += 1
                                break
                            }
                        }
                    }
                    if changed > 0 { counts[y] = changed }
                }
            }
        }
        return counts
    }

    /// Whether two renders of the same screen show the same picture. A
    /// handful of stray pixels is rendering noise; anything that moves or
    /// draws changes far more.
    private static func matches(_ a: Bitmap, _ b: Bitmap) -> Bool {
        changedPixelsByRow(a, b).values.reduce(0, +) <= 8
    }

    /// Words shown inside a span: a short one, a long one, a nested pair.
    private static let cases: [(text: String, word: String)] = [
        ("He said (as I recall) that it rained.", "I"),
        ("(Efforts of internationalization and more) followed.", "internationalization"),
        ("“It tells you: ‘Stop lying to yourself,’ he said.”", "lying"),
    ]

    @MainActor
    private static func engine(_ sample: (text: String, word: String)) throws -> (RSVPEngine, EnclosingMarks) {
        let words = Tokenizer.tokenize(sample.text)
        let index = try #require(words.firstIndex(of: sample.word))
        let marks = EnclosingMarks(words: words, chapters: [])
        #expect(!marks.stack(at: index).isEmpty, "\(sample.word)")
        return (RSVPEngine(words: words, currentIndex: index), marks)
    }

    /// Yields between cases: rendering them all holds the main actor long
    /// enough to stall other tests, the engine's timer tests among them.
    @MainActor
    @Test func wordPixelsMatchWithMarksAbsentDisabledOrInvisible() async throws {
        let defaults = try Self.isolatedDefaults()
        for screen in [Screen.phone, .smallWindow] {
            for fontSize: CGFloat in [24, 40, 72] {
                for sample in Self.cases {
                    await Task.yield()
                    let (engine, marks) = try Self.engine(sample)
                    func stage(_ variant: Variant) -> Stage {
                        Stage(screen: screen, engine: engine, marks: marks, fontSize: fontSize,
                              variant: variant, defaults: defaults)
                    }
                    // Early renders in a process can differ from later ones.
                    for _ in 0..<3 { _ = try Self.render(stage(.absent)) }
                    let absent = try Self.render(stage(.absent))
                    let label = "\(screen.width)pt, \(fontSize)pt, \(sample.word)"
                    #expect(Self.matches(try Self.render(stage(.disabled)), absent), "\(label)")
                    #expect(Self.matches(try Self.render(stage(.invisible)), absent), "\(label)")
                }
            }
        }
    }

    @MainActor
    @Test func visibleMarksOnlyChangePixelsInsideTheirSlot() async throws {
        let defaults = try Self.isolatedDefaults()
        try await Self.expectMarksOnlyChangePixelsInsideTheirSlot(defaults: defaults, sizeScale: 1)
    }

    /// The largest marks, at full opacity, keep to their slot too: it grows
    /// into the room above the word and no further.
    @MainActor
    @Test func largestMarksOnlyChangePixelsInsideTheirSlot() async throws {
        let largest = EnclosingMarksLayout.sizeRange.upperBound
        let defaults = try Self.isolatedDefaults("largest")
        defaults.set(largest, forKey: ReaderSettings.Keys.enclosingMarksSize)
        defaults.set(1.0, forKey: ReaderSettings.Keys.enclosingMarksOpacity)
        try await Self.expectMarksOnlyChangePixelsInsideTheirSlot(defaults: defaults, sizeScale: CGFloat(largest))
    }

    /// Renders each case with and without the marks, from `defaults`, whose
    /// size setting is `sizeScale`. Yields between cases, like
    /// `wordPixelsMatchWithMarksAbsentDisabledOrInvisible`.
    @MainActor
    private static func expectMarksOnlyChangePixelsInsideTheirSlot(defaults: UserDefaults, sizeScale: CGFloat) async throws {
        for screen in [Screen.phone, .smallWindow] {
            for fontSize: CGFloat in [24, 40, 72] {
                for sample in Self.cases {
                    await Task.yield()
                    let (engine, marks) = try Self.engine(sample)
                    func stage(_ variant: Variant) -> Stage {
                        Stage(screen: screen, engine: engine, marks: marks, fontSize: fontSize,
                              variant: variant, defaults: defaults)
                    }
                    for _ in 0..<3 { _ = try Self.render(stage(.absent)) }
                    let absent = try Self.render(stage(.absent))
                    let visible = try Self.render(stage(.visible))
                    let changed = Self.changedPixelsByRow(absent, visible)
                    let label = "\(screen.width)pt, \(fontSize)pt, \(sample.word), \(sizeScale)x"
                    guard let slot = Self.slotRows(screen, fontSize: fontSize, sizeScale: sizeScale) else {
                        #expect(Self.matches(absent, visible), "\(label): marks drew without room")
                        continue
                    }
                    #expect(!changed.isEmpty, "\(label): no marks drawn")
                    let outside = changed.filter { !slot.contains($0.key) }.values.reduce(0, +)
                    #expect(outside <= 8, "\(label): drew outside the slot")
                }
            }
        }
    }

    @MainActor
    @Test func wordOutsideAnySpanDrawsNoMarks() throws {
        let defaults = try Self.isolatedDefaults()
        let words = Tokenizer.tokenize("He said (as I recall) that it rained.")
        let engine = RSVPEngine(words: words, currentIndex: 6)
        let marks = EnclosingMarks(words: words, chapters: [])
        #expect(marks.stack(at: 6).isEmpty)
        func stage(_ variant: Variant) -> Stage {
            Stage(screen: .phone, engine: engine, marks: marks, fontSize: 40,
                  variant: variant, defaults: defaults)
        }
        for _ in 0..<3 { _ = try Self.render(stage(.absent)) }
        #expect(Self.matches(try Self.render(stage(.visible)), try Self.render(stage(.absent))))
    }

    @MainActor
    @Test func marksHideDuringAChapterAnnouncement() throws {
        let defaults = try Self.isolatedDefaults()
        let words = ["(as", "I", "recall)", "that"]
        let chapters = [Chapter(title: "Chapter Two", wordIndex: 0)]
        let engine = RSVPEngine(words: words, currentIndex: 0, chapters: chapters)
        let marks = EnclosingMarks(words: words, chapters: chapters)
        #expect(marks.stack(at: 0).marks == "(")
        engine.play()
        defer { engine.pause() }
        #expect(engine.chapterAnnouncement != nil)
        func stage(_ variant: Variant) -> Stage {
            Stage(screen: .phone, engine: engine, marks: marks, fontSize: 40,
                  variant: variant, defaults: defaults)
        }
        for _ in 0..<3 { _ = try Self.render(stage(.absent)) }
        #expect(Self.matches(try Self.render(stage(.visible)), try Self.render(stage(.absent))))
    }

    /// At 1 WPM the real timer never fires during the test; `advance()`
    /// stands in for the sentence's last deadline.
    @MainActor
    @Test func marksHideDuringASentenceBreak() throws {
        let defaults = try Self.isolatedDefaults()
        let words = ["(It", "ended.", "Then", "more)", "after"]
        let engine = RSVPEngine(words: words, currentIndex: 1, wordsPerMinute: 1, sentenceBreakEnabled: true)
        let marks = EnclosingMarks(words: words, chapters: [])
        #expect(marks.stack(at: 1).marks == "(")
        engine.play()
        defer { engine.pause() }
        engine.advance()
        #expect(engine.isInSentenceBreak)
        func stage(_ variant: Variant) -> Stage {
            Stage(screen: .phone, engine: engine, marks: marks, fontSize: 40,
                  variant: variant, defaults: defaults)
        }
        for _ in 0..<3 { _ = try Self.render(stage(.absent)) }
        #expect(Self.matches(try Self.render(stage(.visible)), try Self.render(stage(.absent))))
    }
}
