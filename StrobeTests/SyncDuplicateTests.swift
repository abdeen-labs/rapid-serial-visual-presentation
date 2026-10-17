import Foundation
import Testing
@testable import Strobe

/// Identical copies of a book that reached iCloud from two devices: which
/// device imported what, which copy stays, and what never merges.
struct SyncDuplicateTests {
    private typealias Origin = CloudSyncLedger.Entry.Origin

    private let t0 = Date(timeIntervalSince1970: 1_788_220_800) // 2026-09-01 00:00 UTC

    // IDs in a known order: a < b < c.
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    private func minutes(_ count: Double) -> Date {
        t0.addingTimeInterval(count * 60)
    }

    private func position(_ current: Int, read: Date? = nil) -> ReadingPosition {
        ReadingPosition(currentWordIndex: current, furthestWordIndex: current, wordsPerMinute: 300, lastReadDate: read)
    }

    /// A copy of the book in iCloud, as one device's library has it.
    private struct Copy {
        var id: UUID
        var origin: Origin?
        var added: Date
        var uploaded: Date
        var title = "Moby-Dick"
        var position = ReadingPosition(currentWordIndex: 0, furthestWordIndex: 0, wordsPerMinute: 300, lastReadDate: nil)
        var isOpen = false
    }

    /// A ledger past its first full fetch whose library holds `copies`,
    /// all in iCloud with the same words.
    private func makeLedger(for copies: [Copy]) -> CloudSyncLedger {
        var ledger = CloudSyncLedger()
        ledger.hasFetchedEverything = true
        for copy in copies {
            ledger.entries[copy.id.uuidString] = CloudSyncLedger.Entry(
                hasLocalDocument: true,
                bookSystemFields: Data([1]),
                stateSystemFields: Data([1]),
                syncedTitle: copy.title,
                syncedState: StampedReadingPosition(position: copy.position, modifiedAt: copy.position.lastReadDate ?? copy.added),
                contentHash: "moby",
                origin: copy.origin,
                bookCreatedAt: copy.uploaded
            )
        }
        return ledger
    }

    private func documents(_ copies: [Copy]) -> [LocalDocumentSnapshot] {
        copies.map {
            LocalDocumentSnapshot(id: $0.id, title: $0.title, position: $0.position, dateAdded: $0.added, isOpen: $0.isOpen)
        }
    }

    private func records(of id: UUID) -> [CloudRecordKey] {
        [CloudRecordKey(.book, id), CloudRecordKey(.state, id)]
    }

    private func bookFields() -> BookRecordFields {
        let words = ["Call", "me", "Ishmael."]
        return BookRecordFields(
            title: "Moby-Dick",
            fileName: "moby.epub",
            dateAdded: t0,
            wordCount: words.count,
            chapters: [],
            contentHash: ContentFingerprint.of(WordStorage.encode(words))
        )
    }

    /// The origins of `a` and `b` as device A sees them, then as device B does.
    private let bothSides: [(Origin, Origin)] = [(.importedHere, .fromICloud), (.fromICloud, .importedHere)]

    /// `a` imported on device A at 0 min and uploaded at 10; `b` imported
    /// on device B at 1 min and uploaded at 11. Neither device had the
    /// other's copy when it imported its own.
    private func pair(aOrigin: Origin, bOrigin: Origin) -> [Copy] {
        [
            Copy(id: a, origin: aOrigin, added: t0, uploaded: minutes(10)),
            Copy(id: b, origin: bOrigin, added: minutes(1), uploaded: minutes(11)),
        ]
    }

    // MARK: - Which copy stays

    @Test func bothDevicesKeepTheCopyWithTheSmallerID() {
        let read = position(80, read: minutes(12))
        for origins in bothSides {
            var copies = pair(aOrigin: origins.0, bOrigin: origins.1)
            copies[1].position = read
            var ledger = makeLedger(for: copies)

            let plan = ledger.reconcile(documents(copies), now: minutes(20))
            #expect(plan.removals == [b])
            // Its records are in iCloud, so the deletion is sent.
            #expect(plan.deletes == records(of: b))
            // The copy that stays takes its reading and sends it.
            #expect(plan.positionUpdates == [a: read])
            #expect(plan.saves == [CloudRecordKey(.state, a)])
            #expect(ledger.entry(for: b) == nil)
            #expect(ledger.entry(for: a)?.removal == nil)
        }
    }

