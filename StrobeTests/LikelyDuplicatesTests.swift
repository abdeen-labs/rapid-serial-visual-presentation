import Foundation
import Testing
@testable import Strobe

/// Books likely in the library twice, with words too different for sync to
/// merge: what matches, what's left alone, the groups kept on this device,
/// and the reading the kept copy takes.
struct LikelyDuplicatesTests {
    private typealias Candidate = LikelyDuplicates.Candidate
    private typealias Origin = CloudSyncLedger.Entry.Origin

    // IDs in a known order: a < b < c < d.
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    private let d = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!

    private let t0 = Date(timeIntervalSince1970: 1_788_220_800) // 2026-09-01 00:00 UTC

    private func day(_ count: Double) -> Date {
        t0.addingTimeInterval(count * 86_400)
    }

    /// A copy of Moby-Dick from another device unless said otherwise.
    private func book(
        _ id: UUID,
        title: String = "Moby-Dick",
        fileName: String = "moby-dick.epub",
        words: Int = 200_000,
        origin: Origin? = .fromICloud,
        isLeaving: Bool = false
    ) -> Candidate {
        Candidate(id: id, title: title, fileName: fileName, wordCount: words, origin: origin, isLeaving: isLeaving)
    }

    /// The groups among `candidates`. Copies in `sameWords` have the same
    /// words as each other.
    private func groups(
        _ candidates: [Candidate],
        kept: KeptLikelyDuplicates = KeptLikelyDuplicates(),
        sameWords: Set<UUID> = []
    ) -> [[UUID]] {
        LikelyDuplicates.groups(among: candidates, kept: kept) { first, second in
            sameWords.contains(first.id) && sameWords.contains(second.id)
        }
    }

    // MARK: - Matching

    @Test func copiesWithTheSameTitleFileNameAndSimilarLengthMatch() {
        let copies = [book(a, origin: .importedHere), book(b, words: 204_000)]
        #expect(groups(copies) == [[a, b]])
    }

    @Test func titlesMatchIgnoringCaseAccentsAndSurroundingSpace() {
        let copies = [
            book(a, title: "Les Misérables", fileName: "les-miserables.epub", origin: .importedHere),
            book(b, title: "  les miserables\n", fileName: "Les-Miserables.EPUB"),
        ]
        #expect(groups(copies) == [[a, b]])
    }

    @Test func differentTitlesOrFileNamesDontMatch() {
        #expect(groups([book(a, origin: .importedHere), book(b, title: "Moby Dick")]).isEmpty)
        #expect(groups([book(a, origin: .importedHere), book(b, fileName: "moby-dick.pdf")]).isEmpty)
        #expect(groups([book(a, origin: .importedHere), book(b, fileName: "moby-dick-2.epub")]).isEmpty)
    }

    @Test func webArticlesMatchOnTheirAddress() {
        let address = "https://example.com/2026/10/the-long-read"
        let here = book(a, title: "The Long Read", fileName: address, words: 5_000, origin: .importedHere)
        let shared = book(b, title: "The Long Read", fileName: address, words: 5_400)
        #expect(groups([here, shared]) == [[a, b]])
        // Another article with the same headline doesn't.
        let other = book(b, title: "The Long Read", fileName: "https://example.org/the-long-read", words: 5_400)
        #expect(groups([here, other]).isEmpty)
    }

    @Test func textAddedWithoutAFileNeverMatches() {
        // New Text and shared text store their title as the file name.
        #expect(groups([book(a, title: "Notes", fileName: "Notes", origin: .importedHere), book(b, title: "Notes", fileName: "Notes")]).isEmpty)
        #expect(groups([book(a, title: "Release 2.0", fileName: "Release 2.0", origin: .importedHere), book(b, title: "Release 2.0", fileName: "Release 2.0")]).isEmpty)
        #expect(groups([book(a, title: "Notes", fileName: "", origin: .importedHere), book(b, title: "Notes", fileName: " ")]).isEmpty)
        // A text file has a file name like any other.
        #expect(groups([book(a, title: "notes", fileName: "notes.txt", origin: .importedHere), book(b, title: "notes", fileName: "Notes.TXT")]) == [[a, b]])
        #expect(LikelyDuplicates.fileNameKey("Draft.md") == "draft.md")
        #expect(LikelyDuplicates.fileNameKey("Draft") == nil)
    }

