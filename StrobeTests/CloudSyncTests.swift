import CloudKit
import Foundation
import Testing
@testable import Strobe

struct CloudSyncTests {

    private let t0 = Date(timeIntervalSince1970: 1_788_220_800) // 2026-09-01 00:00 UTC

    private func minutes(_ count: Double) -> Date {
        t0.addingTimeInterval(count * 60)
    }

    private func position(_ current: Int, furthest: Int? = nil, wpm: Int = 300, read: Date? = nil) -> ReadingPosition {
        ReadingPosition(
            currentWordIndex: current,
            furthestWordIndex: furthest ?? current,
            wordsPerMinute: wpm,
            lastReadDate: read
        )
    }

    private func document(
        _ id: UUID,
        title: String = "Book",
        at position: ReadingPosition,
        added: Date? = nil,
        isOpen: Bool = false
    ) -> LocalDocumentSnapshot {
        LocalDocumentSnapshot(id: id, title: title, position: position, dateAdded: added ?? t0, isOpen: isOpen)
    }

    /// A ledger entry for a document iCloud already has, as `title` at `state`.
    private func synced(title: String = "Book", state: StampedReadingPosition, contentHash: String? = nil) -> CloudSyncLedger.Entry {
        CloudSyncLedger.Entry(
            hasLocalDocument: true,
            bookSystemFields: Data([1]),
            stateSystemFields: Data([1]),
            syncedTitle: title,
            syncedState: state,
            contentHash: contentHash
        )
    }

    private func bookFields(title: String = "Book", words: [String] = ["Call", "me", "Ishmael."]) -> BookRecordFields {
        BookRecordFields(
            title: title,
            fileName: "moby.epub",
            dateAdded: t0,
            wordCount: words.count,
            chapters: [Chapter(title: "Loomings", wordIndex: 0)],
            contentHash: ContentFingerprint.of(WordStorage.encode(words))
        )
    }

    // MARK: - Record keys

    @Test func recordNamesRoundTrip() {
        let id = UUID()
        #expect(CloudRecordKey(.book, id).recordName == "book-\(id.uuidString)")
        #expect(CloudRecordKey(.state, id).recordName == "state-\(id.uuidString)")
        for kind in [CloudRecordKey.Kind.book, .state] {
            let key = CloudRecordKey(kind, id)
            #expect(CloudRecordKey(recordName: key.recordName) == key)
            #expect(CloudRecordKey(recordID: key.recordID) == key)
        }
    }

    @Test func foreignRecordNamesAreIgnored() {
        #expect(CloudRecordKey(recordName: "note-\(UUID().uuidString)") == nil)
        #expect(CloudRecordKey(recordName: "book-not-a-uuid") == nil)
        #expect(CloudRecordKey(recordName: "book") == nil)
        let otherZone = CKRecordZone.ID(zoneName: "Other", ownerName: CKCurrentUserDefaultName)
        #expect(CloudRecordKey(recordID: CKRecord.ID(recordName: "book-\(UUID().uuidString)", zoneID: otherZone)) == nil)
    }

    /// A session's record name never reads as a document's, or the other
    /// way round, so document sync passes sessions by.
    @Test func sessionRecordNamesStayApartFromDocuments() {
        let id = UUID()
        let key = SessionRecordKey(id)
        #expect(key.recordName == "session-\(id.uuidString)")
        #expect(SessionRecordKey(recordName: key.recordName) == key)
        #expect(SessionRecordKey(recordID: key.recordID) == key)
        #expect(CloudRecordKey(recordID: key.recordID) == nil)
        #expect(SessionRecordKey(recordID: CloudRecordKey(.book, id).recordID) == nil)
        #expect(SessionRecordKey(recordID: CloudRecordKey(.state, id).recordID) == nil)
        #expect(SessionRecordKey(recordName: "session-not-a-uuid") == nil)
        let otherZone = CKRecordZone.ID(zoneName: "Other", ownerName: CKCurrentUserDefaultName)
        #expect(SessionRecordKey(recordID: CKRecord.ID(recordName: key.recordName, zoneID: otherZone)) == nil)
    }