    @Test func deviceThatImportedNeitherLeavesThePairAlone() {
        let copies = pair(aOrigin: .fromICloud, bOrigin: .fromICloud)
        var ledger = makeLedger(for: copies)
        let plan = ledger.reconcile(documents(copies), now: minutes(20))
        #expect(plan.removals.isEmpty)
        #expect(plan.deletes.isEmpty)
        #expect(ledger.entry(for: b)?.removal == nil)
    }

    @Test func copiesImportedTwiceOnOneDeviceStay() {
        let copies = pair(aOrigin: .importedHere, bOrigin: .importedHere)
        var ledger = makeLedger(for: copies)
        let plan = ledger.reconcile(documents(copies), now: minutes(20))
        #expect(plan.removals.isEmpty)
        #expect(plan.deletes.isEmpty)

        // Nor does another device's copy change that.
        let three = copies + [Copy(id: c, origin: .fromICloud, added: minutes(2), uploaded: minutes(12))]
        var withThird = makeLedger(for: three)
        #expect(withThird.reconcile(documents(three), now: minutes(20)).removals.isEmpty)
    }

    @Test func copyImportedAfterTheOtherReachedICloudStays() {
        // b was imported at 30 min, with a in iCloud since 10: next to it on
        // purpose, as far as sync can tell.
        for origins in bothSides {
            let copies = [
                Copy(id: a, origin: origins.0, added: t0, uploaded: minutes(10)),
                Copy(id: b, origin: origins.1, added: minutes(30), uploaded: minutes(31)),
            ]
            var ledger = makeLedger(for: copies)
            let plan = ledger.reconcile(documents(copies), now: minutes(40))
            #expect(plan.removals.isEmpty)
            #expect(plan.deletes.isEmpty)
        }
    }

    @Test func copyOfUnknownOriginHoldsItsTitleBack() {
        // From a ledger written before origins were kept, or a book already
        // in iCloud when this ledger started.
        var copies = pair(aOrigin: .importedHere, bOrigin: .fromICloud)
        copies.append(Copy(id: c, origin: nil, added: minutes(2), uploaded: minutes(12)))
        var ledger = makeLedger(for: copies)
        #expect(ledger.reconcile(documents(copies), now: minutes(20)).removals.isEmpty)

        var unknownPair = pair(aOrigin: .importedHere, bOrigin: .fromICloud)
        unknownPair[1].origin = nil
        var other = makeLedger(for: unknownPair)
        #expect(other.reconcile(documents(unknownPair), now: minutes(20)).removals.isEmpty)
    }

    @Test func copyStillUploadingHereHoldsThePairBack() {
        let copies = pair(aOrigin: .importedHere, bOrigin: .fromICloud)
        var ledger = makeLedger(for: copies)
        // A second copy imported here, on purpose, not in iCloud yet.
        ledger.entries[c.uuidString] = CloudSyncLedger.Entry(hasLocalDocument: true, contentHash: "moby", origin: .importedHere)
        let all = documents(copies + [Copy(id: c, origin: .importedHere, added: minutes(2), uploaded: minutes(12))])

        let uploading = ledger.reconcile(all, now: minutes(20))
        #expect(uploading.removals.isEmpty)
        #expect(uploading.saves.contains(CloudRecordKey(.book, c)))

        // Once it's there, two copies were imported here: they all stay.
        ledger.entries[c.uuidString]?.bookSystemFields = Data([1])
        ledger.entries[c.uuidString]?.bookCreatedAt = minutes(12)
        #expect(ledger.reconcile(all, now: minutes(21)).removals.isEmpty)
    }

    @Test func differentTitlesAreNotDuplicates() {
        // Renamed on one device.
        var copies = pair(aOrigin: .importedHere, bOrigin: .fromICloud)
        copies[1].title = "Moby-Dick (annotated)"
        var ledger = makeLedger(for: copies)
        #expect(ledger.reconcile(documents(copies), now: minutes(20)).removals.isEmpty)
    }