    @Test func lengthsMatchWithinAFifthOfTheLarger() {
        #expect(groups([book(a, words: 1_000, origin: .importedHere), book(b, words: 1_250)]) == [[a, b]])
        #expect(groups([book(a, words: 1_000, origin: .importedHere), book(b, words: 1_251)]).isEmpty)
        #expect(LikelyDuplicates.haveSimilarLengths(1_250, 1_000))
        #expect(LikelyDuplicates.haveSimilarLengths(1_000, 1_250))
        #expect(!LikelyDuplicates.haveSimilarLengths(1_000, 1_251))
        #expect(!LikelyDuplicates.haveSimilarLengths(0, 0))
    }

    @Test func groupsOfThree() {
        let copies = [book(a, words: 200_000, origin: .importedHere), book(b, words: 190_000), book(c, words: 215_000)]
        #expect(groups(copies) == [[a, b, c]])
    }

    @Test func everyCopyInAGroupIsWithinAFifthOfTheLongest() {
        // 118k is within a fifth of 141k, and 100k of 118k, but 100k isn't
        // of 141k: the longest two go together, and 100k is left on its own.
        let copies = [
            book(a, words: 100_000, origin: .importedHere),
            book(b, words: 118_000, origin: .importedHere),
            book(c, words: 141_000),
        ]
        #expect(groups(copies) == [[b, c]])
    }

    @Test func groupsFollowLibraryOrder() {
        let copies = [
            book(c, title: "Walden", fileName: "walden.epub", words: 110_000, origin: .importedHere),
            book(a, origin: .importedHere),
            book(d, title: "Walden", fileName: "walden.epub", words: 114_000),
            book(b, words: 205_000),
        ]
        #expect(groups(copies) == [[c, d], [a, b]])
    }

    // MARK: - Left alone

    @Test func identicalCopiesAreLeftToSync() {
        // The same words: sync merges copies imported on different devices,
        // and copies imported on one device were made on purpose.
        #expect(groups([book(a, origin: .importedHere), book(b)], sameWords: [a, b]).isEmpty)
        // The same length but different words, from another cleaning level.
        #expect(groups([book(a, origin: .importedHere), book(b)]) == [[a, b]])
        // Two identical copies and a third that isn't.
        let three = [book(a, origin: .importedHere), book(b), book(c, words: 210_000)]
        #expect(groups(three, sameWords: [a, b]) == [[a, b, c]])
    }

    @Test func wordsAreOnlyComparedWhenEveryLengthIsEqual() {
        var comparisons = 0
        let found = LikelyDuplicates.groups(
            among: [book(a, origin: .importedHere), book(b), book(c, words: 201_000)],
            kept: KeptLikelyDuplicates()
        ) { _, _ in
            comparisons += 1
            return true
        }
        #expect(found == [[a, b, c]])
        #expect(comparisons == 0)
    }

    @Test func aGroupImportedHereIsLeftAlone() {
        #expect(groups([book(a, origin: .importedHere), book(b, words: 210_000, origin: .importedHere)]).isEmpty)
        // A copy whose origin sync doesn't know may have come from anywhere.
        #expect(groups([book(a, origin: .importedHere), book(b, words: 210_000, origin: nil)]) == [[a, b]])
        #expect(groups([book(a), book(b, words: 210_000)]) == [[a, b]])
        // One from elsewhere is enough for a group of three.
        let three = [book(a, origin: .importedHere), book(b, words: 210_000, origin: .importedHere), book(c, words: 190_000)]
        #expect(groups(three) == [[a, b, c]])
    }

    @Test func copiesLeavingTheLibraryAreLeftOut() {
        #expect(groups([book(a, origin: .importedHere), book(b, words: 210_000, isLeaving: true)]).isEmpty)
        let three = [book(a, origin: .importedHere), book(b, words: 210_000, isLeaving: true), book(c, words: 190_000)]
        #expect(groups(three) == [[a, c]])
    }

    // MARK: - Kept groups

