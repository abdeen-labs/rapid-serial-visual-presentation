import Testing
import CoreGraphics
@testable import Strobe

struct ReaderLayoutTests {

    // Measured reader chrome at default Dynamic Type: the top bar (header +
    // WPM card), and the bottom bar without and with chapter navigation.
    private static let topBar: CGFloat = 140
    private static let bottomBar: CGFloat = 106
    private static let bottomBarWithChapters: CGFloat = 166

    /// Safe-area height and insets for one screen or window.
    private struct Container {
        let boundsHeight: CGFloat
        let topInset: CGFloat
        let bottomInset: CGFloat

        var fullHeight: CGFloat { topInset + boundsHeight + bottomInset }

        static let dynamicIslandPhone = Container(boundsHeight: 759, topInset: 59, bottomInset: 34)
        static let homeButtonPhone = Container(boundsHeight: 667, topInset: 0, bottomInset: 0)
        static let zoomedHomeButtonPhone = Container(boundsHeight: 568, topInset: 0, bottomInset: 0)
        static let largePad = Container(boundsHeight: 1346, topInset: 0, bottomInset: 20)
        static let minimumMacWindow = Container(boundsHeight: 468, topInset: 32, bottomInset: 0)
        static let landscapePhone = Container(boundsHeight: 372, topInset: 0, bottomInset: 21)

        static let all = [dynamicIslandPhone, homeButtonPhone, zoomedHomeButtonPhone,
                          largePad, minimumMacWindow, landscapePhone]
    }

    private static func wordSlotHeight(fontSize: CGFloat) -> CGFloat {
        max(120, fontSize * 2.3)
    }

    /// The content's center measured from the top of the full container.
    private static func centerInContainer(
        _ container: Container,
        contentHeight: CGFloat,
        topBar: CGFloat = topBar,
        bottomBar: CGFloat
    ) -> CGFloat {
        container.topInset + ReaderStageLayout.fixationCenterY(
            boundsHeight: container.boundsHeight,
            topInset: container.topInset,
            bottomInset: container.bottomInset,
            contentHeight: contentHeight,
            topBarHeight: topBar,
            bottomBarHeight: bottomBar
        )
    }

    @Test func fixationLineSitsSlightlyAboveGeometricCenter() {
        let fraction = ReaderStageLayout.fixationFraction
        #expect(fraction < 0.5)
        #expect(fraction >= 0.45)
    }

    @Test func wordRestsOnTheFixationLineOfTheFullContainer() {
        let slot = Self.wordSlotHeight(fontSize: 40)
        for container in [Container.dynamicIslandPhone, .homeButtonPhone, .largePad] {
            let center = Self.centerInContainer(container, contentHeight: slot, bottomBar: Self.bottomBar)
            let expected = container.fullHeight * ReaderStageLayout.fixationFraction
            #expect(abs(center - expected) < 0.001)
        }
    }

    /// Documents with and without chapter navigation have different bottom
    /// bar heights but must share one fixation line.
    @Test func wordPositionIgnoresChapterNavigation() {
        let slot = Self.wordSlotHeight(fontSize: 40)
        for container in [Container.dynamicIslandPhone, .homeButtonPhone, .largePad] {
            let plain = Self.centerInContainer(container, contentHeight: slot, bottomBar: Self.bottomBar)
            let chaptered = Self.centerInContainer(container, contentHeight: slot, bottomBar: Self.bottomBarWithChapters)
            #expect(plain == chaptered)
        }
    }

    /// Only the full height matters — how it splits into safe area and
    /// insets (notch, home indicator, title bar) must not move the line.
    @Test func wordPositionIgnoresHowInsetsSplitTheContainer() {
        let slot = Self.wordSlotHeight(fontSize: 40)
        let notched = Container(boundsHeight: 759, topInset: 59, bottomInset: 34)
        let flat = Container(boundsHeight: 852, topInset: 0, bottomInset: 0)
        let a = Self.centerInContainer(notched, contentHeight: slot, topBar: 0, bottomBar: 0)
        let b = Self.centerInContainer(flat, contentHeight: slot, topBar: 0, bottomBar: 0)
        #expect(abs(a - b) < 0.001)
    }