    @Test func nothingMergesBeforeAFullFetch() {
        let copies = pair(aOrigin: .importedHere, bOrigin: .fromICloud)
        var ledger = makeLedger(for: copies)
        ledger.hasFetchedEverything = false
        let plan = ledger.reconcile(documents(copies), now: minutes(20))
        #expect(plan.removals.isEmpty)
        #expect(ledger.entry(for: b)?.removal == nil)
    }

    // MARK: - Three or more copies

    @Test func threeDevicesEachRemoveTheirOwnCopy() {
        // a, b, and c imported on devices A, B, and C before any reached iCloud.
        func copies(importedHere own: UUID) -> [Copy] {
            [(a, 0.0), (b, 1.0), (c, 2.0)].map { id, minute in
                let origin: Origin = id == own ? .importedHere : .fromICloud
                return Copy(id: id, origin: origin, added: minutes(minute), uploaded: minutes(10 + minute))
            }
        }

        var onA = makeLedger(for: copies(importedHere: a))
        #expect(onA.reconcile(documents(copies(importedHere: a)), now: minutes(20)).removals.isEmpty)

        var onB = makeLedger(for: copies(importedHere: b))
        let planB = onB.reconcile(documents(copies(importedHere: b)), now: minutes(20))
        #expect(planB.removals == [b])
        #expect(planB.deletes == records(of: b))
        // Two from elsewhere may be one device's two copies: B leaves c to C.
        #expect(onB.entry(for: c)?.removal == nil)

        var onC = makeLedger(for: copies(importedHere: c))
        #expect(onC.reconcile(documents(copies(importedHere: c)), now: minutes(20)).removals == [c])

        // Once b's deletion reaches A, the pair left is A's to settle too.
        let afterB = copies(importedHere: a).filter { $0.id != b }
        var later = makeLedger(for: afterB)
        #expect(later.reconcile(documents(afterB), now: minutes(30)).removals == [c])
    }

    @Test func copiesImportedTwiceOnAnotherDeviceAreLeftToIt() {
        // Device A imported two copies, maybe on purpose; this device one.
        // This device's copy has the smallest ID: everything stays.
        let mineIsSmallest = [
            Copy(id: a, origin: .importedHere, added: minutes(2), uploaded: minutes(12)),
            Copy(id: b, origin: .fromICloud, added: t0, uploaded: minutes(10)),
            Copy(id: c, origin: .fromICloud, added: minutes(1), uploaded: minutes(11)),
        ]
        var first = makeLedger(for: mineIsSmallest)
        let kept = first.reconcile(documents(mineIsSmallest), now: minutes(20))
        #expect(kept.removals.isEmpty)
        #expect(kept.deletes.isEmpty)

        // Otherwise only this device's copy goes, to the smallest.
        let mineIsLargest = [
            Copy(id: a, origin: .fromICloud, added: t0, uploaded: minutes(10)),
            Copy(id: b, origin: .fromICloud, added: minutes(1), uploaded: minutes(11)),
            Copy(id: c, origin: .importedHere, added: minutes(2), uploaded: minutes(12)),
        ]
        var second = makeLedger(for: mineIsLargest)
        let plan = second.reconcile(documents(mineIsLargest), now: minutes(20))
        #expect(plan.removals == [c])
        #expect(plan.deletes == records(of: c))
        #expect(second.entry(for: b)?.removal == nil)
    }

    @Test func mergesOnlyEverGoToASmallerID() {
        // Every mix of origins for three independent copies: the smallest
        // is never removed, so no device's merges can remove every copy.
        let origins: [Origin] = [.importedHere, .fromICloud]
        for first in origins {
            for second in origins {
                for third in origins {
                    let copies = [(a, first), (b, second), (c, third)].enumerated().map { index, copy in
                        CloudSyncLedger.SyncedCopy(
                            id: copy.0,
                            origin: copy.1,
                            dateAdded: minutes(Double(index)),
                            createdAt: minutes(10 + Double(index))
                        )
                    }
                    let removals = CloudSyncLedger.duplicateRemovals(among: copies)
                    #expect(removals[a] == nil)
                    for (copy, keeper) in removals {
                        #expect(keeper.uuidString < copy.uuidString)
                    }
                    // The same whatever order the library lists them in.
                    #expect(CloudSyncLedger.duplicateRemovals(among: Array(copies.reversed())) == removals)
                }
            }
        }
    }