    @Test func aKeptGroupIsntOfferedAgainUntilACopyJoins() {
        var kept = KeptLikelyDuplicates()
        kept.keep([a, b], library: [a, b])
        let pair = [book(a, origin: .importedHere), book(b, words: 210_000)]
        #expect(groups(pair, kept: kept).isEmpty)
        // A copy that wasn't there when the group was kept brings it back,
        // with every copy.
        #expect(groups(pair + [book(c, words: 190_000)], kept: kept) == [[a, b, c]])
        // Kept as three, it stays kept when one copy leaves.
        kept.keep([a, b, c], library: [a, b, c])
        #expect(groups(pair + [book(c, words: 190_000)], kept: kept).isEmpty)
        #expect(groups([book(a, origin: .importedHere), book(c, words: 190_000)], kept: kept).isEmpty)
    }

    @Test func keptPairsIgnoreOrderAndSurviveStorage() {
        #expect(KeptLikelyDuplicates.pairKey(a, b) == KeptLikelyDuplicates.pairKey(b, a))
        var kept = KeptLikelyDuplicates()
        kept.keep([c, a, b], library: [a, b, c])
        #expect(kept.pairs.count == 3)
        #expect(kept.contains([b, c, a]))
        #expect(kept.contains([a, b]))
        #expect(!kept.contains([a, b, d]))
        #expect(!kept.contains([a]))
        #expect(KeptLikelyDuplicates(rawValue: kept.rawValue) == kept)
        #expect(KeptLikelyDuplicates(rawValue: "") == KeptLikelyDuplicates())
    }

    @Test func keepingForgetsPairsOfBooksNoLongerInTheLibrary() {
        var kept = KeptLikelyDuplicates()
        kept.keep([a, b], library: [a, b])
        // `a` has been deleted since.
        kept.keep([c, d], library: [b, c, d])
        #expect(kept.pairs == [KeptLikelyDuplicates.pairKey(c, d)])
    }

    @Test func keptGroupsLoadFromDefaults() throws {
        let suiteName = "LikelyDuplicatesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var kept = KeptLikelyDuplicates()
        kept.keep([a, b], library: [a, b])
        defaults.set(kept.rawValue, forKey: ReaderSettings.Keys.keptLikelyDuplicates)
        let stored = try #require(defaults.string(forKey: ReaderSettings.Keys.keptLikelyDuplicates))
        #expect(KeptLikelyDuplicates(rawValue: stored).contains([b, a]))
    }

    // MARK: - Position mapping

    @Test func indicesCarryOverInProportionToLength() {
        #expect(LikelyDuplicates.mappedIndex(500, from: 1_000, to: 1_200) == 600)
        #expect(LikelyDuplicates.mappedIndex(600, from: 1_200, to: 1_000) == 500)
        #expect(LikelyDuplicates.mappedIndex(37, from: 1_000, to: 1_000) == 37)
        #expect(LikelyDuplicates.mappedIndex(0, from: 1_000, to: 1_200) == 0)
    }

    @Test func mappedIndicesRoundToTheNearestWord() {
        #expect(LikelyDuplicates.mappedIndex(1, from: 3, to: 2) == 1) // 0.67
        #expect(LikelyDuplicates.mappedIndex(1, from: 5, to: 2) == 0) // 0.4
        #expect(LikelyDuplicates.mappedIndex(1, from: 4, to: 2) == 1) // 0.5, half up
        #expect(LikelyDuplicates.mappedIndex(3, from: 4, to: 5) == 4) // 3.75
        #expect(LikelyDuplicates.mappedIndex(250, from: 1_000, to: 1_001) == 250) // 250.25
    }

    @Test func mappedIndicesStayInsideTheKeptCopy() {
        // The last word lands on the last word, either way.
        #expect(LikelyDuplicates.mappedIndex(1_199, from: 1_200, to: 1_000) == 999)
        #expect(LikelyDuplicates.mappedIndex(999, from: 1_000, to: 1_200) == 1_199)
        // 2.7 rounds to 3, past the end of three words.
        #expect(LikelyDuplicates.mappedIndex(9, from: 10, to: 3) == 2)
        #expect(LikelyDuplicates.mappedIndex(-4, from: 1_000, to: 1_200) == 0)
        #expect(LikelyDuplicates.mappedIndex(5_000, from: 1_000, to: 1_200) == 1_199)
        #expect(LikelyDuplicates.mappedIndex(10, from: 0, to: 1_200) == 0)
        #expect(LikelyDuplicates.mappedIndex(10, from: 1_000, to: 0) == 0)
    }

