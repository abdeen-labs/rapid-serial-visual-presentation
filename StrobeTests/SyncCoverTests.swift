import CloudKit
import CoreGraphics
import Foundation
import Testing
@testable import Strobe

/// A cover changed after import: sending it, taking it in, both devices
/// changing it, a copy folding into the book that stays, and ledgers and
/// records from before covers could change.
struct SyncCoverTests {

    private let t0 = Date(timeIntervalSince1970: 1_788_220_800) // 2026-09-01 00:00 UTC

    // IDs in a known order: a < b.
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    private var book: CloudRecordKey { CloudRecordKey(.book, a) }

    private var position: ReadingPosition {
        ReadingPosition(currentWordIndex: 0, furthestWordIndex: 0, wordsPerMinute: 300, lastReadDate: nil)
    }

    /// A ledger past its first full fetch, with `a` in iCloud and its cover
    /// there `syncedCover`: nil for an entry from a build before covers
    /// synced.
    private func makeLedger(syncedCover: String?) -> CloudSyncLedger {
        var ledger = CloudSyncLedger()
        ledger.hasFetchedEverything = true
        ledger.entries[a.uuidString] = CloudSyncLedger.Entry(
            hasLocalDocument: true,
            bookSystemFields: Data([1]),
            stateSystemFields: Data([1]),
            syncedTitle: "Book",
            syncedState: StampedReadingPosition(position: position, modifiedAt: t0),
            contentHash: "hash",
            origin: .importedHere,
            bookCreatedAt: t0,
            syncedCover: syncedCover
        )
        return ledger
    }

    private func document(_ id: UUID? = nil, cover: String?) -> LocalDocumentSnapshot {
        LocalDocumentSnapshot(id: id ?? a, title: "Book", position: position, dateAdded: t0, coverFingerprint: cover)
    }

    private func bookFields(cover: String?) -> BookRecordFields {
        let words = ["Call", "me", "Ishmael."]
        return BookRecordFields(
            title: "Book",
            fileName: "moby.epub",
            dateAdded: t0,
            wordCount: words.count,
            chapters: [],
            contentHash: ContentFingerprint.of(WordStorage.encode(words)),
            coverFingerprint: cover
        )
    }

    private static func jpeg(width: Int = 60, height: Int = 90, gray: Double = 0.4) throws -> Data {
        let context = try #require(CoverImage.makeContext(size: CGSize(width: width, height: height)))
        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return try #require(CoverImage.jpegData(image))
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "SyncCoverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Sending

    @Test func changedCoverQueuesABookSave() {
        var ledger = makeLedger(syncedCover: "old")
        let plan = ledger.reconcile([document(cover: "new")], now: t0)
        #expect(plan.saves == [book])
        #expect(ledger.coverChanged(a, coverFingerprint: "new"))
    }

    @Test func coverAddedToABookWithoutOneQueuesABookSave() {
        var ledger = makeLedger(syncedCover: SyncedCover.noCover)
        #expect(ledger.reconcile([document(cover: "new")], now: t0).saves == [book])
    }

    @Test func unchangedCoverQueuesNothing() {
        var ledger = makeLedger(syncedCover: "same")
        #expect(ledger.reconcile([document(cover: "same")], now: t0) == ReconcilePlan())

        var without = makeLedger(syncedCover: SyncedCover.noCover)
        #expect(without.reconcile([document(cover: nil)], now: t0) == ReconcilePlan())
    }

    @Test func removedCoverIsSentAsARemoval() throws {
        var ledger = makeLedger(syncedCover: "old")
        #expect(ledger.reconcile([document(cover: nil)], now: t0).saves == [book])

        // The record iCloud has, with its cover.
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coverURL = directory.appending(path: "cover")
        try Self.jpeg().write(to: coverURL)
        let server = CKRecord(recordType: CloudSyncSchema.RecordType.book, recordID: book.recordID)
        bookFields(cover: "old").write(to: server)
        server[CloudSyncSchema.BookField.coverImage] = CKAsset(fileURL: coverURL)

        // What sync sends: the record's system fields, and only the keys it sets.
        let record = try #require(CloudRecordArchive.record(fromSystemFields: CloudRecordArchive.systemFields(of: server)))
        record.encryptedValues[CloudSyncSchema.BookField.title] = "Book"
        BookRecordFields.writeCover(nil, asset: nil, to: record)
        #expect(record.object(forKey: CloudSyncSchema.BookField.coverImage) == nil)
        #expect(BookRecordFields.coverFingerprint(in: record) == SyncedCover.noCover)
        // The asset's key goes too, so iCloud drops it.
        #expect(record.changedKeys().contains(CloudSyncSchema.BookField.coverImage))
        let sent: Set<String> = [
            CloudSyncSchema.BookField.title, CloudSyncSchema.BookField.coverImage,
            CloudSyncSchema.BookField.coverFingerprint,
        ]
        #expect(Set(record.changedKeys()).isSubset(of: sent))

        ledger.confirmSaved(book, systemFields: Data([2]), title: "Book", state: nil, cover: SyncedCover.noCover)
        #expect(ledger.reconcile([document(cover: nil)], now: t0) == ReconcilePlan())
    }

    @Test func aReplacedCoverIsWrittenWithItsFingerprint() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coverURL = directory.appending(path: "cover")
        try Self.jpeg().write(to: coverURL)
        let record = CKRecord(recordType: CloudSyncSchema.RecordType.book, recordID: book.recordID)
        BookRecordFields.writeCover("new", asset: CKAsset(fileURL: coverURL), to: record)
        #expect((record[CloudSyncSchema.BookField.coverImage] as? CKAsset)?.fileURL == coverURL)
        #expect(BookRecordFields.coverFingerprint(in: record) == "new")
    }