    @Test func copiesImportedBeforeEitherReachedICloudAreIndependent() {
        let first = CloudSyncLedger.SyncedCopy(id: a, origin: .importedHere, dateAdded: t0, createdAt: minutes(10))
        let second = CloudSyncLedger.SyncedCopy(id: b, origin: .fromICloud, dateAdded: minutes(1), createdAt: minutes(11))
        #expect(CloudSyncLedger.importedIndependently(first, second))
        #expect(CloudSyncLedger.importedIndependently(second, first))

        let later = CloudSyncLedger.SyncedCopy(id: b, origin: .fromICloud, dateAdded: minutes(10), createdAt: minutes(11))
        #expect(!CloudSyncLedger.importedIndependently(first, later))
        #expect(!CloudSyncLedger.importedIndependently(later, first))
    }

    // MARK: - Leaving

    @Test func duplicateWaitsWhileOpen() {
        var copies = pair(aOrigin: .fromICloud, bOrigin: .importedHere)
        copies[1].isOpen = true
        var ledger = makeLedger(for: copies)

        let open = ledger.reconcile(documents(copies), now: minutes(20))
        #expect(open == ReconcilePlan())
        #expect(ledger.entry(for: b)?.removal == .duplicateOf(a))

        copies[1].isOpen = false
        let closed = ledger.reconcile(documents(copies), now: minutes(21))
        #expect(closed.removals == [b])
        #expect(closed.deletes == records(of: b))
    }

    @Test func duplicateStaysWhenTheKeptCopyIsDeletedFirst() {
        var copies = pair(aOrigin: .fromICloud, bOrigin: .importedHere)
        copies[1].isOpen = true
        var ledger = makeLedger(for: copies)
        _ = ledger.reconcile(documents(copies), now: minutes(20))

        // The user deletes a while b is still open.
        let deleted = ledger.reconcile(documents([copies[1]]), now: minutes(21))
        #expect(deleted.deletes == records(of: a))

        // b is now the only copy: it stays.
        copies[1].isOpen = false
        let closed = ledger.reconcile(documents([copies[1]]), now: minutes(22))
        #expect(closed.removals.isEmpty)
        #expect(closed.deletes == records(of: a))
        #expect(ledger.entry(for: b)?.removal == nil)
    }

    @Test func duplicateStaysWhenTheKeptCopyIsDeletedElsewhere() {
        var copies = pair(aOrigin: .fromICloud, bOrigin: .importedHere)
        copies[1].isOpen = true
        var ledger = makeLedger(for: copies)
        _ = ledger.reconcile(documents(copies), now: minutes(20))

        let removeNow = ledger.receiveDeletion(of: CloudRecordKey(.book, a), isOpen: false)
        #expect(removeNow)
        copies[1].isOpen = false
        let plan = ledger.reconcile(documents([copies[1]]), now: minutes(21))
        #expect(plan.removals.isEmpty)
        #expect(plan.deletes.isEmpty)
        #expect(ledger.entry(for: b)?.removal == nil)
    }

    @Test func duplicateDeletedByTheOtherDeviceWhileOpenLeavesOnce() {
        // Device B removed b first; here b is open.
        var copies = pair(aOrigin: .importedHere, bOrigin: .fromICloud)
        copies[1].isOpen = true
        copies[1].position = position(40, read: minutes(15))
        var ledger = makeLedger(for: copies)
        _ = ledger.reconcile(documents(copies), now: minutes(20))
        #expect(ledger.entry(for: b)?.removal == .duplicateOf(a))

        let removeNow = ledger.receiveDeletion(of: CloudRecordKey(.book, b), isOpen: true, foldInto: a)
        #expect(!removeNow)
        copies[1].isOpen = false
        let plan = ledger.reconcile(documents(copies), now: minutes(21))
        #expect(plan.removals == [b])
        #expect(plan.positionUpdates == [a: position(40, read: minutes(15))])
        // Already gone from iCloud.
        #expect(plan.deletes.isEmpty)
    }