    // MARK: - Merged reading

    private func reading(
        _ words: Int,
        at current: Int,
        furthest: Int? = nil,
        wpm: Int = 300,
        read: Date? = nil
    ) -> LikelyDuplicates.Reading {
        LikelyDuplicates.Reading(
            wordCount: words,
            position: ReadingPosition(
                currentWordIndex: current,
                furthestWordIndex: furthest ?? current,
                wordsPerMinute: wpm,
                lastReadDate: read
            )
        )
    }

    @Test func keptCopyTakesTheReadingOfTheCopyReadMostRecently() {
        let kept = reading(1_000, at: 100, wpm: 300, read: day(1))
        let latest = reading(1_200, at: 600, wpm: 450, read: day(3))
        let older = reading(900, at: 800, wpm: 250, read: day(2))
        let merged = LikelyDuplicates.mergedReading(keeping: kept, others: [older, latest])
        #expect(merged.currentWordIndex == 500)
        #expect(merged.wordsPerMinute == 450)
        #expect(merged.lastReadDate == day(3))
        // The older copy got furthest: 800 of 900 words is 888.9 of 1,000.
        #expect(merged.furthestWordIndex == 889)
    }

    @Test func keptCopyKeepsItsOwnReadingWhenItWasReadLast() {
        let kept = reading(1_000, at: 100, furthest: 400, wpm: 320, read: day(5))
        let other = reading(1_200, at: 600, wpm: 450, read: day(3))
        let merged = LikelyDuplicates.mergedReading(keeping: kept, others: [other])
        #expect(merged == ReadingPosition(currentWordIndex: 100, furthestWordIndex: 500, wordsPerMinute: 320, lastReadDate: day(5)))
    }

    @Test func aTieOrNoReadingAtAllGoesToTheKeptCopy() {
        let kept = reading(1_000, at: 100, wpm: 320, read: day(3))
        let other = reading(1_200, at: 600, wpm: 450, read: day(3))
        let tie = LikelyDuplicates.mergedReading(keeping: kept, others: [other])
        #expect(tie.currentWordIndex == 100)
        #expect(tie.wordsPerMinute == 320)

        let unread = LikelyDuplicates.mergedReading(keeping: reading(1_000, at: 0), others: [reading(1_200, at: 0, wpm: 450)])
        #expect(unread == ReadingPosition(currentWordIndex: 0, furthestWordIndex: 0, wordsPerMinute: 300, lastReadDate: nil))
    }

    @Test func aCopyReadOnlyElsewhereGivesTheKeptCopyItsReading() {
        // The kept copy was never opened.
        let merged = LikelyDuplicates.mergedReading(
            keeping: reading(1_000, at: 0),
            others: [reading(1_200, at: 600, wpm: 450, read: day(2))]
        )
        #expect(merged == ReadingPosition(currentWordIndex: 500, furthestWordIndex: 500, wordsPerMinute: 450, lastReadDate: day(2)))
    }

    @Test func aFinishedCopyLeavesTheKeptCopyFinished() {
        let merged = LikelyDuplicates.mergedReading(
            keeping: reading(1_000, at: 0),
            others: [reading(1_200, at: 1_199, read: day(1))]
        )
        #expect(merged.currentWordIndex == 999)
        #expect(merged.furthestWordIndex == 999)
    }

    @Test func furthestCountsAResumePointAheadOfTheFurthestPoint() {
        // Documents saved before the furthest point was kept have it at 0,
        // and the library counts the resume point instead.
        let merged = LikelyDuplicates.mergedReading(
            keeping: reading(1_000, at: 10, furthest: 0, read: day(2)),
            others: [reading(1_000, at: 700, furthest: 0, read: day(1))]
        )
        #expect(merged.currentWordIndex == 10)
        #expect(merged.furthestWordIndex == 700)
    }
}
