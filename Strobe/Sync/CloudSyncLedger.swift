import CloudKit
import Foundation

/// A document as reconciliation sees it: only the parts that sync, read
/// without touching the word blobs.
nonisolated struct LocalDocumentSnapshot: Equatable {
    var id: UUID
    var title: String
    var position: ReadingPosition
    var dateAdded: Date
    /// Shown by a reader, book page, or alert right now, so it can't be
    /// removed yet.
    var isOpen = false
}

/// What reconciliation found for iCloud sync to do.
nonisolated struct ReconcilePlan: Equatable {
    /// Records with local changes iCloud doesn't have.
    var saves: [CloudRecordKey] = []
    /// Records of documents deleted on this device that iCloud still has.
    var deletes: [CloudRecordKey] = []
    /// Documents to take off this device now that nothing shows them.
    var removals: [UUID] = []
    /// Positions to write into local documents: a removed copy's reading
    /// handed to the copy that stays.
    var positionUpdates: [UUID: ReadingPosition] = [:]
}

/// What this device knows about its library in iCloud: each document's
/// records as last confirmed by the server, local changes not yet sent, and
/// deletions not yet confirmed.
///
/// Kept in its own file beside the SwiftData store, never in it, so syncing
/// doesn't change the store's schema. Losing the file is safe: the next start
/// fetches everything, matches it to the library by document ID, and uploads
/// what iCloud doesn't have. Sync never deletes anything because ledger state
/// is missing:
/// - A deletion is only sent for a document this ledger saw in the library
///   that has since left it, for a local copy merged into an identical
///   book already in iCloud, or for a duplicate (see `markDuplicates`).
/// - Nothing is uploaded until a full fetch has shown what iCloud has.
/// - A copy in iCloud is only merged away as a duplicate of one imported on
///   another device, and only into a copy with a smaller ID, so merges
///   never remove every copy.
nonisolated struct CloudSyncLedger: Codable {
    struct Entry: Codable, Equatable {
        enum Removal: Codable, Equatable {
            /// Deleted from iCloud by another device while shown here. Its
            /// reading goes to an identical local copy, if there is one.
            case deletedElsewhere(foldInto: UUID?)
            /// A copy never uploaded, of a book already in iCloud as the
            /// given document. Its reading goes to that document.
            case mergedInto(UUID)
            /// A copy in iCloud that duplicates the given document, the two
            /// imported on different devices. Its reading goes to that
            /// document, and its records are deleted from iCloud.
            case duplicateOf(UUID)
        }

        enum Origin: String, Codable {
            /// Imported on this device.
            case importedHere
            /// Added to this device's library from iCloud.
            case fromICloud
        }

        /// The document has been in this device's library. Entries without
        /// one hold a reading state whose book hasn't arrived yet.
        var hasLocalDocument = false
        /// Set when the document is to leave this device once nothing shows it.
        var removal: Removal?
        var bookSystemFields: Data?
        var stateSystemFields: Data?
        /// The title iCloud has.
        var syncedTitle: String?
        /// The reading state iCloud has.
        var syncedState: StampedReadingPosition?
        /// A local reading state iCloud doesn't have yet, stamped when its
        /// resume point was set.
        var localState: StampedReadingPosition?
        var contentHash: String?
        /// Where the document came from, which decides whether an identical
        /// copy in iCloud is a duplicate to merge. Nil when unknown: entries
        /// from builds before this was kept, and documents already in iCloud
        /// when this ledger started, which may have come from anywhere.
        var origin: Origin?
        /// When iCloud first saved the book record.
        var bookCreatedAt: Date?
    }

    /// `CKSyncEngine`'s own state: change tokens and pending changes.
    var engineState: CKSyncEngine.State.Serialization?
    /// The SwiftData store these entries describe. Any other store (a reset
    /// or replaced library) means none of them apply.
    var storeIdentifier: String?
    /// Whether a full fetch has finished since this ledger started. Until
    /// then nothing is uploaded, so a library that iCloud already has (the
    /// same books under the same IDs, or identical books from another
    /// device) isn't sent again.
    var hasFetchedEverything = false
    /// Keyed by document UUID string.
    var entries: [String: Entry] = [:]
    /// Documents deleted here whose records iCloud hasn't confirmed deleting.
    var pendingDeletes: Set<String> = []
    /// When the library was last reconciled. A local change the ledger
    /// hasn't seen was made after this, which dates changes saved while sync
    /// wasn't watching. Optional, so a ledger saved by an earlier build
    /// still loads.
    var lastReconciledAt: Date?
    /// Books from iCloud this device couldn't take in, to fetch again; keyed
    /// by document UUID string. Fields added after the first release are
    /// optional, so a ledger written by an earlier build still decodes.
    var skippedBooks: [String: SkippedBook]?
    /// Set once iCloud reports the storage full, until a save shows there's
    /// room again. Kept here so a relaunch doesn't start the backoff over.
    var storagePause: StoragePause?
    /// The iCloud account these records belong to, as its user record name.
    /// Nil until sync learns it, and in a ledger started after a sign-out.
    var userRecordName: String?
    /// An account sync turned off for and asked about: signed in, but not
    /// the one whose ledger is set aside. This ledger only runs again once
    /// the user turns sync back on, which agrees to sync with that account.
    var accountAskedAbout: String?

    /// A book from iCloud this device couldn't take in. The engine's change
    /// token has moved past its record, so it's fetched again directly.
    struct SkippedBook: Codable, Equatable {
        /// The newer format the book was written in, when that's why it was
        /// skipped: it's fetched again once a build reads that format. Nil
        /// when its words were missing or didn't match their fingerprint.
        var format: Int64?
        /// Tries that failed, each doubling the wait.
        var failures: Int
        /// Not fetched again before this.
        var retryAfter: Date
    }

    /// Saves held after iCloud refused one for lack of storage.
    struct StoragePause: Codable, Equatable {
        /// When held saves are tried again.
        var until: Date
        /// Refusals in a row, each doubling the pause.
        var failures: Int
        /// Whether an update to a book already in iCloud was refused too, so
        /// updates wait as well.
        var holdsUpdates: Bool
    }

    func entry(for id: UUID) -> Entry? {
        entries[id.uuidString]
    }

    func isPendingDelete(_ id: UUID) -> Bool {
        pendingDeletes.contains(id.uuidString)
    }

    /// Whether iCloud has confirmed the document's book record.
    func isInICloud(_ id: UUID) -> Bool {
        entries[id.uuidString]?.bookSystemFields != nil
    }

    /// Whether this ledger no longer describes the library: many documents
    /// it saw are gone at once, as when an older copy of the store is
    /// restored. Sending those as deletions would delete them everywhere, so
    /// sync starts over instead, and anything missing comes back from iCloud.
    func hasLostTrack(ofLibraryWith presentIDs: Set<UUID>) -> Bool {
        let known = entries.filter { $0.value.hasLocalDocument && $0.value.removal == nil }.keys
        let missing = known.filter { key in
            UUID(uuidString: key).map { !presentIDs.contains($0) } ?? false
        }
        return missing.count >= 3 && missing.count * 4 >= known.count
    }

    /// The stamp for a local document's position. Only a change to the
    /// resume point or speed counts as newer: opening and closing a book
    /// touches its last-read date without moving it, and that mustn't beat
    /// reading done on another device. Unchanged since the last sync keeps
    /// iCloud's stamp, a pending change keeps the stamp it got when first
    /// seen, and a document that has never synced uses its own dates, so the
    /// first upload of an existing library doesn't make every copy look just
    /// read.
    ///
    /// A change seen for the first time is stamped with when it was made, as
    /// near as sync can tell, so an old change doesn't beat newer reading on
    /// another device. It was made after `unseenSince`: `now` while sync is
    /// watching, since every save is then reconciled right away, or the last
    /// reconcile when it wasn't (sync was off, or the app quit or crashed
    /// before a scheduled reconcile ran). It was also made after every stamp
    /// the ledger has for the document. The last-read date, when later than
    /// all of those, is when the reader that moved it closed. When
    /// `unseenSince` isn't known (a ledger from an earlier build) and the
    /// last-read date is no later, it's stamped when first seen. Never later
    /// than `now`.
    func stamped(
        _ id: UUID,
        position: ReadingPosition,
        dateAdded: Date,
        now: Date,
        unseenSince: Date? = nil
    ) -> StampedReadingPosition {
        let entry = entry(for: id)
        let modifiedAt: Date
        if let synced = entry?.syncedState, synced.position.hasSameResumePoint(as: position) {
            modifiedAt = synced.modifiedAt
        } else if let pending = entry?.localState, pending.position.hasSameResumePoint(as: position) {
            modifiedAt = pending.modifiedAt
        } else if entry?.syncedState == nil && entry?.localState == nil {
            modifiedAt = position.lastReadDate ?? dateAdded
        } else {
            let earliest = [entry?.syncedState?.modifiedAt, entry?.localState?.modifiedAt, unseenSince]
                .compactMap { $0 }
                .max()
            if let lastRead = position.lastReadDate, lastRead > (earliest ?? .distantPast) {
                modifiedAt = min(lastRead, now)
            } else if unseenSince != nil, let earliest {
                modifiedAt = min(earliest, now)
            } else {
                modifiedAt = now
            }
        }
        return StampedReadingPosition(position: position, modifiedAt: modifiedAt)
    }

    /// Hands a copy's reading to the copy that stays. Returns the kept
    /// copy's new position, or nil if it doesn't change. The copy's entry
    /// must still exist. `unseenSince` dates changes not seen yet, as in
    /// `stamped`.
    mutating func mergeReading(
        from copy: LocalDocumentSnapshot,
        into keeper: LocalDocumentSnapshot,
        now: Date,
        unseenSince: Date? = nil
    ) -> ReadingPosition? {
        let merged = StampedReadingPosition.merged(
            stamped(keeper.id, position: keeper.position, dateAdded: keeper.dateAdded, now: now, unseenSince: unseenSince),
            stamped(copy.id, position: copy.position, dateAdded: copy.dateAdded, now: now, unseenSince: unseenSince)
        )
        guard merged.position != keeper.position else { return nil }
        // A local document with no entry yet was imported here, as in `reconcile`.
        entries[keeper.id.uuidString, default: Entry(origin: .importedHere)].localState = merged
        return merged.position
    }

    // MARK: - Local changes

    /// Compares the library with what iCloud last confirmed. Records new
    /// local changes and returns the records to send. `unseenSince` dates
    /// the changes it finds, as in `stamped`.
    mutating func reconcile(_ documents: [LocalDocumentSnapshot], now: Date, unseenSince: Date? = nil) -> ReconcilePlan {
        var plan = ReconcilePlan()
        let presentIDs = Set(documents.map(\.id))
        var snapshots = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Until a full fetch has shown what iCloud has, there may be copies
        // this ledger hasn't seen.
        if hasFetchedEverything {
            markDuplicates(among: snapshots)
        }

        // Documents waiting to leave go once nothing shows them, handing
        // their reading to the copy that stays.
        for (key, entry) in entries {
            guard let removal = entry.removal, let id = UUID(uuidString: key) else { continue }
            if let document = snapshots[id] {
                guard !document.isOpen else { continue }
                let keeperID: UUID?
                switch removal {
                case .deletedElsewhere(let foldInto):
                    keeperID = foldInto
                case .mergedInto(let target):
                    // The copy in iCloud is gone or going, or this one
                    // turned out to be in iCloud too: it stays, like any
                    // other book.
                    guard snapshots[target] != nil,
                          entries[target.uuidString]?.removal == nil,
                          entry.bookSystemFields == nil else {
                        entries[key]?.removal = nil
                        continue
                    }
                    keeperID = target
                case .duplicateOf(let target):
                    // The copy that stays was deleted, is leaving, or is no
                    // longer in iCloud since this one was marked: both stay.
                    guard snapshots[target] != nil,
                          entries[target.uuidString]?.removal == nil,
                          isInICloud(target),
                          !isPendingDelete(target) else {
                        entries[key]?.removal = nil
                        continue
                    }
                    keeperID = target
                }
                if let keeperID, let keeper = snapshots[keeperID],
                   let position = mergeReading(from: document, into: keeper, now: now, unseenSince: unseenSince) {
                    snapshots[keeperID]?.position = position
                    plan.positionUpdates[keeperID] = position
                }
                plan.removals.append(id)
                snapshots[id] = nil
            }
            if case .mergedInto = removal {
                // Never uploaded as far as this device knows; if an upload
                // did land, the book it duplicates is in iCloud, so deleting
                // this copy's records loses nothing.
                pendingDeletes.insert(key)
            }
            if case .duplicateOf = removal {
                // Its records are in iCloud: deleting them takes it off
                // every device.
                pendingDeletes.insert(key)
            }
            entries[key] = nil
        }

        for document in snapshots.values {
            let key = document.id.uuidString
            // No entry: imported on this device, since a book from iCloud
            // gets its entry before it's added. One that was already in
            // iCloud when this ledger started is told apart when its record
            // arrives (see `receiveBook`).
            var entry = entries[key] ?? Entry(origin: .importedHere)
            // Still shown while waiting to leave: nothing to send for it.
            guard entry.removal == nil else { continue }
            entry.hasLocalDocument = true
            if entry.bookSystemFields == nil || entry.syncedTitle != document.title {
                plan.saves.append(CloudRecordKey(.book, document.id))
            }
            if entry.stateSystemFields == nil || entry.syncedState?.position != document.position {
                entry.localState = stamped(document.id, position: document.position, dateAdded: document.dateAdded, now: now, unseenSince: unseenSince)
                plan.saves.append(CloudRecordKey(.state, document.id))
            } else {
                entry.localState = nil
            }
            entries[key] = entry
        }

        // Documents that were in the library and aren't any more were
        // deleted here.
        for (key, entry) in entries where entry.hasLocalDocument && entry.removal == nil {
            guard let id = UUID(uuidString: key), !presentIDs.contains(id) else { continue }
            pendingDeletes.insert(key)
            entries[key] = nil
        }

        lastReconciledAt = now
        plan.saves.sort()
        plan.removals.sort { $0.uuidString < $1.uuidString }
        plan.deletes = pendingDeletes.sorted().compactMap(UUID.init(uuidString:)).flatMap {
            [CloudRecordKey(.book, $0), CloudRecordKey(.state, $0)]
        }
        return plan
    }

    /// Marks a local copy that was never uploaded, of a book iCloud already
    /// has as `keeperID`. It leaves once nothing shows it, handing its
    /// reading to the kept copy.
    mutating func markMerged(_ id: UUID, into keeperID: UUID) {
        // No entry yet: imported here, as in `reconcile`. That matters if
        // the copy turns out to be in iCloud and stays.
        var entry = entries[id.uuidString] ?? Entry(origin: .importedHere)
        entry.hasLocalDocument = true
        entry.removal = .mergedInto(keeperID)
        entries[id.uuidString] = entry
    }

    /// Whether a local copy not yet in iCloud may merge into an identical
    /// book that is, as `keeperID`, which iCloud first saved at
    /// `keeperCreatedAt`. The copy's upload may already be on its way, and
    /// if it lands, `duplicateRemovals` mustn't then remove the other book
    /// in favor of this copy, or both would go. So a copy that would win
    /// there (the smaller ID, imported before the other reached iCloud)
    /// uploads instead, and the duplicate rule settles the pair.
    static func mayMergeUnsentCopy(_ id: UUID, addedAt: Date, into keeperID: UUID, keeperCreatedAt: Date?) -> Bool {
        guard id.uuidString < keeperID.uuidString else { return true }
        guard let keeperCreatedAt else { return false }
        return addedAt >= keeperCreatedAt
    }

    // MARK: - Duplicates

    /// A book in iCloud as the duplicate rule sees it.
    struct SyncedCopy {
        var id: UUID
        var origin: Entry.Origin
        /// When it was imported, on whichever device.
        var dateAdded: Date
        /// When iCloud first saved its book record.
        var createdAt: Date
    }

    /// Whether each copy was imported before the other reached iCloud, so
    /// neither could have been in the library when the other was imported.
    /// One imported later may have been imported next to the other on
    /// purpose.
    static func importedIndependently(_ a: SyncedCopy, _ b: SyncedCopy) -> Bool {
        a.dateAdded < b.createdAt && b.dateAdded < a.createdAt
    }

    /// For identical copies of one book, all in iCloud, the ones this
    /// device removes, each with the copy its reading goes to. Copies only
    /// ever go to one with a smaller ID, so the smallest is never removed
    /// by any device, and only pairs imported independently count.
    ///
    /// Only a device that imported exactly one of them decides: one that
    /// imported two did so on purpose, and one that imported none can't
    /// tell which came from the same device; it receives the deletions.
    /// Of a pair, both devices that imported them remove the same copy,
    /// so neither shows the duplicate for long. With more copies, this
    /// device removes only its own, since two of the others may have been
    /// imported on one device.
    static func duplicateRemovals(among copies: [SyncedCopy]) -> [UUID: UUID] {
        let own = copies.filter { $0.origin == .importedHere }
        guard own.count == 1, let mine = own.first else { return [:] }
        let others = copies.filter { $0.id != mine.id }
        guard let smallest = others
            .filter({ importedIndependently(mine, $0) })
            .min(by: { $0.id.uuidString < $1.id.uuidString }) else { return [:] }
        if smallest.id.uuidString < mine.id.uuidString {
            return [mine.id: smallest.id]
        }
        return others.count == 1 ? [smallest.id: mine.id] : [:]
    }

    /// Marks duplicates to leave once nothing shows them: identical copies
    /// in iCloud imported on different devices before either reached
    /// iCloud, as when two devices with the same book turn on sync at about
    /// the same time. See `duplicateRemovals`. Copies need the same title
    /// and words. Grouping uses the hashes the ledger keeps for books in
    /// iCloud, so no words are read.
    private mutating func markDuplicates(among documents: [UUID: LocalDocumentSnapshot]) {
        var groups: [[String]: [SyncedCopy]] = [:]
        // Titles with a copy that can't be counted yet: one not in iCloud
        // (still uploading, say), or of unknown origin, which could be one
        // imported here or a second one from elsewhere. Their groups wait.
        var undecided: Set<String> = []
        for (id, document) in documents {
            let key = id.uuidString
            guard var entry = entries[key] else {
                undecided.insert(document.title)
                continue
            }
            if case .mergedInto = entry.removal, entry.bookSystemFields != nil {
                // In iCloud after all, so it stays (see `reconcile`), and
                // may be a duplicate like any other copy there.
                entry.removal = nil
                entries[key] = entry
            }
            guard entry.removal == nil, !pendingDeletes.contains(key) else { continue }
            guard entry.bookSystemFields != nil, let contentHash = entry.contentHash,
                  let origin = entry.origin, let createdAt = entry.bookCreatedAt else {
                undecided.insert(document.title)
                continue
            }
            groups[[document.title, contentHash], default: []].append(
                SyncedCopy(id: id, origin: origin, dateAdded: document.dateAdded, createdAt: createdAt)
            )
        }
        for (group, copies) in groups where copies.count > 1 && !undecided.contains(group[0]) {
            for (id, keeperID) in Self.duplicateRemovals(among: copies) {
                entries[id.uuidString]?.removal = .duplicateOf(keeperID)
            }
        }
    }

    // MARK: - Records from iCloud

    /// Takes in a book record, fetched or returned by a conflict.
    /// `localTitle` is nil when the book is new to this device. Returns a
    /// title to show locally, or nil to keep the local one: a rename made
    /// here and not yet sent wins over an older title in iCloud.
    mutating func receiveBook(
        _ fields: BookRecordFields,
        systemFields: Data,
        for id: UUID,
        localTitle: String?
    ) -> String? {
        let key = id.uuidString
        var entry = entries[key] ?? Entry()
        let previousTitle = entry.syncedTitle
        if localTitle == nil {
            entry.origin = .fromICloud
        } else if !hasFetchedEverything && entry.bookSystemFields == nil && entry.origin == .importedHere {
            // Already in iCloud, though nothing uploads before the first full
            // fetch: it was there before this ledger started, uploaded by
            // this device or added here from iCloud. Which isn't known.
            entry.origin = nil
        }
        entry.bookSystemFields = systemFields
        if let createdAt = Self.creationDate(inSystemFields: systemFields) {
            entry.bookCreatedAt = createdAt
        }
        entry.syncedTitle = fields.title
        entry.contentHash = fields.contentHash
        entries[key] = entry
        guard let localTitle, localTitle != fields.title else { return nil }
        let renamedHere = previousTitle != nil && localTitle != previousTitle
        return renamedHere ? nil : fields.title
    }

    /// Takes in a reading state record. `local` is the document's current
    /// position, or nil when its book hasn't arrived; the state then waits
    /// in the ledger for it. Returns the position the document should show,
    /// merged with any local reading iCloud doesn't have yet. `unseenSince`
    /// dates a local change not seen yet, as in `stamped`.
    mutating func receiveState(
        _ remote: StampedReadingPosition,
        systemFields: Data,
        for id: UUID,
        local: (position: ReadingPosition, dateAdded: Date)?,
        now: Date,
        unseenSince: Date? = nil
    ) -> ReadingPosition? {
        let key = id.uuidString
        var localStamp: StampedReadingPosition?
        if let local {
            localStamp = stamped(id, position: local.position, dateAdded: local.dateAdded, now: now, unseenSince: unseenSince)
        }
        var entry = entries[key] ?? Entry()
        entry.stateSystemFields = systemFields
        entry.syncedState = remote
        guard let localStamp else {
            entries[key] = entry
            return nil
        }
        let merged = StampedReadingPosition.merged(localStamp, remote)
        entry.localState = merged.position == remote.position ? nil : merged
        entries[key] = entry
        return merged.position
    }

    /// Records a document from iCloud as part of this device's library.
    /// Called only after the store has saved it, so a failed save can never
    /// look like a local deletion.
    mutating func markLocal(_ id: UUID) {
        entries[id.uuidString, default: Entry()].hasLocalDocument = true
        // A book skipped earlier is here now.
        skippedBooks?[id.uuidString] = nil
    }

    /// Takes in a record deleted from iCloud. For a book, returns whether
    /// to remove the local document now; a document that's open waits until
    /// it closes, then hands its reading to `foldInto`.
    mutating func receiveDeletion(of record: CloudRecordKey, isOpen: Bool, foldInto: UUID? = nil) -> Bool {
        let key = record.documentID.uuidString
        switch record.kind {
        case .book:
            pendingDeletes.remove(key)
            skippedBooks?[key] = nil
            // No entry: nothing here is known to be that book's synced copy.
            guard var entry = entries[key], entry.hasLocalDocument else {
                entries[key] = nil
                return false
            }
            if isOpen {
                entry.removal = .deletedElsewhere(foldInto: foldInto)
                entries[key] = entry
                return false
            }
            entries[key] = nil
            return true
        case .state:
            if let entry = entries[key], !entry.hasLocalDocument {
                entries[key] = nil
            }
            return false
        }
    }

    // MARK: - Send results

    mutating func setContentHash(_ contentHash: String, for id: UUID) {
        entries[id.uuidString]?.contentHash = contentHash
    }

    /// Records a save iCloud confirmed. `title` and `state` are the values
    /// the saved record carries.
    mutating func confirmSaved(
        _ record: CloudRecordKey,
        systemFields: Data,
        title: String?,
        state: StampedReadingPosition?
    ) {
        let key = record.documentID.uuidString
        // Deleted here while the save was in flight: the deletion follows.
        guard var entry = entries[key] else { return }
        switch record.kind {
        case .book:
            entry.bookSystemFields = systemFields
            if let createdAt = Self.creationDate(inSystemFields: systemFields) {
                entry.bookCreatedAt = createdAt
            }
            if let title { entry.syncedTitle = title }
        case .state:
            entry.stateSystemFields = systemFields
            if let state {
                entry.syncedState = state
                if entry.localState?.position == state.position {
                    entry.localState = nil
                }
            }
        }
        entries[key] = entry
    }

    mutating func confirmDeleted(_ record: CloudRecordKey) {
        if record.kind == .book {
            pendingDeletes.remove(record.documentID.uuidString)
        }
    }

    /// Forgets a record iCloud no longer has, so the next save creates it
    /// again.
    mutating func forgetServerRecord(_ record: CloudRecordKey) {
        let key = record.documentID.uuidString
        guard var entry = entries[key] else { return }
        switch record.kind {
        case .book:
            entry.bookSystemFields = nil
            entry.syncedTitle = nil
        case .state:
            entry.stateSystemFields = nil
            entry.syncedState = nil
        }
        entries[key] = entry
    }

    /// Forgets every record after iCloud lost the zone (an encrypted data
    /// reset), so the whole library uploads again. What's in the library
    /// here is kept.
    mutating func forgetServerRecords() {
        for (key, entry) in entries {
            guard entry.hasLocalDocument else {
                entries[key] = nil
                continue
            }
            var kept = Entry()
            kept.hasLocalDocument = true
            kept.removal = entry.removal
            kept.contentHash = entry.contentHash
            kept.origin = entry.origin
            entries[key] = kept
        }
        pendingDeletes.removeAll()
        // Their records went with the zone; the devices that have them
        // upload them again.
        skippedBooks = nil
    }

    /// When iCloud first saved the record whose system fields these are.
    /// Archived system fields keep the record's creation date.
    private static func creationDate(inSystemFields data: Data) -> Date? {
        CloudRecordArchive.record(fromSystemFields: data)?.creationDate
    }

    // MARK: - Storage

    static var fileURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "CloudSync", directoryHint: .isDirectory)
            .appending(path: "Ledger.plist")
    }

    /// The saved ledger, or an empty one. An unreadable file is set aside
    /// for diagnosis; an empty ledger only means fetching and matching again.
    static func load(from url: URL = fileURL) -> CloudSyncLedger {
        guard let data = try? Data(contentsOf: url) else { return CloudSyncLedger() }
        do {
            return try PropertyListDecoder().decode(CloudSyncLedger.self, from: data)
        } catch {
            try? FileManager.default.removeItem(at: url.appendingPathExtension("unreadable"))
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable"))
            return CloudSyncLedger()
        }
    }

    func save(to url: URL = Self.fileURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// A new ledger for the same store and iCloud account. Sync starts over
    /// with everything else, but still knows which account the library
    /// synced with, so a different one is asked about first.
    func startingOver() -> CloudSyncLedger {
        CloudSyncLedger(
            storeIdentifier: storeIdentifier,
            userRecordName: userRecordName,
            accountAskedAbout: accountAskedAbout
        )
    }

    /// Where the ledger of an account that signed out waits for it to sign
    /// back in. Only one is kept: the account the library last synced with.
    static var setAsideFileURL: URL {
        fileURL.deletingLastPathComponent().appending(path: "SetAside.plist")
    }

    /// The ledger set aside at a sign-out, or nil if there isn't one. One
    /// that can't be read is set aside for diagnosis, as `load(from:)` does.
    static func loadSetAside(from url: URL = setAsideFileURL) -> CloudSyncLedger? {
        let ledger = load(from: url)
        // Missing, unreadable, or not tied to an account: nothing to restore.
        return ledger.userRecordName == nil ? nil : ledger
    }

    static func removeSetAside(at url: URL = setAsideFileURL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Retries

nonisolated extension CloudSyncLedger {
    /// The wait after an unreadable book's first failed try, doubled after
    /// each later one up to a week: soon enough for a passing fault, and
    /// rarely enough that a damaged upload isn't downloaded on every launch.
    static let skippedBookFirstWait: TimeInterval = 3600
    static let skippedBookLongestWait: TimeInterval = 7 * 86_400
    /// The first storage pause, doubled after each refusal in a row up to a
    /// day. A try a day costs next to nothing, and a day is about as long
    /// as sync should take to notice on its own that the user made room.
    static let storagePauseFirstLength: TimeInterval = 900
    static let storagePauseLongestLength: TimeInterval = 86_400

    /// `first`, doubled for each failure after the first, up to `longest`.
    static func backoff(first: TimeInterval, longest: TimeInterval, failures: Int) -> TimeInterval {
        let doublings = min(max(0, failures - 1), 30)
        return min(first * TimeInterval(1 << doublings), longest)
    }

    // MARK: Skipped books

    func isSkipped(_ id: UUID) -> Bool {
        skippedBooks?[id.uuidString] != nil
    }

    /// The skipped books due another fetch: written in a format this build
    /// reads, and past their wait.
    func skippedBooksDue(now: Date, readableFormat: Int64 = CloudSyncSchema.bookFormat) -> [UUID] {
        (skippedBooks ?? [:])
            .filter { ($0.value.format ?? 0) <= readableFormat && $0.value.retryAfter <= now }
            .keys
            .sorted()
            .compactMap(UUID.init(uuidString:))
    }

    /// Records a book written in a newer format than this build reads. It's
    /// fetched again once a build reads that format, after an update.
    mutating func skipNewerFormatBook(_ id: UUID, format: Int64, now: Date) {
        setSkipped(SkippedBook(format: format, failures: 0, retryAfter: now), for: id)
    }

    /// Records a book whose words were missing or didn't match their
    /// fingerprint, most likely a damaged upload. It's fetched again after a
    /// wait that doubles with each try.
    mutating func skipUnreadableBook(_ id: UUID, now: Date) {
        retryLater(id, format: nil, now: now)
    }

    /// A fetch of a skipped book failed: it waits before the next, like an
    /// unreadable book.
    mutating func skippedBookFetchFailed(_ id: UUID, now: Date) {
        guard let skipped = skippedBooks?[id.uuidString] else { return }
        retryLater(id, format: skipped.format, now: now)
    }

    /// Takes a book off the skipped list: iCloud no longer has it.
    mutating func forgetSkippedBook(_ id: UUID) {
        skippedBooks?[id.uuidString] = nil
    }

    /// Ends a fetch of skipped books, once their records went through like
    /// any fetched change. Those taken in have left the list (`markLocal`),
    /// and those skipped again were listed anew. Any still listed as before
    /// were neither, being here already, say, or a record this build can't
    /// parse; fetching them again won't help, so they leave too.
    mutating func finishRefetch(of ids: [UUID], skippedBefore: [String: SkippedBook]?) {
        for id in ids {
            let key = id.uuidString
            if let before = skippedBefore?[key], skippedBooks?[key] == before {
                skippedBooks?[key] = nil
            }
        }
    }

    private mutating func retryLater(_ id: UUID, format: Int64?, now: Date) {
        let failures = (skippedBooks?[id.uuidString]?.failures ?? 0) + 1
        let wait = Self.backoff(first: Self.skippedBookFirstWait, longest: Self.skippedBookLongestWait, failures: failures)
        setSkipped(SkippedBook(format: format, failures: failures, retryAfter: now.addingTimeInterval(wait)), for: id)
    }

    private mutating func setSkipped(_ book: SkippedBook, for id: UUID) {
        var skipped = skippedBooks ?? [:]
        skipped[id.uuidString] = book
        skippedBooks = skipped
    }

    // MARK: Full storage

    func isStoragePaused(now: Date) -> Bool {
        storagePause.map { $0.until > now } ?? false
    }

    /// Whether a save waits for the storage pause to end. First uploads, a
    /// book iCloud doesn't have and its reading state, always wait: they're
    /// what needs the room. Updates to books already in iCloud (positions
    /// and renames) are tiny and keep devices in step, so they go on unless
    /// one was refused too.
    func holdsSave(_ record: CloudRecordKey, now: Date) -> Bool {
        guard let pause = storagePause, pause.until > now else { return false }
        return pause.holdsUpdates || !isInICloud(record.documentID)
    }

    /// Records a save iCloud refused for lack of storage, `refusedUpdate`
    /// when it was an update to a book already in iCloud. Starts a pause
    /// twice as long as the last one, or, while one is on (the save was
    /// sent before it began, or is an update it let through), keeps it,
    /// holding updates too if one was refused. Returns the end of a new
    /// pause.
    mutating func noteStorageFull(refusedUpdate: Bool, now: Date) -> Date? {
        if var pause = storagePause, pause.until > now {
            pause.holdsUpdates = pause.holdsUpdates || refusedUpdate
            storagePause = pause
            return nil
        }
        let failures = (storagePause?.failures ?? 0) + 1
        let length = Self.backoff(first: Self.storagePauseFirstLength, longest: Self.storagePauseLongestLength, failures: failures)
        let until = now.addingTimeInterval(length)
        storagePause = StoragePause(until: until, failures: failures, holdsUpdates: refusedUpdate)
        return until
    }

    /// Records saves iCloud accepted. A first upload going through shows
    /// there's room and ends the pause; so does any save once no book is
    /// waiting for its first upload. An update going through shows only
    /// that updates fit: they stop waiting, and books still wait.
    mutating func noteSavesAccepted(includingFirstUpload firstUpload: Bool) {
        guard storagePause != nil else { return }
        if firstUpload || !hasBooksToUpload {
            storagePause = nil
        } else {
            storagePause?.holdsUpdates = false
        }
    }

    /// Whether the library has a document whose book iCloud doesn't have.
    var hasBooksToUpload: Bool {
        entries.values.contains { $0.hasLocalDocument && $0.removal == nil && $0.bookSystemFields == nil }
    }

    /// Whether iCloud has confirmed any of the library's records, so its
    /// zone exists.
    var hasRecordsInICloud: Bool {
        entries.values.contains { $0.bookSystemFields != nil || $0.stateSystemFields != nil }
    }
}

nonisolated extension ReadingPosition {
    /// The part of a position that the most recent device decides: where to
    /// resume and at what speed. The furthest point and last-read date only
    /// ever move forward, so they don't make a position newer.
    func hasSameResumePoint(as other: ReadingPosition) -> Bool {
        currentWordIndex == other.currentWordIndex && wordsPerMinute == other.wordsPerMinute
    }
}