    @Test func duplicateDeletedByTheUserWhileWaitingIsDeleted() {
        var copies = pair(aOrigin: .fromICloud, bOrigin: .importedHere)
        copies[1].isOpen = true
        var ledger = makeLedger(for: copies)
        _ = ledger.reconcile(documents(copies), now: minutes(20))

        let plan = ledger.reconcile(documents([copies[0]]), now: minutes(21))
        #expect(plan.removals.isEmpty)
        #expect(plan.deletes == records(of: b))
        #expect(ledger.entry(for: b) == nil)
        #expect(ledger.entry(for: a)?.removal == nil)
    }

    // MARK: - Merging copies never uploaded

    @Test func mergedCopyThatTurnsOutToBeInICloudIsADuplicateWhenFromAnotherDevice() {
        // b was imported here and merged into a from device A, but its
        // upload landed: both are in iCloud, imported independently.
        let copies = pair(aOrigin: .fromICloud, bOrigin: .importedHere)
        var ledger = makeLedger(for: [copies[0]])
        ledger.markMerged(b, into: a)
        #expect(ledger.entry(for: b)?.origin == .importedHere)
        ledger.setContentHash("moby", for: b)
        ledger.confirmSaved(CloudRecordKey(.book, b), systemFields: Data([3]), title: "Moby-Dick", state: nil)
        ledger.entries[b.uuidString]?.bookCreatedAt = minutes(11)

        let plan = ledger.reconcile(documents(copies), now: minutes(20))
        #expect(plan.removals == [b])
        #expect(plan.deletes == records(of: b))
    }

    @Test func unsentCopyThatWouldWinUploadsInstead() {
        // b is the larger ID: merging it into a agrees with the duplicate rule.
        #expect(CloudSyncLedger.mayMergeUnsentCopy(b, addedAt: minutes(1), into: a, keeperCreatedAt: minutes(10)))
        // a, imported before b reached iCloud, would keep a and remove b if
        // its upload landed: it uploads instead.
        #expect(!CloudSyncLedger.mayMergeUnsentCopy(a, addedAt: minutes(1), into: b, keeperCreatedAt: minutes(10)))
        #expect(!CloudSyncLedger.mayMergeUnsentCopy(a, addedAt: minutes(1), into: b, keeperCreatedAt: nil))
        // Imported after b was in iCloud: the duplicate rule leaves the pair
        // alone, so merging is safe.
        #expect(CloudSyncLedger.mayMergeUnsentCopy(a, addedAt: minutes(30), into: b, keeperCreatedAt: minutes(10)))
    }

    // MARK: - Knowing where a document came from

    @Test func documentsImportedHereAndFromICloudAreTold() {
        var ledger = CloudSyncLedger()
        ledger.hasFetchedEverything = true
        _ = ledger.reconcile(documents([Copy(id: a, origin: nil, added: t0, uploaded: t0)]), now: minutes(1))
        #expect(ledger.entry(for: a)?.origin == .importedHere)

        _ = ledger.receiveBook(bookFields(), systemFields: Data([1]), for: b, localTitle: nil)
        ledger.markLocal(b)
        _ = ledger.reconcile(documents([
            Copy(id: a, origin: nil, added: t0, uploaded: t0),
            Copy(id: b, origin: nil, added: t0, uploaded: t0),
        ]), now: minutes(2))
        #expect(ledger.entry(for: b)?.origin == .fromICloud)

        // This device's own upload, seen in a fetch before its save is
        // confirmed, is still its own.
        _ = ledger.receiveBook(bookFields(), systemFields: Data([2]), for: a, localTitle: "Moby-Dick")
        #expect(ledger.entry(for: a)?.origin == .importedHere)
    }