    /// The largest word slot (72pt) still lands on the line on the smallest
    /// phones, with chapter navigation showing.
    @Test func largestWordFitsOnSmallestPhonesWithoutYielding() {
        let slot = Self.wordSlotHeight(fontSize: 72)
        for container in [Container.homeButtonPhone, .zoomedHomeButtonPhone] {
            let center = Self.centerInContainer(container, contentHeight: slot, bottomBar: Self.bottomBarWithChapters)
            let expected = container.fullHeight * ReaderStageLayout.fixationFraction
            #expect(abs(center - expected) < 0.001)
        }
    }

    /// Accessibility text sizes grow the bars; the word gives way by exactly
    /// the overlap and no more.
    @Test func wordYieldsJustEnoughToClearAGrownTopBar() {
        let grownTopBar: CGFloat = 260
        let slot = Self.wordSlotHeight(fontSize: 72)
        let container = Container.homeButtonPhone
        let center = Self.centerInContainer(container, contentHeight: slot, topBar: grownTopBar, bottomBar: Self.bottomBar)
        #expect(center > container.fullHeight * ReaderStageLayout.fixationFraction)
        #expect(abs(center - (grownTopBar + slot / 2)) < 0.001)
    }

    @Test func wordYieldsJustEnoughToClearTheBottomBar() {
        let center = ReaderStageLayout.fixationCenterY(
            boundsHeight: 600, topInset: 0, bottomInset: 0,
            contentHeight: 200, topBarHeight: 0, bottomBarHeight: 250
        )
        #expect(center == 250)
    }

    @Test func wordThatCannotFitIsCenteredBetweenTheBars() {
        let container = Container.landscapePhone
        let center = ReaderStageLayout.fixationCenterY(
            boundsHeight: container.boundsHeight,
            topInset: container.topInset,
            bottomInset: container.bottomInset,
            contentHeight: Self.wordSlotHeight(fontSize: 72),
            topBarHeight: Self.topBar,
            bottomBarHeight: Self.bottomBarWithChapters
        )
        let between = ReaderStageLayout.centerBetweenBars(
            boundsHeight: container.boundsHeight,
            topBarHeight: Self.topBar,
            bottomBarHeight: Self.bottomBarWithChapters
        )
        #expect(center == between)
    }

    @Test func centerBetweenBarsIsTheMidpointOfTheFreeSpace() {
        let center = ReaderStageLayout.centerBetweenBars(boundsHeight: 759, topBarHeight: 140, bottomBarHeight: 106)
        #expect(center - 140 == (759 - 106) - center)
        #expect(ReaderStageLayout.centerBetweenBars(boundsHeight: 600, topBarHeight: 0, bottomBarHeight: 0) == 300)
    }