    // MARK: - Merging positions

    @Test func laterResumePointWinsAndFurthestNeverDrops() {
        let older = StampedReadingPosition(position: position(100, furthest: 400), modifiedAt: t0)
        let newer = StampedReadingPosition(position: position(20, wpm: 450), modifiedAt: minutes(1))
        let merged = StampedReadingPosition.merged(older, newer)
        #expect(merged.position == position(20, furthest: 400, wpm: 450))
        #expect(merged.modifiedAt == minutes(1))
        #expect(StampedReadingPosition.merged(newer, older) == merged)
    }

    @Test func equalStampsMergeTheSameEitherWay() {
        let a = StampedReadingPosition(position: position(10, wpm: 500), modifiedAt: t0)
        let b = StampedReadingPosition(position: position(90, wpm: 250), modifiedAt: t0)
        #expect(StampedReadingPosition.merged(a, b) == StampedReadingPosition.merged(b, a))
        #expect(StampedReadingPosition.merged(a, b).position.currentWordIndex == 90)
    }

    @Test func lastReadDateTakesTheLater() {
        let read = StampedReadingPosition(position: position(5, read: minutes(30)), modifiedAt: t0)
        let unread = StampedReadingPosition(position: position(0), modifiedAt: minutes(60))
        #expect(StampedReadingPosition.merged(read, unread).position.lastReadDate == minutes(30))
        let later = StampedReadingPosition(position: position(0, read: minutes(90)), modifiedAt: t0)
        #expect(StampedReadingPosition.merged(read, later).position.lastReadDate == minutes(90))
    }

    @Test func positionsStayInsideTheDocument() {
        let clamped = ReadingPosition(currentWordIndex: 900, furthestWordIndex: -3, wordsPerMinute: 0, lastReadDate: nil)
            .clamped(toWordCount: 100)
        #expect(clamped == ReadingPosition(currentWordIndex: 99, furthestWordIndex: 0, wordsPerMinute: 1, lastReadDate: nil))
        #expect(position(4).clamped(toWordCount: 0).currentWordIndex == 0)
    }

    // MARK: - Records

    @Test func bookFieldsRoundTripThroughARecord() {
        let id = UUID()
        let record = CKRecord(recordType: CloudSyncSchema.RecordType.book, recordID: CloudRecordKey(.book, id).recordID)
        let fields = bookFields(title: "Moby-Dick")
        fields.write(to: record)
        #expect(BookRecordFields(record: record) == fields)
        #expect(BookRecordFields.title(in: record) == "Moby-Dick")
    }

    @Test func readingStateRoundTripsThroughARecord() {
        let id = UUID()
        for read in [nil, minutes(5)] {
            let record = CKRecord(
                recordType: CloudSyncSchema.RecordType.readingState,
                recordID: CloudRecordKey(.state, id).recordID
            )
            let state = StampedReadingPosition(position: position(12, furthest: 40, wpm: 350, read: read), modifiedAt: minutes(6))
            state.write(to: record)
            #expect(StampedReadingPosition(record: record) == state)
        }
    }

    @Test func recordsOfTheOtherTypeAreRejected() {
        let id = UUID()
        let stateRecord = CKRecord(recordType: CloudSyncSchema.RecordType.readingState, recordID: CloudRecordKey(.state, id).recordID)
        StampedReadingPosition(position: position(1), modifiedAt: t0).write(to: stateRecord)
        #expect(BookRecordFields(record: stateRecord) == nil)
        let bookRecord = CKRecord(recordType: CloudSyncSchema.RecordType.book, recordID: CloudRecordKey(.book, id).recordID)
        bookFields().write(to: bookRecord)
        #expect(StampedReadingPosition(record: bookRecord) == nil)
    }

    @Test func systemFieldsRecreateTheRecord() {
        let key = CloudRecordKey(.book, UUID())
        let record = CKRecord(recordType: key.recordType, recordID: key.recordID)
        let restored = CloudRecordArchive.record(fromSystemFields: CloudRecordArchive.systemFields(of: record))
        #expect(restored?.recordID == key.recordID)
        #expect(restored?.recordType == CloudSyncSchema.RecordType.book)
    }