    @Test func bookAlreadyInICloudWhenTheLedgerStartsHasUnknownOrigin() {
        // A ledger that started over (another store, a lost ledger, an
        // account change) with a library that synced before.
        var ledger = CloudSyncLedger()
        _ = ledger.reconcile(documents([Copy(id: a, origin: nil, added: t0, uploaded: t0)]), now: minutes(1))
        #expect(ledger.entry(for: a)?.origin == .importedHere)

        // The first full fetch shows a in iCloud: it may have come from anywhere.
        _ = ledger.receiveBook(bookFields(), systemFields: Data([1]), for: a, localTitle: "Moby-Dick")
        #expect(ledger.entry(for: a)?.origin == nil)
        _ = ledger.receiveBook(bookFields(), systemFields: Data([1]), for: b, localTitle: nil)
        ledger.markLocal(b)
        ledger.entries[a.uuidString]?.bookCreatedAt = minutes(10)
        ledger.entries[b.uuidString]?.bookCreatedAt = minutes(11)
        ledger.hasFetchedEverything = true

        // So an identical copy from iCloud isn't merged with it here.
        let plan = ledger.reconcile(documents([
            Copy(id: a, origin: nil, added: t0, uploaded: minutes(10)),
            Copy(id: b, origin: nil, added: minutes(1), uploaded: minutes(11)),
        ]), now: minutes(20))
        #expect(plan.removals.isEmpty)
    }

    @Test func originSurvivesLedgerChanges() {
        let copies = pair(aOrigin: .importedHere, bOrigin: .fromICloud)
        var ledger = makeLedger(for: copies)

        ledger.confirmSaved(CloudRecordKey(.book, a), systemFields: Data([2]), title: "Moby-Dick", state: nil)
        ledger.confirmSaved(
            CloudRecordKey(.state, a),
            systemFields: Data([2]),
            title: nil,
            state: StampedReadingPosition(position: position(5), modifiedAt: minutes(5))
        )
        // Fetched again, as after a refetch.
        _ = ledger.receiveBook(bookFields(), systemFields: Data([2]), for: b, localTitle: "Moby-Dick")
        #expect(ledger.entry(for: a)?.origin == .importedHere)
        #expect(ledger.entry(for: b)?.origin == .fromICloud)

        // An encrypted data reset: the library uploads again.
        ledger.forgetServerRecords()
        #expect(ledger.entry(for: a)?.origin == .importedHere)
        #expect(ledger.entry(for: b)?.origin == .fromICloud)
        #expect(ledger.entry(for: a)?.bookCreatedAt == nil)

        // A copy that leaves keeps what's known of it until then.
        ledger.markMerged(b, into: a)
        #expect(ledger.entry(for: b)?.origin == .fromICloud)

        // A copy taking reading before reconciling has seen it was imported here.
        var fresh = CloudSyncLedger()
        let keeper = LocalDocumentSnapshot(id: c, title: "Moby-Dick", position: position(0), dateAdded: t0)
        let leaving = LocalDocumentSnapshot(id: b, title: "Moby-Dick", position: position(30, read: minutes(3)), dateAdded: t0)
        fresh.entries[b.uuidString] = CloudSyncLedger.Entry(hasLocalDocument: true, syncedState: StampedReadingPosition(position: position(30, read: minutes(3)), modifiedAt: minutes(3)))
        #expect(fresh.mergeReading(from: leaving, into: keeper, now: minutes(4)) != nil)
        #expect(fresh.entry(for: c)?.origin == .importedHere)
    }

    @Test func ledgerKeepsOriginsInItsFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SyncDuplicateTests-\(UUID().uuidString)/Ledger.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let copies = pair(aOrigin: .importedHere, bOrigin: .fromICloud)
        var ledger = makeLedger(for: copies + [Copy(id: c, origin: nil, added: t0, uploaded: t0)])
        // Unknown fields are left out of the file, as in a ledger from an
        // earlier build.
        ledger.entries[c.uuidString]?.bookCreatedAt = nil
        ledger.entries[b.uuidString]?.removal = .duplicateOf(a)
        try ledger.save(to: url)

        let loaded = CloudSyncLedger.load(from: url)
        #expect(loaded.entries == ledger.entries)
        #expect(loaded.entry(for: a)?.origin == .importedHere)
        #expect(loaded.entry(for: b)?.removal == .duplicateOf(a))
        #expect(loaded.entry(for: c)?.origin == nil)
        #expect(loaded.entry(for: c)?.bookCreatedAt == nil)
    }
}
