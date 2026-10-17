import Foundation
import Testing
@testable import Strobe

/// How a fetched batch's new books are split into saves, so a first sync
/// holds one save's worth of words in memory rather than the whole batch.
struct SyncSaveChunksTests {

    @Test func noBooksMeansNoSaves() {
        #expect(BookContent.saveRanges(sizes: [], limit: 12).isEmpty)
    }

    @Test func booksThatFitAreSavedTogether() {
        #expect(BookContent.saveRanges(sizes: [3, 4, 5], limit: 12) == [0..<3])
    }

    @Test func aRunEndsBeforeTheBookThatWouldPassTheLimit() {
        #expect(BookContent.saveRanges(sizes: [6, 6, 6], limit: 12) == [0..<2, 2..<3])
        #expect(BookContent.saveRanges(sizes: [5, 8, 4, 9], limit: 12) == [0..<1, 1..<3, 3..<4])
    }

    @Test func aBookLargerThanTheLimitIsSavedOnItsOwn() {
        #expect(BookContent.saveRanges(sizes: [5, 30, 5], limit: 12) == [0..<1, 1..<2, 2..<3])
        #expect(BookContent.saveRanges(sizes: [30], limit: 12) == [0..<1])
    }

    @Test func booksAlreadyHereJoinTheRunTheyFallIn() {
        // Size 0: a book this device has, whose record only updates its
        // title. It never starts a save of its own.
        #expect(BookContent.saveRanges(sizes: [0, 0, 10, 0, 10], limit: 12) == [0..<4, 4..<5])
        #expect(BookContent.saveRanges(sizes: [30, 0, 0], limit: 12) == [0..<3])
        #expect(BookContent.saveRanges(sizes: [0, 0], limit: 12) == [0..<2])
    }

    @Test func everyBookIsInExactlyOneRunInOrder() {
        let sizes = [7, 0, 13, 2, 2, 2, 40, 0, 11, 1]
        let ranges = BookContent.saveRanges(sizes: sizes, limit: 12)
        #expect(ranges.flatMap { Array($0) } == Array(sizes.indices))
        // Only a run with a single new book (one larger than the limit, with
        // books already here around it) goes over.
        for range in ranges where range.filter({ sizes[$0] > 0 }).count > 1 {
            #expect(sizes[range].reduce(0, +) <= 12)
        }
    }
}