    @Test func aRenameAloneSendsNoCover() {
        var ledger = makeLedger(syncedCover: "same")
        let plan = ledger.reconcile([LocalDocumentSnapshot(id: a, title: "Renamed", position: position, dateAdded: t0, coverFingerprint: "same")], now: t0)
        #expect(plan.saves == [book])
        #expect(!ledger.coverChanged(a, coverFingerprint: "same"))
    }

    @Test func aConfirmedSaveRemembersItsCover() {
        var ledger = CloudSyncLedger()
        ledger.hasFetchedEverything = true
        // A first upload: imported here, not yet in iCloud.
        let plan = ledger.reconcile([document(cover: "art")], now: t0)
        #expect(plan.saves.contains(book))
        #expect(ledger.entry(for: a)?.syncedCover == nil)
        ledger.confirmSaved(book, systemFields: Data([1]), title: "Book", state: nil, cover: "art")
        #expect(ledger.entry(for: a)?.syncedCover == "art")
        #expect(!ledger.coverChanged(a, coverFingerprint: "art"))

        // A save whose record doesn't carry the cover leaves it as it was.
        ledger.confirmSaved(book, systemFields: Data([2]), title: "Renamed", state: nil)
        #expect(ledger.entry(for: a)?.syncedCover == "art")

        // Gone from iCloud: everything is sent again.
        ledger.forgetServerRecord(book)
        #expect(ledger.entry(for: a)?.syncedCover == nil)
    }

    // MARK: - Before covers could change

    /// An entry from an earlier build counts iCloud's cover as none. No
    /// build before covers kept one, so a first launch sends nothing.
    @Test func olderEntryWithoutALocalCoverQueuesNothing() {
        var ledger = makeLedger(syncedCover: nil)
        #expect(ledger.reconcile([document(cover: nil)], now: t0) == ReconcilePlan())
        #expect(ledger.entry(for: a)?.syncedCover == SyncedCover.noCover)
    }

    /// A cover set here since (while sync was off, say) is sent.
    @Test func olderEntryWithALocalCoverQueuesABookSave() {
        var ledger = makeLedger(syncedCover: nil)
        #expect(ledger.reconcile([document(cover: "art")], now: t0).saves == [book])
        #expect(ledger.entry(for: a)?.syncedCover == SyncedCover.noCover)
        #expect(ledger.coverChanged(a, coverFingerprint: "art"))
    }

