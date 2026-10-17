import Foundation
import Testing
@testable import Strobe

/// Books a device skipped are fetched again when due, and a full iCloud
/// pauses first uploads on a backoff while small updates go on.
struct SyncRetryTests {

    private let t0 = Date(timeIntervalSince1970: 1_788_220_800) // 2026-09-01 00:00 UTC

    private func minutes(_ count: Double) -> Date {
        t0.addingTimeInterval(count * 60)
    }

    private func hours(_ count: Double) -> Date {
        t0.addingTimeInterval(count * 3600)
    }

    /// A ledger entry for a document whose records iCloud has.
    private func inICloud() -> CloudSyncLedger.Entry {
        CloudSyncLedger.Entry(hasLocalDocument: true, bookSystemFields: Data([1]), stateSystemFields: Data([1]), syncedTitle: "Book")
    }

    /// A ledger entry for a document never uploaded.
    private func notUploaded() -> CloudSyncLedger.Entry {
        CloudSyncLedger.Entry(hasLocalDocument: true)
    }

    // MARK: - Skipped books

    @Test func newerFormatBookIsFetchedAgainOnceABuildReadsIt() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.skipNewerFormatBook(id, format: 2, now: t0)
        #expect(ledger.isSkipped(id))
        #expect(ledger.skippedBooks?[id.uuidString]?.format == 2)
        // A build that reads format 1 never fetches it, however long it waits.
        #expect(ledger.skippedBooksDue(now: hours(24 * 365), readableFormat: 1).isEmpty)
        // One that reads it fetches it right away.
        #expect(ledger.skippedBooksDue(now: t0, readableFormat: 2) == [id])
        #expect(ledger.skippedBooksDue(now: t0, readableFormat: 3) == [id])
    }

    @Test func thisBuildWaitsForAnUpdateToReadANewerFormat() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.skipNewerFormatBook(id, format: CloudSyncSchema.bookFormat + 1, now: t0)
        #expect(ledger.skippedBooksDue(now: hours(24 * 365)).isEmpty)
    }

    @Test func unreadableBookWaitsLongerAfterEachTry() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.skipUnreadableBook(id, now: t0)
        #expect(ledger.isSkipped(id))
        #expect(ledger.skippedBooks?[id.uuidString]?.format == nil)
        #expect(ledger.skippedBooksDue(now: minutes(59)).isEmpty)
        #expect(ledger.skippedBooksDue(now: hours(1)) == [id])

        // Unreadable again: two hours, then four.
        ledger.skipUnreadableBook(id, now: hours(1))
        #expect(ledger.skippedBooksDue(now: hours(2.9)).isEmpty)
        #expect(ledger.skippedBooksDue(now: hours(3)) == [id])
        ledger.skipUnreadableBook(id, now: hours(3))
        #expect(ledger.skippedBooks?[id.uuidString]?.failures == 3)
        #expect(ledger.skippedBooks?[id.uuidString]?.retryAfter == hours(7))
    }

    @Test func unreadableBookWaitsAtMostAWeek() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        for _ in 0..<20 {
            ledger.skipUnreadableBook(id, now: t0)
        }
        #expect(ledger.skippedBooks?[id.uuidString]?.failures == 20)
        #expect(ledger.skippedBooks?[id.uuidString]?.retryAfter == hours(24 * 7))
    }

    @Test func onlyBooksPastTheirWaitAreDue() {
        let first = UUID()
        let second = UUID()
        let waiting = UUID()
        let newer = UUID()
        var ledger = CloudSyncLedger()
        ledger.skipUnreadableBook(first, now: t0)
        ledger.skipUnreadableBook(second, now: t0)
        ledger.skipUnreadableBook(waiting, now: minutes(30))
        ledger.skipNewerFormatBook(newer, format: 2, now: t0)

        let due = ledger.skippedBooksDue(now: hours(1), readableFormat: 1)
        #expect(due == [first, second].sorted { $0.uuidString < $1.uuidString })
    }

    @Test func failedFetchOfASkippedBookWaitsBeforeTheNext() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.skipNewerFormatBook(id, format: 2, now: t0)
        ledger.skippedBookFetchFailed(id, now: t0)
        // Still waiting for a build that reads its format, and now an hour too.
        #expect(ledger.skippedBooks?[id.uuidString]?.format == 2)
        #expect(ledger.skippedBooksDue(now: minutes(30), readableFormat: 2).isEmpty)
        #expect(ledger.skippedBooksDue(now: hours(1), readableFormat: 2) == [id])

        // A book that isn't skipped isn't listed by a failed fetch.
        let other = UUID()
        ledger.skippedBookFetchFailed(other, now: t0)
        #expect(!ledger.isSkipped(other))
    }

    @Test func bookTakenInLeavesTheList() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.skipUnreadableBook(id, now: t0)
        ledger.markLocal(id)
        #expect(!ledger.isSkipped(id))
        #expect(ledger.entry(for: id)?.hasLocalDocument == true)
    }

    @Test func bookDeletedFromICloudLeavesTheList() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.skipUnreadableBook(id, now: t0)
        // Its reading state going doesn't say anything about the book.
        _ = ledger.receiveDeletion(of: CloudRecordKey(.state, id), isOpen: false)
        #expect(ledger.isSkipped(id))

        let removesDocument = ledger.receiveDeletion(of: CloudRecordKey(.book, id), isOpen: false)
        #expect(!removesDocument)
        #expect(!ledger.isSkipped(id))

        // Found gone by the fetch itself.
        let gone = UUID()
        ledger.skipNewerFormatBook(gone, format: 2, now: t0)
        ledger.forgetSkippedBook(gone)
        #expect(!ledger.isSkipped(gone))
    }

    @Test func refetchedBookNeitherTakenInNorSkippedAgainLeavesTheList() {
        let takenIn = UUID()
        let unreadable = UUID()
        let unchanged = UUID()
        let notFetched = UUID()
        var ledger = CloudSyncLedger()
        for id in [takenIn, unreadable, unchanged, notFetched] {
            ledger.skipUnreadableBook(id, now: t0)
        }
        let before = ledger.skippedBooks

        // What applying the fetched records did.
        ledger.markLocal(takenIn)
        ledger.skipUnreadableBook(unreadable, now: hours(1))
        ledger.finishRefetch(of: [takenIn, unreadable, unchanged], skippedBefore: before)

        #expect(!ledger.isSkipped(takenIn))
        #expect(ledger.skippedBooks?[unreadable.uuidString]?.failures == 2)
        // Here already, say: fetching it again won't help.
        #expect(!ledger.isSkipped(unchanged))
        #expect(ledger.isSkipped(notFetched))
    }

    @Test func forgettingServerRecordsForgetsSkippedBooks() {
        var ledger = CloudSyncLedger()
        ledger.skipUnreadableBook(UUID(), now: t0)
        ledger.forgetServerRecords()
        #expect(ledger.skippedBooksDue(now: hours(24 * 365)).isEmpty)
    }

    // MARK: - Full storage

    @Test func storagePauseDoublesUpToADay() throws {
        var ledger = CloudSyncLedger()
        var now = t0
        var lengths: [TimeInterval] = []
        for _ in 0..<9 {
            let next = ledger.noteStorageFull(refusedUpdate: false, now: now)
            let until = try #require(next)
            lengths.append(until.timeIntervalSince(now))
            now = until
        }
        #expect(lengths.map { $0 / 60 } == [15, 30, 60, 120, 240, 480, 960, 1440, 1440])
        #expect(ledger.storagePause?.failures == 9)
    }

    @Test func refusalDuringAPauseDoesNotLengthenIt() throws {
        var ledger = CloudSyncLedger()
        let first = ledger.noteStorageFull(refusedUpdate: false, now: t0)
        let until = try #require(first)
        // A batch sent before the pause began comes back refused too.
        let second = ledger.noteStorageFull(refusedUpdate: false, now: minutes(1))
        #expect(second == nil)
        #expect(ledger.storagePause?.until == until)
        #expect(ledger.storagePause?.failures == 1)
    }

    @Test func noPauseHoldsNothing() {
        let unsent = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[unsent.uuidString] = notUploaded()
        #expect(!ledger.isStoragePaused(now: t0))
        #expect(!ledger.holdsSave(CloudRecordKey(.book, unsent), now: t0))
        #expect(!ledger.holdsSave(CloudRecordKey(.state, unsent), now: t0))
    }

    @Test func pauseHoldsFirstUploadsAndLetsUpdatesThrough() {
        let synced = UUID()
        let unsent = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[synced.uuidString] = inICloud()
        ledger.entries[unsent.uuidString] = notUploaded()
        _ = ledger.noteStorageFull(refusedUpdate: false, now: t0)

        // A book iCloud doesn't have, and its first reading state.
        #expect(ledger.holdsSave(CloudRecordKey(.book, unsent), now: minutes(1)))
        #expect(ledger.holdsSave(CloudRecordKey(.state, unsent), now: minutes(1)))
        // A position, and a rename, of a book iCloud has.
        #expect(!ledger.holdsSave(CloudRecordKey(.state, synced), now: minutes(1)))
        #expect(!ledger.holdsSave(CloudRecordKey(.book, synced), now: minutes(1)))

        // Once the pause ends, everything goes again.
        #expect(ledger.isStoragePaused(now: minutes(14)))
        #expect(!ledger.isStoragePaused(now: minutes(15)))
        #expect(!ledger.holdsSave(CloudRecordKey(.book, unsent), now: minutes(15)))
    }

    @Test func refusedUpdateHoldsUpdatesUntilThePauseEnds() {
        let synced = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[synced.uuidString] = inICloud()
        _ = ledger.noteStorageFull(refusedUpdate: false, now: t0)

        // An update the pause let through was refused as well.
        let next = ledger.noteStorageFull(refusedUpdate: true, now: minutes(2))
        #expect(next == nil)
        #expect(ledger.holdsSave(CloudRecordKey(.state, synced), now: minutes(3)))
        #expect(ledger.holdsSave(CloudRecordKey(.book, synced), now: minutes(3)))
        #expect(!ledger.holdsSave(CloudRecordKey(.state, synced), now: minutes(15)))
    }

    @Test func firstUploadThatGoesThroughEndsThePause() throws {
        var ledger = CloudSyncLedger()
        ledger.entries[UUID().uuidString] = notUploaded()
        var now = t0
        for _ in 0..<3 {
            let next = ledger.noteStorageFull(refusedUpdate: false, now: now)
            now = try #require(next)
        }
        ledger.noteSavesAccepted(includingFirstUpload: true)
        #expect(ledger.storagePause == nil)

        // The next refusal starts over at 15 minutes.
        let next = ledger.noteStorageFull(refusedUpdate: false, now: now)
        #expect(next == now.addingTimeInterval(15 * 60))
    }

    @Test func updateThatGoesThroughKeepsBooksWaiting() {
        let synced = UUID()
        let unsent = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[synced.uuidString] = inICloud()
        ledger.entries[unsent.uuidString] = notUploaded()
        _ = ledger.noteStorageFull(refusedUpdate: true, now: t0)
        #expect(ledger.holdsSave(CloudRecordKey(.state, synced), now: minutes(1)))

        // Updates fit after all: they go again, and books keep waiting on
        // the same backoff.
        ledger.noteSavesAccepted(includingFirstUpload: false)
        #expect(ledger.storagePause?.failures == 1)
        #expect(!ledger.holdsSave(CloudRecordKey(.state, synced), now: minutes(1)))
        #expect(ledger.holdsSave(CloudRecordKey(.book, unsent), now: minutes(1)))
    }

    @Test func pauseEndsOnceNoBookWaitsToUpload() {
        let synced = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[synced.uuidString] = inICloud()
        #expect(!ledger.hasBooksToUpload)
        _ = ledger.noteStorageFull(refusedUpdate: true, now: t0)
        ledger.noteSavesAccepted(includingFirstUpload: false)
        #expect(ledger.storagePause == nil)
    }

    @Test func zoneIsKnownToExistOnceARecordIsInICloud() {
        var ledger = CloudSyncLedger()
        ledger.entries[UUID().uuidString] = notUploaded()
        #expect(ledger.hasBooksToUpload)
        #expect(!ledger.hasRecordsInICloud)

        // A reading state waiting for its book.
        let state = StampedReadingPosition(
            position: ReadingPosition(currentWordIndex: 0, furthestWordIndex: 0, wordsPerMinute: 300, lastReadDate: nil),
            modifiedAt: t0
        )
        _ = ledger.receiveState(state, systemFields: Data([1]), for: UUID(), local: nil, now: t0)
        #expect(ledger.hasRecordsInICloud)
    }

    // MARK: - Ledger file

    @Test func skippedBooksAndThePauseSurviveTheLedgerFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SyncRetryTests-\(UUID().uuidString)/Ledger.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = CloudSyncLedger()
        ledger.skipNewerFormatBook(UUID(), format: 2, now: t0)
        ledger.skipUnreadableBook(UUID(), now: t0)
        _ = ledger.noteStorageFull(refusedUpdate: true, now: t0)
        try ledger.save(to: url)

        let loaded = CloudSyncLedger.load(from: url)
        #expect(loaded.skippedBooks == ledger.skippedBooks)
        #expect(loaded.storagePause == ledger.storagePause)
    }

    @Test func ledgerFromAnEarlierBuildStillDecodes() throws {
        let earlier: [String: Any] = [
            "storeIdentifier": "store",
            "hasFetchedEverything": true,
            "entries": [String: Any](),
            "pendingDeletes": [String](),
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: earlier, format: .binary, options: 0)
        let ledger = try PropertyListDecoder().decode(CloudSyncLedger.self, from: data)
        #expect(ledger.storeIdentifier == "store")
        #expect(ledger.hasFetchedEverything)
        #expect(ledger.skippedBooks == nil)
        #expect(ledger.storagePause == nil)
    }
}