    /// Whenever the word slot fits between the bars, it must clear both.
    @Test func wordNeverOverlapsBarsWhenItFits() {
        for container in Container.all {
            for bottomBar in [Self.bottomBar, Self.bottomBarWithChapters] {
                for fontSize in stride(from: CGFloat(24), through: 72, by: 8) {
                    let slot = Self.wordSlotHeight(fontSize: fontSize)
                    let free = container.boundsHeight - Self.topBar - bottomBar
                    guard slot <= free else { continue }
                    let center = ReaderStageLayout.fixationCenterY(
                        boundsHeight: container.boundsHeight,
                        topInset: container.topInset,
                        bottomInset: container.bottomInset,
                        contentHeight: slot,
                        topBarHeight: Self.topBar,
                        bottomBarHeight: bottomBar
                    )
                    #expect(center - slot / 2 >= Self.topBar - 0.001,
                            "overlaps top bar: \(container), font \(fontSize)")
                    #expect(center + slot / 2 <= container.boundsHeight - bottomBar + 0.001,
                            "overlaps bottom bar: \(container), font \(fontSize)")
                }
            }
        }
    }

    /// With no chrome at all (bars restructured or absent, e.g. a short
    /// landscape screen) the word stays on the line and on screen.
    @Test func wordStaysOnScreenWithoutBarsInShortContainers() {
        let container = Container.landscapePhone
        let slot = Self.wordSlotHeight(fontSize: 72)
        let center = Self.centerInContainer(container, contentHeight: slot, topBar: 0, bottomBar: 0)
        #expect(abs(center - container.fullHeight * ReaderStageLayout.fixationFraction) < 0.001)
        #expect(center - slot / 2 >= 0)
        #expect(center + slot / 2 <= container.fullHeight)
    }

    // MARK: - Folding screens

    /// iPhone Duo's inner screen upright and half open: 951 pt tall, with a
    /// 40 pt fold band across the middle.
    private static let duoUpright = Container(boundsHeight: 951, topInset: 0, bottomInset: 0)
    private static let duoFold: ClosedRange<CGFloat> = 455.5...495.5

    private static func duoCenter(fontSize: CGFloat, fold: ClosedRange<CGFloat>? = duoFold) -> CGFloat {
        ReaderStageLayout.fixationCenterY(
            boundsHeight: duoUpright.boundsHeight,
            topInset: 0,
            bottomInset: 0,
            contentHeight: wordSlotHeight(fontSize: fontSize),
            topBarHeight: topBar,
            bottomBarHeight: bottomBarWithChapters,
            foldBand: fold,
            wordHeight: fontSize * WordView.guideLineHeightRatio
        )
    }

    @Test func wordMovesJustAboveAFoldItWouldSitOn() {
        let fontSize: CGFloat = 56
        let half = fontSize * WordView.guideLineHeightRatio / 2
        let onLine = Self.duoCenter(fontSize: fontSize, fold: nil)
        #expect(onLine + half > Self.duoFold.lowerBound)
        #expect(Self.duoCenter(fontSize: fontSize) == Self.duoFold.lowerBound - half)
    }

    @Test func wordClearOfTheFoldStaysOnTheLine() {
        let farFold: ClosedRange<CGFloat> = 800...840
        #expect(Self.duoCenter(fontSize: 40, fold: farFold) == Self.duoCenter(fontSize: 40, fold: nil))
    }

    /// A fold the word can't clear without running into a bar leaves the
    /// word where the bars put it.
    @Test func wordStaysPutWhenNeitherSideOfTheFoldHasRoom() {
        let center = ReaderStageLayout.fixationCenterY(
            boundsHeight: 400, topInset: 0, bottomInset: 0,
            contentHeight: 120, topBarHeight: 140, bottomBarHeight: 106,
            foldBand: 160...240, wordHeight: 90
        )
        #expect(center == 200)
    }

    // MARK: - Room around the word

    @Test func clearHalfHeightIsTheRoomToTheNearerBar() {
        #expect(ReaderStageLayout.clearHalfHeight(centerY: 300, boundsHeight: 700, topBarHeight: 140, bottomBarHeight: 106) == 160)
        #expect(ReaderStageLayout.clearHalfHeight(centerY: 500, boundsHeight: 700, topBarHeight: 140, bottomBarHeight: 106) == 94)
    }

    @Test func clearHalfHeightIsZeroInsideABar() {
        #expect(ReaderStageLayout.clearHalfHeight(centerY: 100, boundsHeight: 700, topBarHeight: 140, bottomBarHeight: 106) == 0)
        #expect(ReaderStageLayout.clearHalfHeight(centerY: 650, boundsHeight: 700, topBarHeight: 140, bottomBarHeight: 106) == 0)
    }
}