    /// A book not yet in iCloud remembers no cover until its upload is
    /// confirmed.
    @Test func bookNotYetInICloudRemembersNoCover() {
        var ledger = CloudSyncLedger()
        ledger.hasFetchedEverything = true
        _ = ledger.reconcile([document(cover: "art")], now: t0)
        #expect(ledger.entry(for: a)?.syncedCover == nil)
    }

    @Test func ledgerFromBeforeCoversLoads() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SyncCoverTests-\(UUID().uuidString)/Ledger.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // An unknown cover isn't written, as in a ledger saved before it existed.
        try makeLedger(syncedCover: nil).save(to: url)
        #expect(CloudSyncLedger.load(from: url).entry(for: a)?.syncedCover == nil)
        #expect(CloudSyncLedger.load(from: url).entry(for: a)?.bookSystemFields == Data([1]))

        try makeLedger(syncedCover: "art").save(to: url)
        #expect(CloudSyncLedger.load(from: url).entry(for: a)?.syncedCover == "art")
    }

    /// A record written before covers could change says nothing about the
    /// cover: nothing is taken, and the ledger keeps what it knew.
    @Test func recordWithoutAFingerprintChangesNothing() {
        var ledger = makeLedger(syncedCover: "old")
        let took1 = ledger.receiveCover(nil, for: a, localCover: "mine")
        #expect(!took1)
        #expect(ledger.entry(for: a)?.syncedCover == "old")
        // The change here still goes.
        #expect(ledger.reconcile([document(cover: "mine")], now: t0).saves == [book])

        var unknown = makeLedger(syncedCover: nil)
        let took2 = unknown.receiveCover(nil, for: a, localCover: nil)
        #expect(!took2)
        #expect(unknown.entry(for: a)?.syncedCover == nil)
    }

    // MARK: - Taking it in

    @Test func remoteChangeIsTakenWhenNothingChangedHere() {
        var ledger = makeLedger(syncedCover: "old")
        let took3 = ledger.receiveCover("theirs", for: a, localCover: "old")
        #expect(took3)
        // Recorded once it's taken.
        #expect(ledger.entry(for: a)?.syncedCover == "old")
        ledger.coverTaken("theirs", for: a)
        #expect(ledger.reconcile([document(cover: "theirs")], now: t0) == ReconcilePlan())

        // Removed in iCloud, and added to a book that had none.
        #expect(makeLedger(syncedCover: "old").takesCover(SyncedCover.noCover, for: a, localCover: "old"))
        #expect(makeLedger(syncedCover: SyncedCover.noCover).takesCover("theirs", for: a, localCover: nil))
        // The same cover: nothing to take, and it's iCloud's.
        var same = makeLedger(syncedCover: "old")
        let took4 = same.receiveCover("theirs", for: a, localCover: "theirs")
        #expect(!took4)
        #expect(same.entry(for: a)?.syncedCover == "theirs")
    }

    /// A cover from iCloud that can't be read is never taken, and nothing
    /// here is sent over it.
    @Test func unreadableRemoteCoverLeavesBothSides() {
        var ledger = makeLedger(syncedCover: "old")
        let took5 = ledger.receiveCover("theirs", for: a, localCover: "old")
        #expect(took5)
        // Not taken: no `coverTaken`.
        #expect(ledger.reconcile([document(cover: "old")], now: t0) == ReconcilePlan())
    }

    @Test func localChangeWaitingToBeSentWins() {
        var ledger = makeLedger(syncedCover: "old")
        let took6 = ledger.receiveCover("theirs", for: a, localCover: "mine")
        #expect(!took6)
        #expect(ledger.entry(for: a)?.syncedCover == "theirs")
        #expect(ledger.reconcile([document(cover: "mine")], now: t0).saves == [book])

        // A removal made here wins too.
        var removed = makeLedger(syncedCover: "old")
        let took7 = removed.receiveCover("theirs", for: a, localCover: nil)
        #expect(!took7)
        #expect(removed.reconcile([document(cover: nil)], now: t0).saves == [book])

        // Changed back here to the cover iCloud had: iCloud's new one is
        // compared with it, so that's sent too.
        var reverted = makeLedger(syncedCover: "old")
        _ = reverted.receiveCover("theirs", for: a, localCover: "mine")
        #expect(reverted.reconcile([document(cover: "old")], now: t0).saves == [book])
    }

    /// Both devices changed the cover: each keeps its own until iCloud
    /// takes one, and the save iCloud accepts last wins everywhere. Device
    /// A's save lands first; B's conflicts, B keeps its cover and sends it
    /// again, and A takes it.
    @Test func whenBothChangeTheLastSaveWins() {
        var deviceA = makeLedger(syncedCover: "old")
        var deviceB = makeLedger(syncedCover: "old")

        deviceA.confirmSaved(book, systemFields: Data([2]), title: "Book", state: nil, cover: "fromA")
        let took8 = deviceB.receiveCover("fromA", for: a, localCover: "fromB")
        #expect(!took8)
        #expect(deviceB.reconcile([document(cover: "fromB")], now: t0).saves == [book])
        deviceB.confirmSaved(book, systemFields: Data([3]), title: "Book", state: nil, cover: "fromB")

        let took9 = deviceA.receiveCover("fromB", for: a, localCover: "fromA")
        #expect(took9)
        deviceA.coverTaken("fromB", for: a)
        #expect(deviceA.reconcile([document(cover: "fromB")], now: t0) == ReconcilePlan())
        #expect(deviceB.reconcile([document(cover: "fromB")], now: t0) == ReconcilePlan())
    }

    /// With no cover remembered (a ledger that started over, before its
    /// first reconcile), nothing here counts as changed, so iCloud's is
    /// taken, as titles are.
    @Test func unknownICloudCoverTakesTheRecordsCover() {
        let ledger = makeLedger(syncedCover: nil)
        #expect(ledger.takesCover("theirs", for: a, localCover: "mine"))
        #expect(!ledger.takesCover("mine", for: a, localCover: "mine"))
        #expect(!ledger.takesCover(nil, for: a, localCover: "mine"))
    }

    @Test func downloadedCoverMustMatchItsRecord() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cover = try Self.jpeg()
        let url = directory.appending(path: "cover")
        try cover.write(to: url)
        let fingerprint = ContentFingerprint.of(cover)

        #expect(BookContent.loadCover(at: url, recordedAs: fingerprint) == cover)
        // A record from before covers could change.
        #expect(BookContent.loadCover(at: url, recordedAs: nil) == cover)
        // A record that says there's no cover, whatever asset it keeps.
        #expect(BookContent.loadCover(at: url, recordedAs: SyncedCover.noCover) == nil)
        #expect(BookContent.loadCover(at: url, recordedAs: ContentFingerprint.of(try Self.jpeg(gray: 0.8))) == nil)
        #expect(BookContent.loadCover(at: nil, recordedAs: fingerprint) == nil)

        // A new book takes the cover only as its record describes it.
        let words = WordStorage.encode(["Call", "me", "Ishmael."])
        let wordsURL = directory.appending(path: "words")
        try words.write(to: wordsURL)
        let loaded = BookContent.load(wordsURL: wordsURL, complexityURL: nil, coverImageURL: url, fields: bookFields(cover: fingerprint))
        #expect(loaded?.coverImage == cover)
        let removed = BookContent.load(wordsURL: wordsURL, complexityURL: nil, coverImageURL: url, fields: bookFields(cover: SyncedCover.noCover))
        #expect(removed != nil)
        #expect(removed?.coverImage == nil)
    }

    // MARK: - Records and schema

    @Test func coverFingerprintRoundTripsThroughARecord() {
        for cover in ["abc123", SyncedCover.noCover, nil] {
            let record = CKRecord(recordType: CloudSyncSchema.RecordType.book, recordID: book.recordID)
            let fields = bookFields(cover: cover)
            fields.write(to: record)
            #expect(BookRecordFields(record: record) == fields)
            #expect(BookRecordFields(record: record)?.coverFingerprint == cover)
            #expect(BookRecordFields.coverFingerprint(in: record) == cover)
        }
    }

    @Test func schemaSeedSetsTheCoverFingerprint() throws {
        #expect(CloudSyncSchema.BookField.all.contains(CloudSyncSchema.BookField.coverFingerprint))
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = try CloudSchemaSeed.records(assetDirectory: directory)
        let seed = try #require(records.first { $0.recordType == CloudSyncSchema.RecordType.book })
        let fingerprint = try #require(BookRecordFields(record: seed)?.coverFingerprint)
        let coverURL = try #require((seed[CloudSyncSchema.BookField.coverImage] as? CKAsset)?.fileURL)
        #expect(fingerprint == ContentFingerprint.of(try Data(contentsOf: coverURL)))
    }

    // MARK: - Catching up after an older build

    @Test func olderLedgerNeedsTheCoverCatchUpOnce() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SyncCoverTests-\(UUID().uuidString)/Ledger.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // As saved by a build before covers synced: no flag.
        try makeLedger(syncedCover: nil).save(to: url)
        var loaded = CloudSyncLedger.load(from: url)
        #expect(loaded.hasFetchedCovers == nil)
        #expect(loaded.needsCoverCatchUp)

        loaded.hasFetchedCovers = true
        try loaded.save(to: url)
        #expect(!CloudSyncLedger.load(from: url).needsCoverCatchUp)

        // Not before a full fetch, and not again for a ledger starting over,
        // whose engine fetches whole records (`LibrarySync.startEngine`
        // marks it).
        var unfetched = CloudSyncLedger()
        #expect(!unfetched.needsCoverCatchUp)
        unfetched.hasFetchedEverything = true
        #expect(unfetched.needsCoverCatchUp)
        #expect(loaded.startingOver().hasFetchedCovers == nil)
        #expect(!loaded.startingOver().hasFetchedEverything)
    }

    @Test func catchUpReadsOnlyBookCovers() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cover = try Self.jpeg()
        let coverURL = directory.appending(path: "cover")
        try cover.write(to: coverURL)

        let record = CKRecord(recordType: CloudSyncSchema.RecordType.book, recordID: book.recordID)
        BookRecordFields.writeCover("art", asset: CKAsset(fileURL: coverURL), to: record)
        let fetched = try #require(FetchedCover(record: record))
        #expect(fetched.documentID == a)
        #expect(fetched.fingerprint == "art")
        #expect(fetched.fileURL == coverURL)
        #expect(fetched.byteCount == cover.count)

        let removed = CKRecord(recordType: CloudSyncSchema.RecordType.book, recordID: book.recordID)
        BookRecordFields.writeCover(nil, asset: nil, to: removed)
        #expect(FetchedCover(record: removed) == FetchedCover(documentID: a, fingerprint: SyncedCover.noCover, fileURL: nil, byteCount: 0))

        // A record that doesn't say, and records that aren't books.
        let silent = CKRecord(recordType: CloudSyncSchema.RecordType.book, recordID: book.recordID)
        bookFields(cover: nil).write(to: silent)
        #expect(FetchedCover(record: silent) == nil)
        let state = CKRecord(recordType: CloudSyncSchema.RecordType.readingState, recordID: CloudRecordKey(.state, a).recordID)
        state.encryptedValues[CloudSyncSchema.BookField.coverFingerprint] = "art"
        #expect(FetchedCover(record: state) == nil)
    }

    private func fetched(_ id: UUID, _ fingerprint: String) -> FetchedCover {
        FetchedCover(documentID: id, fingerprint: fingerprint, fileURL: nil, byteCount: 100)
    }

    /// The catch-up takes covers in as a fetched change does: a cover
    /// changed here and waiting wins, the same cover is recorded, and books
    /// not here, leaving, or not in iCloud are passed over.
    @Test func catchUpTakesCoversInLikeAFetchedChange() {
        let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
        let d = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!
        let e = UUID(uuidString: "00000000-0000-0000-0000-00000000000E")!
        var ledger = makeLedger(syncedCover: SyncedCover.noCover)
        // b: in iCloud with a cover changed here, waiting to be sent.
        ledger.entries[b.uuidString] = ledger.entries[a.uuidString]
        // c: in iCloud, the same cover here.
        ledger.entries[c.uuidString] = ledger.entries[a.uuidString]
        // d: leaving. e: not in iCloud yet.
        ledger.entries[d.uuidString] = ledger.entries[a.uuidString]
        ledger.entries[d.uuidString]?.removal = .deletedElsewhere(foldInto: nil)
        ledger.entries[e.uuidString] = CloudSyncLedger.Entry(hasLocalDocument: true, origin: .importedHere)
        let stranger = UUID()

        let covers = [fetched(a, "art"), fetched(b, "art"), fetched(c, "same"), fetched(d, "art"), fetched(e, "art"), fetched(stranger, "art")]
        let localCovers = [
            a: SyncedCover.noCover, b: "mine", c: "same", d: SyncedCover.noCover, e: SyncedCover.noCover,
        ]
        let toTake = ledger.receiveCaughtUpCovers(covers, localCovers: localCovers)
        #expect(toTake == [fetched(a, "art")])
        // Recorded once taken.
        #expect(ledger.entry(for: a)?.syncedCover == SyncedCover.noCover)
        // b's own cover is compared with iCloud's now, and sent.
        #expect(ledger.entry(for: b)?.syncedCover == "art")
        #expect(ledger.coverChanged(b, coverFingerprint: "mine"))
        #expect(ledger.entry(for: c)?.syncedCover == "same")
        #expect(ledger.entry(for: d)?.syncedCover == SyncedCover.noCover)
        #expect(ledger.entry(for: e)?.syncedCover == nil)
        #expect(ledger.entry(for: stranger) == nil)

        // Run again after taking a's: nothing left to take.
        ledger.coverTaken("art", for: a)
        let again = ledger.receiveCaughtUpCovers(covers, localCovers: localCovers.merging([a: "art"]) { _, new in new })
        #expect(again.isEmpty)
    }

    @Test func catchUpTakesARemovalFromICloud() {
        var ledger = makeLedger(syncedCover: "old")
        let toTake = ledger.receiveCaughtUpCovers([fetched(a, SyncedCover.noCover)], localCovers: [a: "old"])
        #expect(toTake == [fetched(a, SyncedCover.noCover)])
    }

    // MARK: - Copies folding into a book in iCloud

    /// A copy never uploaded that folds into the identical book in iCloud
    /// hands its cover over when that book has none, and the book sends it.
    @Test func mergedCopyHandsItsCoverToTheBookThatStays() {
        var ledger = makeLedger(syncedCover: SyncedCover.noCover)
        ledger.markMerged(b, into: a)
        let plan = ledger.reconcile([document(a, cover: nil), document(b, cover: "art")], now: t0)
        #expect(plan.removals == [b])
        #expect(plan.coverHandoffs == [a: b])
        #expect(plan.saves == [book])

        // Once it has the cover, it's sent until iCloud confirms it.
        #expect(ledger.reconcile([document(a, cover: "art")], now: t0).saves == [book])
    }

    @Test func mergedCopyLeavesABookWithItsOwnCover() {
        var ledger = makeLedger(syncedCover: "own")
        ledger.markMerged(b, into: a)
        let plan = ledger.reconcile([document(a, cover: "own"), document(b, cover: "art")], now: t0)
        #expect(plan.removals == [b])
        #expect(plan.coverHandoffs.isEmpty)
        #expect(plan.saves.isEmpty)

        // A copy without a cover hands nothing over.
        var plain = makeLedger(syncedCover: SyncedCover.noCover)
        plain.markMerged(b, into: a)
        #expect(plain.reconcile([document(a, cover: nil), document(b, cover: nil)], now: t0).coverHandoffs.isEmpty)
    }
}