    @Test func fingerprintIsHexSHA256() {
        #expect(ContentFingerprint.of(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func downloadedWordsMustMatchTheirFingerprint() throws {
        let words = ["Call", "me", "Ishmael."]
        let directory = FileManager.default.temporaryDirectory.appending(path: "CloudSyncTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wordsURL = directory.appending(path: "words")
        try WordStorage.encode(words).write(to: wordsURL)
        let scoresURL = directory.appending(path: "scores")
        try ComplexityStorage.encode([0.1, 0.2, 0.3]).write(to: scoresURL)
        let shortScoresURL = directory.appending(path: "short")
        try ComplexityStorage.encode([0.1]).write(to: shortScoresURL)

        let content = BookContent.load(wordsURL: wordsURL, complexityURL: scoresURL, fields: bookFields(words: words))
        #expect(content.map { WordStorage.decode($0.words) } == words)
        #expect(content?.complexity != nil)
        // Scores that don't line up with the words are dropped, not the book.
        let unscored = BookContent.load(wordsURL: wordsURL, complexityURL: shortScoresURL, fields: bookFields(words: words))
        #expect(unscored != nil)
        #expect(unscored?.complexity == nil)
        #expect(BookContent.load(wordsURL: wordsURL, complexityURL: nil, fields: bookFields(words: ["Other"])) == nil)
        #expect(BookContent.load(wordsURL: nil, complexityURL: nil, fields: bookFields(words: words)) == nil)
    }

    // MARK: - Reconciling local changes

    @Test func existingLibraryUploadsWithItsOwnDates() {
        var ledger = CloudSyncLedger()
        let read = UUID()
        let unread = UUID()
        let plan = ledger.reconcile([
            document(read, at: position(40, read: minutes(60)), added: t0),
            document(unread, at: position(0), added: minutes(1)),
        ], now: minutes(10_000))
        #expect(Set(plan.saves) == [
            CloudRecordKey(.book, read), CloudRecordKey(.state, read),
            CloudRecordKey(.book, unread), CloudRecordKey(.state, unread),
        ])
        #expect(plan.deletes.isEmpty)
        #expect(plan.removals.isEmpty)
        // Stamped with when each was read or added, not with the upgrade.
        #expect(ledger.entry(for: read)?.localState?.modifiedAt == minutes(60))
        #expect(ledger.entry(for: unread)?.localState?.modifiedAt == minutes(1))
        #expect(ledger.entry(for: read)?.hasLocalDocument == true)
    }

    @Test func unchangedSyncedDocumentSendsNothing() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(10), modifiedAt: t0))
        let plan = ledger.reconcile([document(id, at: position(10))], now: minutes(5))
        #expect(plan == ReconcilePlan())
    }

    @Test func positionChangeIsStampedWhenFirstSeen() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(10), modifiedAt: t0))

        let plan = ledger.reconcile([document(id, at: position(20))], now: minutes(1))
        #expect(plan.saves == [CloudRecordKey(.state, id)])
        #expect(ledger.entry(for: id)?.localState?.modifiedAt == minutes(1))

        _ = ledger.reconcile([document(id, at: position(20))], now: minutes(2))
        #expect(ledger.entry(for: id)?.localState?.modifiedAt == minutes(1))

        _ = ledger.reconcile([document(id, at: position(30))], now: minutes(3))
        #expect(ledger.entry(for: id)?.localState?.modifiedAt == minutes(3))
    }

    @Test func renameSendsTheBook() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(title: "Old", state: StampedReadingPosition(position: position(0), modifiedAt: t0))
        let plan = ledger.reconcile([document(id, title: "New", at: position(0))], now: t0)
        #expect(plan.saves == [CloudRecordKey(.book, id)])
    }

    @Test func deletingADocumentDeletesItsRecordsUntilConfirmed() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(0), modifiedAt: t0))

        let plan = ledger.reconcile([], now: t0)
        #expect(plan.deletes == [CloudRecordKey(.book, id), CloudRecordKey(.state, id)])
        #expect(ledger.entry(for: id) == nil)
        let again = ledger.reconcile([], now: t0)
        #expect(again.deletes == plan.deletes)

        ledger.confirmDeleted(CloudRecordKey(.book, id))
        let confirmed = ledger.reconcile([], now: t0)
        #expect(confirmed.deletes.isEmpty)
    }

    @Test func onlyDocumentsSeenInTheLibraryAreDeleted() {
        var ledger = CloudSyncLedger()
        // A reading state still waiting for its book.
        let waiting = UUID()
        let state = StampedReadingPosition(position: position(7), modifiedAt: t0)
        let shown = ledger.receiveState(state, systemFields: Data([1]), for: waiting, local: nil, now: t0)
        #expect(shown == nil)

        let plan = ledger.reconcile([], now: t0)
        #expect(plan.deletes.isEmpty)
        #expect(ledger.entry(for: waiting)?.syncedState == state)
    }

    @Test func documentDeletedElsewhereWaitsWhileOpen() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(10), modifiedAt: t0))

        let removeNow = ledger.receiveDeletion(of: CloudRecordKey(.book, id), isOpen: true)
        #expect(!removeNow)
        #expect(ledger.entry(for: id)?.removal == .deletedElsewhere(foldInto: nil))

        // Reading on while it's open sends nothing and deletes nothing.
        let open = ledger.reconcile([document(id, at: position(50), isOpen: true)], now: minutes(1))
        #expect(open == ReconcilePlan())

        let closed = ledger.reconcile([document(id, at: position(50))], now: minutes(2))
        #expect(closed.removals == [id])
        #expect(closed.deletes.isEmpty)
        #expect(closed.saves.isEmpty)
        #expect(ledger.entry(for: id) == nil)
    }

    @Test func deletionWithoutALedgerEntryKeepsTheDocument() {
        var ledger = CloudSyncLedger()
        let removesUnknown = ledger.receiveDeletion(of: CloudRecordKey(.book, UUID()), isOpen: false)
        #expect(!removesUnknown)

        let id = UUID()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(0), modifiedAt: t0))
        let removesSynced = ledger.receiveDeletion(of: CloudRecordKey(.book, id), isOpen: false)
        #expect(removesSynced)
        #expect(ledger.entry(for: id) == nil)
    }

    @Test func mergedCopyHandsItsReadingToTheCopyInICloud() {
        let keeper = UUID()
        let copy = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[keeper.uuidString] = synced(state: StampedReadingPosition(position: position(5), modifiedAt: t0))
        // Never uploaded: no records in iCloud.
        ledger.markMerged(copy, into: keeper)

        let plan = ledger.reconcile([
            document(keeper, at: position(5)),
            document(copy, at: position(50, furthest: 80, read: minutes(1))),
        ], now: minutes(2))
        #expect(plan.removals == [copy])
        #expect(plan.positionUpdates == [keeper: position(50, furthest: 80, read: minutes(1))])
        #expect(plan.saves == [CloudRecordKey(.state, keeper)])
        // In case an upload of the copy did land.
        #expect(plan.deletes == [CloudRecordKey(.book, copy), CloudRecordKey(.state, copy)])
        // The merged position keeps the copy's stamp, not the merge time.
        #expect(ledger.entry(for: keeper)?.localState?.modifiedAt == minutes(1))
        #expect(ledger.entry(for: copy) == nil)
    }

    @Test func mergedCopyWaitsWhileOpen() {
        let keeper = UUID()
        let copy = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[keeper.uuidString] = synced(state: StampedReadingPosition(position: position(5), modifiedAt: t0))
        ledger.markMerged(copy, into: keeper)

        let plan = ledger.reconcile([
            document(keeper, at: position(5)),
            document(copy, at: position(60), isOpen: true),
        ], now: minutes(2))
        #expect(plan == ReconcilePlan())
    }

    @Test func mergedCopyStaysWhenTheCopyInICloudIsGone() {
        let keeper = UUID()
        let copy = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[keeper.uuidString] = synced(state: StampedReadingPosition(position: position(5), modifiedAt: t0))
        ledger.markMerged(copy, into: keeper)

        // The user deleted the kept copy before the merge: this one is now
        // the only one, so it stays and uploads.
        let plan = ledger.reconcile([document(copy, at: position(60))], now: minutes(2))
        #expect(plan.removals.isEmpty)
        #expect(plan.positionUpdates.isEmpty)
        #expect(Set(plan.saves) == [CloudRecordKey(.book, copy), CloudRecordKey(.state, copy)])
        #expect(plan.deletes == [CloudRecordKey(.book, keeper), CloudRecordKey(.state, keeper)])
        #expect(ledger.entry(for: copy)?.removal == nil)
    }

    @Test func mergedCopyThatTurnsOutToBeInICloudStays() {
        let keeper = UUID()
        let copy = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[keeper.uuidString] = synced(state: StampedReadingPosition(position: position(5), modifiedAt: t0))
        ledger.markMerged(copy, into: keeper)
        _ = ledger.receiveBook(bookFields(), systemFields: Data([3]), for: copy, localTitle: "Book")

        let plan = ledger.reconcile([
            document(keeper, at: position(5)),
            document(copy, at: position(60)),
        ], now: minutes(2))
        #expect(plan.removals.isEmpty)
        #expect(plan.deletes.isEmpty)
        #expect(ledger.entry(for: copy)?.removal == nil)
    }

    @Test func bookDeletedElsewhereWhileOpenHandsItsReadingOn() {
        let deleted = UUID()
        let copy = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[deleted.uuidString] = synced(state: StampedReadingPosition(position: position(10), modifiedAt: t0))
        ledger.entries[copy.uuidString] = synced(state: StampedReadingPosition(position: position(4), modifiedAt: t0))

        let removeNow = ledger.receiveDeletion(of: CloudRecordKey(.book, deleted), isOpen: true, foldInto: copy)
        #expect(!removeNow)
        let whileOpen = ledger.reconcile([
            document(deleted, at: position(90), isOpen: true),
            document(copy, at: position(4)),
        ], now: minutes(1))
        #expect(whileOpen == ReconcilePlan())

        let closed = ledger.reconcile([
            document(deleted, at: position(90)),
            document(copy, at: position(4)),
        ], now: minutes(2))
        #expect(closed.removals == [deleted])
        #expect(closed.positionUpdates == [copy: position(90)])
        #expect(closed.saves == [CloudRecordKey(.state, copy)])
        #expect(closed.deletes.isEmpty)
    }

    @Test func forgettingServerRecordsUploadsTheLibraryAgain() {
        let id = UUID()
        let waiting = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(3), modifiedAt: t0), contentHash: "abc")
        _ = ledger.receiveState(StampedReadingPosition(position: position(1), modifiedAt: t0), systemFields: Data([1]), for: waiting, local: nil, now: t0)

        ledger.forgetServerRecords()
        #expect(ledger.entry(for: waiting) == nil)
        #expect(ledger.entry(for: id)?.contentHash == "abc")
        let plan = ledger.reconcile([document(id, at: position(3))], now: t0)
        #expect(Set(plan.saves) == [CloudRecordKey(.book, id), CloudRecordKey(.state, id)])
        #expect(plan.deletes.isEmpty)
    }

    // MARK: - Receiving records

    @Test func remoteStateReplacesAnUnchangedPosition() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(10), modifiedAt: t0))
        let remote = StampedReadingPosition(position: position(200, wpm: 400, read: minutes(1)), modifiedAt: minutes(1))

        let shown = ledger.receiveState(remote, systemFields: Data([2]), for: id, local: (position(10), t0), now: minutes(2))
        #expect(shown == remote.position)
        #expect(ledger.entry(for: id)?.syncedState == remote)
        #expect(ledger.entry(for: id)?.localState == nil)
        let plan = ledger.reconcile([document(id, at: remote.position)], now: minutes(3))
        #expect(plan == ReconcilePlan())
    }

    @Test func unsentLocalReadingWinsOverAnOlderRemoteState() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(10), modifiedAt: t0))
        _ = ledger.reconcile([document(id, at: position(300))], now: minutes(2))

        let remote = StampedReadingPosition(position: position(50), modifiedAt: minutes(1))
        let shown = ledger.receiveState(remote, systemFields: Data([2]), for: id, local: (position(300), t0), now: minutes(3))
        #expect(shown == position(300))
        #expect(ledger.entry(for: id)?.localState?.position == position(300))
        let plan = ledger.reconcile([document(id, at: position(300))], now: minutes(4))
        #expect(plan.saves == [CloudRecordKey(.state, id)])
    }

    @Test func newerRemoteReadingKeepsTheLocalFurthestPoint() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(10), modifiedAt: t0))
        _ = ledger.reconcile([document(id, at: position(300))], now: minutes(1))

        // Another device went back to re-read, later.
        let remote = StampedReadingPosition(position: position(100), modifiedAt: minutes(2))
        let shown = ledger.receiveState(remote, systemFields: Data([2]), for: id, local: (position(300), t0), now: minutes(3))
        #expect(shown == position(100, furthest: 300))
        // Its furthest point is behind this one, so the merge goes back up.
        #expect(ledger.entry(for: id)?.localState?.position == position(100, furthest: 300))
    }

    @Test func stateThatArrivesBeforeItsBookWaitsForIt() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        let state = StampedReadingPosition(position: position(42), modifiedAt: t0)
        let shownBeforeBook = ledger.receiveState(state, systemFields: Data([1]), for: id, local: nil, now: t0)
        #expect(shownBeforeBook == nil)
        let title = ledger.receiveBook(bookFields(), systemFields: Data([1]), for: id, localTitle: nil)
        #expect(title == nil)
        #expect(ledger.entry(for: id)?.syncedState == state)
        ledger.markLocal(id)
        let plan = ledger.reconcile([document(id, at: position(42))], now: minutes(1))
        #expect(plan == ReconcilePlan())
    }

    @Test func remoteTitleDoesNotOverwriteAnUnsentRename() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(title: "Old", state: StampedReadingPosition(position: position(0), modifiedAt: t0))
        let keptRename = ledger.receiveBook(bookFields(title: "Theirs"), systemFields: Data([2]), for: id, localTitle: "Mine")
        #expect(keptRename == nil)
        let plan = ledger.reconcile([document(id, title: "Mine", at: position(0))], now: t0)
        #expect(plan.saves == [CloudRecordKey(.book, id)])

        let other = UUID()
        ledger.entries[other.uuidString] = synced(title: "Old", state: StampedReadingPosition(position: position(0), modifiedAt: t0))
        let takenTitle = ledger.receiveBook(bookFields(title: "Theirs"), systemFields: Data([2]), for: other, localTitle: "Old")
        #expect(takenTitle == "Theirs")
    }

    @Test func openingAndClosingAStaleCopyDoesNotBeatNewerReading() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(200, read: t0), modifiedAt: t0))

        // Opened and closed without moving: only the last-read date changes.
        let plan = ledger.reconcile([document(id, at: position(200, read: minutes(10)))], now: minutes(10))
        #expect(plan.saves == [CloudRecordKey(.state, id)])
        #expect(ledger.entry(for: id)?.localState?.modifiedAt == t0)

        // Reading done on another device in the meantime still wins.
        let remote = StampedReadingPosition(position: position(800, read: minutes(5)), modifiedAt: minutes(5))
        let shown = ledger.receiveState(remote, systemFields: Data([2]), for: id, local: (position(200, read: minutes(10)), t0), now: minutes(11))
        #expect(shown == position(800, read: minutes(10)))
    }

    @Test func speedChangeCountsAsNewerReading() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(200), modifiedAt: t0))
        _ = ledger.reconcile([document(id, at: position(200, wpm: 450))], now: minutes(3))
        #expect(ledger.entry(for: id)?.localState?.modifiedAt == minutes(3))
    }

    @Test func ledgerThatLostManyDocumentsIsNotTrusted() {
        var ledger = CloudSyncLedger()
        let ids = (0..<8).map { _ in UUID() }
        for id in ids {
            ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(0), modifiedAt: t0))
        }
        #expect(!ledger.hasLostTrack(ofLibraryWith: Set(ids)))
        // Two deleted: ordinary.
        #expect(!ledger.hasLostTrack(ofLibraryWith: Set(ids.dropFirst(2))))
        // Half gone at once: an older library, not deletions.
        #expect(ledger.hasLostTrack(ofLibraryWith: Set(ids.dropFirst(4))))
        #expect(ledger.hasLostTrack(ofLibraryWith: []))
    }

    @Test func documentsInICloudAreTheOnesWithConfirmedBooks() {
        let synced = UUID()
        let unsent = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[synced.uuidString] = self.synced(state: StampedReadingPosition(position: position(0), modifiedAt: t0))
        _ = ledger.reconcile([document(synced, at: position(0)), document(unsent, at: position(0))], now: t0)
        #expect(ledger.isInICloud(synced))
        #expect(!ledger.isInICloud(unsent))
    }

    // MARK: - Reading sessions

    private func session(documentID: UUID? = UUID()) -> ReadingSessionSnapshot {
        ReadingSessionSnapshot(
            id: UUID(),
            documentID: documentID,
            startedAt: t0,
            endedAt: minutes(25),
            plain: ReadingAmount(words: 4321, seconds: 900.5),
            voiced: ReadingAmount(words: 1234, seconds: 450.25)
        )
    }

    @Test func readingSessionRoundTripsThroughARecord() throws {
        for original in [session(), session(documentID: nil)] {
            let record = CKRecord(recordType: CloudSyncSchema.RecordType.session, recordID: SessionRecordKey(original.id).recordID)
            original.write(to: record)
            #expect(ReadingSessionSnapshot(record: record) == original)
            // Every field is encrypted.
            #expect(Set(record.encryptedValues.allKeys()) == Self.keys(of: record))
            #expect(Self.keys(of: record).isSubset(of: CloudSyncSchema.SessionField.all))
        }
    }

    @Test func otherRecordsAreNotSessions() {
        let original = session()
        let book = CKRecord(recordType: CloudSyncSchema.RecordType.book, recordID: SessionRecordKey(original.id).recordID)
        original.write(to: book)
        #expect(ReadingSessionSnapshot(record: book) == nil)
        let misnamed = CKRecord(recordType: CloudSyncSchema.RecordType.session, recordID: CloudRecordKey(.book, original.id).recordID)
        original.write(to: misnamed)
        #expect(ReadingSessionSnapshot(record: misnamed) == nil)
    }

    /// Only finished sessions iCloud doesn't have go, and only once a full
    /// fetch has shown which it has, and not while its storage is full.
    @Test func sessionsUploadOnceEachAfterAFullFetch() {
        let sent = UUID(), unsent = UUID()
        var ledger = CloudSyncLedger()
        #expect(ledger.sessionsToUpload(finished: [sent, unsent], now: t0).isEmpty)

        ledger.hasFetchedEverything = true
        #expect(ledger.sessionsToUpload(finished: [sent, unsent], now: t0) == [sent, unsent])
        ledger.confirmSession(sent)
        #expect(ledger.isSessionInICloud(sent))
        #expect(ledger.sessionsToUpload(finished: [sent, unsent], now: t0) == [unsent])

        ledger.storagePause = CloudSyncLedger.StoragePause(until: minutes(15), failures: 1, holdsUpdates: false)
        #expect(ledger.sessionsToUpload(finished: [unsent], now: t0).isEmpty)
        #expect(ledger.sessionsToUpload(finished: [unsent], now: minutes(16)) == [unsent])
    }

    /// A session iCloud lost goes again, and so does every one after iCloud
    /// lost the zone.
    @Test func sessionsICloudLostAreSentAgain() {
        let first = UUID(), second = UUID()
        var ledger = CloudSyncLedger()
        ledger.hasFetchedEverything = true
        ledger.confirmSession(first)
        ledger.confirmSession(second)
        ledger.forgetSession(first)
        #expect(ledger.sessionsToUpload(finished: [first, second], now: t0) == [first])

        ledger.confirmSession(first)
        ledger.forgetServerRecords()
        #expect(ledger.sessionsToUpload(finished: [first, second], now: t0) == [first, second])
    }

    /// Starting over forgets which sessions iCloud has; the next full fetch
    /// marks them again.
    @Test func startingOverForgetsSessions() {
        var ledger = CloudSyncLedger()
        ledger.confirmSession(UUID())
        ledger.hasFetchedSessions = true
        let fresh = ledger.startingOver()
        #expect(fresh.sessionsInICloud == nil)
        #expect(fresh.hasFetchedSessions == nil)
    }

    // MARK: - Schema

    private static func keys(of record: CKRecord) -> Set<String> {
        Set(record.allKeys()).union(record.encryptedValues.allKeys())
    }

    @Test func schemaSeedSetsEveryField() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "CloudSyncTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = try CloudSchemaSeed.records(assetDirectory: directory)
        let book = try #require(records.first { $0.recordType == CloudSyncSchema.RecordType.book })
        let state = try #require(records.first { $0.recordType == CloudSyncSchema.RecordType.readingState })
        let session = try #require(records.first { $0.recordType == CloudSyncSchema.RecordType.session })

        #expect(Self.keys(of: book) == Set(CloudSyncSchema.BookField.all))
        #expect(Self.keys(of: state) == Set(CloudSyncSchema.StateField.all))
        #expect(Self.keys(of: session) == Set(CloudSyncSchema.SessionField.all))
        #expect(BookRecordFields(record: book) != nil)
        #expect(StampedReadingPosition(record: state) != nil)
        // Never mistaken for library records.
        #expect(records.allSatisfy { CloudRecordKey(recordID: $0.recordID) == nil })
        #expect(records.allSatisfy { SessionRecordKey(recordID: $0.recordID) == nil })
    }

    @Test func syncWritesOnlyFieldsTheSchemaDeclares() {
        let id = UUID()
        let book = CKRecord(recordType: CloudSyncSchema.RecordType.book, recordID: CloudRecordKey(.book, id).recordID)
        bookFields().write(to: book)
        #expect(Self.keys(of: book).isSubset(of: CloudSyncSchema.BookField.all))

        let state = CKRecord(recordType: CloudSyncSchema.RecordType.readingState, recordID: CloudRecordKey(.state, id).recordID)
        StampedReadingPosition(position: position(3, read: t0), modifiedAt: t0).write(to: state)
        #expect(Self.keys(of: state).isSubset(of: CloudSyncSchema.StateField.all))
    }

    // MARK: - Ledger file

    @Test func ledgerRoundTripsThroughItsFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "CloudSyncTests-\(UUID().uuidString)/Ledger.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.storeIdentifier = "store"
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(9, read: t0), modifiedAt: t0), contentHash: "abc")
        ledger.pendingDeletes = [UUID().uuidString]
        ledger.hasFetchedEverything = true
        try ledger.save(to: url)

        let loaded = CloudSyncLedger.load(from: url)
        #expect(loaded.storeIdentifier == "store")
        #expect(loaded.entries == ledger.entries)
        #expect(loaded.pendingDeletes == ledger.pendingDeletes)
        #expect(loaded.hasFetchedEverything)
        // From before sessions synced: none known, and not fetched yet.
        #expect(loaded.sessionsInICloud == nil)
        #expect(loaded.hasFetchedSessions == nil)
    }

    @Test func sessionsSurviveTheLedgerFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "CloudSyncTests-\(UUID().uuidString)/Ledger.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.confirmSession(id)
        ledger.hasFetchedSessions = true
        try ledger.save(to: url)

        let loaded = CloudSyncLedger.load(from: url)
        #expect(loaded.isSessionInICloud(id))
        #expect(loaded.hasFetchedSessions == true)
    }

    @Test func unreadableLedgerStartsEmptyAndIsSetAside() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "CloudSyncTests-\(UUID().uuidString)/Ledger.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a ledger".utf8).write(to: url)

        let loaded = CloudSyncLedger.load(from: url)
        #expect(loaded.entries.isEmpty)
        #expect(loaded.pendingDeletes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable").path(percentEncoded: false)))
    }
}
