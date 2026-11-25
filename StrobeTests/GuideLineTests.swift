import Testing
import Foundation
@testable import Strobe

struct GuideLineTests {

    private func isClose(_ a: Double?, _ b: Double) -> Bool {
        guard let a else { return false }
        return abs(a - b) < 1e-9
    }

    private func opacity(after value: Double, up: Bool) -> Double? {
        GuideLine.stepped(value, by: GuideLine.opacityStep, up: up, in: GuideLine.opacityRange)
    }

    private func width(after value: Double, up: Bool) -> Double? {
        GuideLine.stepped(value, by: GuideLine.widthStep, up: up, in: GuideLine.widthRange)
    }

    // MARK: - Defaults

    /// The line as it was drawn before it had settings.
    @Test func defaultsDrawTheLineAsBefore() {
        #expect(GuideLine.Style.defaultValue == .line)
        #expect(ReaderSettings.Defaults.guideLineOpacity == 0.12)
        #expect(ReaderSettings.Defaults.guideLineWidth == 1.5)
        #expect(GuideLine.opacityRange.contains(ReaderSettings.Defaults.guideLineOpacity))
        #expect(GuideLine.widthRange.contains(ReaderSettings.Defaults.guideLineWidth))
    }

    @Test func unknownStyleReadsAsTheDefault() {
        #expect(GuideLine.Style.resolve("ticks") == .ticks)
        #expect(GuideLine.Style.resolve("dots") == .line)
        #expect(GuideLine.Style.resolve("") == .line)
    }

    /// The ticks fit inside the line's height with room for the word.
    @Test func ticksLeaveRoomForTheWord() {
        #expect(GuideLine.tickGapRatio > 1)
        #expect(GuideLine.tickGapRatio < WordView.guideLineHeightRatio)
    }

    // MARK: - Stepping

    /// The default opacity sits between two steps; either button lands on
    /// the nearer one its way.
    @Test func defaultOpacityStepsOntoAWholeStep() {
        #expect(isClose(opacity(after: 0.12, up: true), 0.15))
        #expect(isClose(opacity(after: 0.12, up: false), 0.10))
    }

    @Test func wholeStepsMoveOneStep() {
        #expect(isClose(opacity(after: 0.15, up: true), 0.20))
        #expect(isClose(opacity(after: 0.15, up: false), 0.10))
        #expect(isClose(width(after: 1.5, up: true), 2))
        #expect(isClose(width(after: 1.5, up: false), 1))
    }

    @Test func stopsAtTheEndsOfTheRange() {
        #expect(opacity(after: 1, up: true) == nil)
        #expect(opacity(after: 0, up: false) == nil)
        #expect(isClose(opacity(after: 0.97, up: true), 1))
        #expect(isClose(opacity(after: 0.03, up: false), 0))
        #expect(width(after: 5, up: true) == nil)
        #expect(width(after: 0.5, up: false) == nil)
    }

    /// A value stored outside the range comes back into it.
    @Test func valuesOutsideTheRangeComeBack() {
        #expect(isClose(opacity(after: 3, up: false), 1))
        #expect(isClose(opacity(after: -1, up: true), 0))
        #expect(isClose(width(after: 0, up: true), 0.5))
    }

    /// Pressing + from hidden walks every step to full and stops, with no
    /// step skipped or repeated by rounding.
    @Test func walksTheWholeRangeBothWays() {
        var value = GuideLine.opacityRange.lowerBound
        var steps = 0
        while let next = opacity(after: value, up: true) {
            #expect(isClose(next, Double(steps + 1) * GuideLine.opacityStep))
            value = next
            steps += 1
            if steps > 100 { break }
        }
        #expect(steps == 20)
        #expect(value == 1)

        while let next = opacity(after: value, up: false) {
            value = next
            steps -= 1
            if steps < -100 { break }
        }
        #expect(steps == 0)
        #expect(value == 0)
    }

    @Test func aZeroStepNeverMoves() {
        #expect(GuideLine.stepped(0.5, by: 0, up: true, in: 0...1) == nil)
    }
}
