import Foundation
import Testing
@testable import Strobe

/// When a local reading position counts as set, which decides between two
/// devices that both moved: changes saved while sync wasn't watching, and
/// the ledger put back after the store couldn't save a reconcile.
struct SyncPositionTimingTests {

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

    private func document(_ id: UUID, at position: ReadingPosition) -> LocalDocumentSnapshot {
        LocalDocumentSnapshot(id: id, title: "Book", position: position, dateAdded: t0)
    }

    private func synced(state: StampedReadingPosition) -> CloudSyncLedger.Entry {
        CloudSyncLedger.Entry(
            hasLocalDocument: true,
            bookSystemFields: Data([1]),
            stateSystemFields: Data([1]),
            syncedTitle: "Book",
            syncedState: state
        )
    }

    // MARK: - Changes sync didn't watch

    /// The Mac reads to word 200 and quits at minute 10, and the reconcile
    /// that would stamp the change never runs. The iPhone then reads to word
    /// 900 at minute 60. At the Mac's next launch (minute 120), `startEngine`
    /// reconciles before it fetches. Stamped with the launch time, the Mac's
    /// old change would win and the iPhone would jump back to word 200. This
    /// ledger doesn't know when it last reconciled (like one from an earlier
    /// build), so the last-read date dates the change.
    ///
    /// The same goes for reading done while sync is turned off, once it's
    /// turned back on.
    @Test func changeMadeWhileSyncWasNotWatchingDoesNotBeatNewerReading() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(100, read: t0), modifiedAt: t0))
        let mac = position(200, read: minutes(10))
        let phone = StampedReadingPosition(position: position(900, read: minutes(60)), modifiedAt: minutes(60))

        _ = ledger.reconcile([document(id, at: mac)], now: minutes(120))
        let shown = ledger.receiveState(phone, systemFields: Data([2]), for: id, local: (mac, t0), now: minutes(121))

        #expect(shown?.currentWordIndex == 900)
    }

    /// Sync is turned off at minute 20. The Mac reads at minute 30 and again
    /// at minute 50; the iPhone reads at minute 40. Turned back on, the Mac's
    /// later reading wins.
    @Test func readingWhileSyncWasOffIsDatedWhenItWasRead() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(100, read: t0), modifiedAt: t0))
        ledger.lastReconciledAt = minutes(20)
        let mac = position(200, read: minutes(50))

        _ = ledger.reconcile([document(id, at: mac)], now: minutes(120), unseenSince: ledger.lastReconciledAt)
        #expect(ledger.entry(for: id)?.localState?.modifiedAt == minutes(50))

        let phone = StampedReadingPosition(position: position(900, read: minutes(40)), modifiedAt: minutes(40))
        let shown = ledger.receiveState(phone, systemFields: Data([2]), for: id, local: (mac, t0), now: minutes(121))
        #expect(shown == position(200, furthest: 900, read: minutes(50)))
    }

    /// Going to the background saves the position without touching the
    /// last-read date. If the app is killed before the reconcile that save
    /// scheduled, the change still came after the last reconcile, minute 30.
    @Test func changeWithAnOlderReadDateIsDatedByTheLastReconcile() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(100, read: t0), modifiedAt: t0))
        ledger.lastReconciledAt = minutes(30)
        let mac = position(200, read: t0)

        _ = ledger.reconcile([document(id, at: mac)], now: minutes(120), unseenSince: ledger.lastReconciledAt)
        #expect(ledger.entry(for: id)?.localState?.modifiedAt == minutes(30))

        let phone = StampedReadingPosition(position: position(900, read: minutes(60)), modifiedAt: minutes(60))
        let shown = ledger.receiveState(phone, systemFields: Data([2]), for: id, local: (mac, t0), now: minutes(121))
        #expect(shown?.currentWordIndex == 900)
    }

    /// A reading state received at minute 50, after the last reconcile but
    /// with the app quitting before the next: a change the ledger hasn't
    /// seen is newer than that too.
    @Test func unseenChangeIsNewerThanWhatTheLedgerKnows() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(100), modifiedAt: minutes(50)))
        ledger.lastReconciledAt = minutes(30)

        _ = ledger.reconcile([document(id, at: position(200, read: minutes(10)))], now: minutes(120), unseenSince: ledger.lastReconciledAt)
        #expect(ledger.entry(for: id)?.localState?.modifiedAt == minutes(50))
    }

    /// A last-read date from a device whose clock runs ahead.
    @Test func unseenChangeIsNeverStampedLaterThanNow() {
        let id = UUID()
        let state = StampedReadingPosition(position: position(100), modifiedAt: t0)
        let ahead = position(200, read: minutes(200))

        var knowingLedger = CloudSyncLedger()
        knowingLedger.entries[id.uuidString] = synced(state: state)
        _ = knowingLedger.reconcile([document(id, at: ahead)], now: minutes(120), unseenSince: minutes(30))
        #expect(knowingLedger.entry(for: id)?.localState?.modifiedAt == minutes(120))

        var unknowingLedger = CloudSyncLedger()
        unknowingLedger.entries[id.uuidString] = synced(state: state)
        _ = unknowingLedger.reconcile([document(id, at: ahead)], now: minutes(120))
        #expect(unknowingLedger.entry(for: id)?.localState?.modifiedAt == minutes(120))
    }

    /// Without the last reconcile, and with a last-read date older than
    /// iCloud's stamp, nothing dates the change: it's stamped when first
    /// seen, as before.
    @Test func undatableChangeIsStampedWhenFirstSeen() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(100), modifiedAt: minutes(50)))

        _ = ledger.reconcile([document(id, at: position(200, read: minutes(10)))], now: minutes(120))
        #expect(ledger.entry(for: id)?.localState?.modifiedAt == minutes(120))
    }

    /// A book opened and closed without moving at minute 10 keeps that
    /// last-read date. Another device reads at minute 40, then this one reads
    /// from minute 60 to 90 and goes to the background, which doesn't touch
    /// the last-read date. Sync was watching, so the change is from when it
    /// was seen, minute 90, not minute 10.
    @Test func changeSeenWhileWatchingIsStampedWhenSeen() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(200, read: t0), modifiedAt: t0))

        _ = ledger.reconcile([document(id, at: position(200, read: minutes(10)))], now: minutes(10), unseenSince: minutes(10))
        #expect(ledger.entry(for: id)?.localState?.modifiedAt == t0)

        let read = position(500, read: minutes(10))
        _ = ledger.reconcile([document(id, at: read)], now: minutes(90), unseenSince: minutes(90))
        #expect(ledger.entry(for: id)?.localState?.modifiedAt == minutes(90))

        let remote = StampedReadingPosition(position: position(800, read: minutes(40)), modifiedAt: minutes(40))
        let shown = ledger.receiveState(remote, systemFields: Data([2]), for: id, local: (read, t0), now: minutes(91), unseenSince: minutes(91))
        #expect(shown?.currentWordIndex == 500)
    }

    /// A fetch can arrive before any reconcile has seen the library (the
    /// first one failed): the state merged in dates the local change the
    /// same way.
    @Test func receivedStateDatesAChangeSyncHasNotSeen() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(100, read: t0), modifiedAt: t0))
        let local = position(200, read: t0)
        let phone = StampedReadingPosition(position: position(900, read: minutes(60)), modifiedAt: minutes(60))

        let shown = ledger.receiveState(phone, systemFields: Data([2]), for: id, local: (local, t0), now: minutes(120), unseenSince: minutes(30))
        #expect(shown == phone.position)
        #expect(ledger.entry(for: id)?.localState == nil)
    }

    /// A book deleted elsewhere hands its reading to an identical copy. Its
    /// unseen change, made after minute 30, loses to the copy's reading from
    /// minute 50.
    @Test func mergedReadingDatesAChangeSyncHasNotSeen() {
        let deleted = UUID()
        let keeper = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[deleted.uuidString] = synced(state: StampedReadingPosition(position: position(10), modifiedAt: t0))
        ledger.entries[keeper.uuidString] = synced(state: StampedReadingPosition(position: position(4), modifiedAt: minutes(50)))

        let merged = ledger.mergeReading(
            from: document(deleted, at: position(90)),
            into: document(keeper, at: position(4)),
            now: minutes(120),
            unseenSince: minutes(30)
        )
        #expect(merged == position(4, furthest: 90))
    }

    // MARK: - Ledger

    @Test func lastReconcileIsKeptInTheLedgerFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SyncPositionTimingTests-\(UUID().uuidString)/Ledger.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = CloudSyncLedger()
        _ = ledger.reconcile([document(UUID(), at: position(0))], now: minutes(7))
        #expect(ledger.lastReconciledAt == minutes(7))

        try ledger.save(to: url)
        #expect(CloudSyncLedger.load(from: url).lastReconciledAt == minutes(7))
    }

    @Test func ledgerFromAnEarlierBuildStillLoads() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SyncPositionTimingTests-\(UUID().uuidString)/Ledger.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(9, read: t0), modifiedAt: t0))
        ledger.lastReconciledAt = minutes(5)

        // The same file without the field, as an earlier build wrote it.
        let encoded = try PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(ledger), format: nil)
        var plist = try #require(encoded as? [String: Any])
        #expect(plist.keys.contains("lastReconciledAt"))
        plist["lastReconciledAt"] = nil
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)

        let loaded = CloudSyncLedger.load(from: url)
        #expect(loaded.entries == ledger.entries)
        #expect(loaded.lastReconciledAt == nil)
    }

    // MARK: - A reconcile the store couldn't save

    /// Reconciling forgets a book deleted elsewhere once it closes, and
    /// removes it from the store. When that save fails, the ledger as it was
    /// before tries the removal again; the ledger as reconciled would take the
    /// book for a new one and upload it, bringing it back everywhere.
    @Test func ledgerPutBackAfterAFailedSaveRemovesTheBookAgain() {
        let id = UUID()
        var ledger = CloudSyncLedger()
        ledger.entries[id.uuidString] = synced(state: StampedReadingPosition(position: position(10), modifiedAt: t0))
        _ = ledger.receiveDeletion(of: CloudRecordKey(.book, id), isOpen: true)

        let before = ledger
        let plan = ledger.reconcile([document(id, at: position(10))], now: minutes(1))
        #expect(plan.removals == [id])
        var reconciled = ledger

        // The store couldn't save the removal, so the book is still there.
        ledger = before
        let retry = ledger.reconcile([document(id, at: position(10))], now: minutes(2))
        #expect(retry.removals == [id])
        #expect(retry.saves.isEmpty)
        #expect(retry.deletes.isEmpty)

        let resurrected = reconciled.reconcile([document(id, at: position(10))], now: minutes(2))
        #expect(Set(resurrected.saves) == [CloudRecordKey(.book, id), CloudRecordKey(.state, id)])
    }
}
