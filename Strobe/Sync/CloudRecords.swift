import CloudKit
import CryptoKit
import Foundation

/// The names every device agrees on: the iCloud container, the record zone,
/// the two record types, and their fields.
///
/// Once the schema is deployed to CloudKit's production environment these are
/// permanent: fields can be added, never renamed, retyped, or removed.
nonisolated enum CloudSyncSchema {
    static let containerIdentifier = "iCloud.com.abdeen.strobe"
    static let zoneName = "Library"

    static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// The encoding of a book's word and complexity assets. A device skips
    /// books written in a newer format than it reads.
    static let bookFormat: Int64 = 1

    /// Chapter lists longer than this travel as an asset, keeping the record
    /// well under CloudKit's 1 MB limit (a PDF outline can be huge).
    static let maxInlineChapterBytes = 200_000

    enum RecordType {
        static let book = "Book"
        static let readingState = "ReadingState"
    }

    enum BookField {
        static let format = "format"
        static let title = "title"
        static let fileName = "fileName"
        static let dateAdded = "dateAdded"
        static let wordCount = "wordCount"
        /// JSON `[Chapter]`, when it fits in the record.
        static let chapters = "chapters"
        /// JSON `[Chapter]` as an asset, when it doesn't.
        static let chaptersAsset = "chaptersAsset"
        static let contentHash = "contentHash"
        /// `WordStorage` data, as an asset.
        static let words = "words"
        /// `ComplexityStorage` data, as an asset. Absent for books imported
        /// before complexity scores existed.
        static let complexity = "complexity"

        /// Every field. `CloudSchemaSeed` sets them all; a new field goes
        /// here too.
        static let all = [
            format, title, fileName, dateAdded, wordCount, chapters, chaptersAsset,
            contentHash, words, complexity,
        ]
    }

    enum StateField {
        static let currentWordIndex = "currentWordIndex"
        static let furthestWordIndex = "furthestWordIndex"
        static let wordsPerMinute = "wordsPerMinute"
        static let lastReadDate = "lastReadDate"
        static let modifiedAt = "modifiedAt"

        /// Every field. `CloudSchemaSeed` sets them all; a new field goes
        /// here too.
        static let all = [currentWordIndex, furthestWordIndex, wordsPerMinute, lastReadDate, modifiedAt]
    }
}

#if DEBUG
/// One record of each type with every field set, written the way sync
/// writes them. Saving them in the Development environment creates every
/// record type and field with the type and encryption sync uses, ready to
/// deploy to Production, which TestFlight and the App Store use. Production
/// never adds fields on its own, and sync only writes some fields for some
/// books (`chaptersAsset` only for huge chapter lists), so syncing real
/// books can miss one.
///
/// They live in a zone of their own, never the library's.
nonisolated enum CloudSchemaSeed {
    static let zoneName = "SchemaSeed"

    static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// The records, with their asset files written into `assetDirectory`.
    static func records(assetDirectory: URL) throws -> [CKRecord] {
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        func asset(_ data: Data, named name: String) throws -> CKAsset {
            let url = assetDirectory.appending(path: name)
            try data.write(to: url, options: .atomic)
            return CKAsset(fileURL: url)
        }

        let words = WordStorage.encode(["Strobe"])
        let chapters = [Chapter(title: "Strobe", wordIndex: 0)]
        let book = CKRecord(
            recordType: CloudSyncSchema.RecordType.book,
            recordID: CKRecord.ID(recordName: "seed-book", zoneID: zoneID)
        )
        BookRecordFields(
            title: "Strobe",
            fileName: "Strobe.txt",
            dateAdded: .now,
            wordCount: 1,
            chapters: chapters,
            contentHash: ContentFingerprint.of(words)
        ).write(to: book)
        book[CloudSyncSchema.BookField.words] = try asset(words, named: "words")
        book[CloudSyncSchema.BookField.complexity] = try asset(ComplexityStorage.encode([0.5]), named: "complexity")
        book[CloudSyncSchema.BookField.chaptersAsset] = try asset(JSONEncoder().encode(chapters), named: "chapters")

        let state = CKRecord(
            recordType: CloudSyncSchema.RecordType.readingState,
            recordID: CKRecord.ID(recordName: "seed-state", zoneID: zoneID)
        )
        StampedReadingPosition(
            position: ReadingPosition(currentWordIndex: 0, furthestWordIndex: 0, wordsPerMinute: 300, lastReadDate: .now),
            modifiedAt: .now
        ).write(to: state)

        return [book, state]
    }
}
#endif

/// One of a document's two records. The book record holds the content and
/// title, which rarely change; the reading state record holds the position,
/// which changes on every read. Keeping them apart means reading never
/// re-sends or re-downloads a book's words.
nonisolated struct CloudRecordKey: Hashable, Comparable {
    enum Kind: String, Comparable {
        case book
        case state

        static func < (lhs: Kind, rhs: Kind) -> Bool {
            lhs == .book && rhs == .state
        }
    }

    let kind: Kind
    let documentID: UUID

    init(_ kind: Kind, _ documentID: UUID) {
        self.kind = kind
        self.documentID = documentID
    }

    /// Parses `book-<UUID>` or `state-<UUID>`.
    init?(recordName: String) {
        let parts = recordName.split(separator: "-", maxSplits: 1)
        guard parts.count == 2,
              let kind = Kind(rawValue: String(parts[0])),
              let documentID = UUID(uuidString: String(parts[1])) else { return nil }
        self.init(kind, documentID)
    }

    init?(recordID: CKRecord.ID) {
        guard recordID.zoneID.zoneName == CloudSyncSchema.zoneName else { return nil }
        self.init(recordName: recordID.recordName)
    }

    var recordName: String { "\(kind.rawValue)-\(documentID.uuidString)" }

    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: CloudSyncSchema.zoneID)
    }

    var recordType: String {
        switch kind {
        case .book: CloudSyncSchema.RecordType.book
        case .state: CloudSyncSchema.RecordType.readingState
        }
    }

    static func < (lhs: CloudRecordKey, rhs: CloudRecordKey) -> Bool {
        (lhs.kind, lhs.documentID.uuidString) < (rhs.kind, rhs.documentID.uuidString)
    }
}

// MARK: - Reading position

/// The parts of a document that change as it's read.
nonisolated struct ReadingPosition: Codable, Equatable {
    var currentWordIndex: Int
    var furthestWordIndex: Int
    var wordsPerMinute: Int
    var lastReadDate: Date?

    /// Keeps the indices inside a document of `wordCount` words, in case a
    /// record carries a position the local words don't reach.
    func clamped(toWordCount wordCount: Int) -> ReadingPosition {
        let lastIndex = max(0, wordCount - 1)
        var position = self
        position.currentWordIndex = min(max(0, currentWordIndex), lastIndex)
        position.furthestWordIndex = min(max(0, furthestWordIndex), lastIndex)
        position.wordsPerMinute = max(1, wordsPerMinute)
        return position
    }
}

/// A reading position with the time its resume point was set, which decides
/// between two devices that both moved.
nonisolated struct StampedReadingPosition: Codable, Equatable {
    var position: ReadingPosition
    var modifiedAt: Date

    /// Combines two devices' positions for one book. The resume point and
    /// speed come from whichever was set later; the furthest point and the
    /// last-read date from whichever is further along, so progress never goes
    /// backward. The result doesn't depend on the argument order.
    static func merged(_ a: Self, _ b: Self) -> Self {
        let newer: Self
        if a.modifiedAt != b.modifiedAt {
            newer = a.modifiedAt > b.modifiedAt ? a : b
        } else {
            // Any fixed rule converges; prefer the position further along.
            let aKey = (a.position.currentWordIndex, a.position.wordsPerMinute)
            let bKey = (b.position.currentWordIndex, b.position.wordsPerMinute)
            newer = aKey >= bKey ? a : b
        }
        let lastReadDate: Date? = switch (a.position.lastReadDate, b.position.lastReadDate) {
        case let (x?, y?): max(x, y)
        case let (x, y): x ?? y
        }
        return Self(
            position: ReadingPosition(
                currentWordIndex: newer.position.currentWordIndex,
                furthestWordIndex: max(a.position.furthestWordIndex, b.position.furthestWordIndex),
                wordsPerMinute: newer.position.wordsPerMinute,
                lastReadDate: lastReadDate
            ),
            modifiedAt: newer.modifiedAt
        )
    }
}

// MARK: - Record fields

/// A book record's fields, apart from its word and complexity assets.
nonisolated struct BookRecordFields: Equatable {
    var title: String
    var fileName: String
    var dateAdded: Date
    var wordCount: Int
    var chapters: [Chapter]
    /// ``ContentFingerprint`` of the words, used to spot a book imported on
    /// two devices before they synced.
    var contentHash: String
    var format: Int64 = CloudSyncSchema.bookFormat

    /// Writes every field. Encrypted, so with Advanced Data Protection only
    /// the user's devices can read them. (Assets are always encrypted.)
    func write(to record: CKRecord) {
        typealias Field = CloudSyncSchema.BookField
        record.encryptedValues[Field.format] = format
        record.encryptedValues[Field.title] = title
        record.encryptedValues[Field.fileName] = fileName
        record.encryptedValues[Field.dateAdded] = dateAdded
        record.encryptedValues[Field.wordCount] = Int64(wordCount)
        record.encryptedValues[Field.contentHash] = contentHash
        // Longer lists go in `chaptersAsset`; see `BookUpload`.
        if let chapterData = try? JSONEncoder().encode(chapters),
           chapterData.count <= CloudSyncSchema.maxInlineChapterBytes {
            record.encryptedValues[Field.chapters] = chapterData
        }
    }

    init(
        title: String,
        fileName: String,
        dateAdded: Date,
        wordCount: Int,
        chapters: [Chapter],
        contentHash: String,
        format: Int64 = CloudSyncSchema.bookFormat
    ) {
        self.title = title
        self.fileName = fileName
        self.dateAdded = dateAdded
        self.wordCount = wordCount
        self.chapters = chapters
        self.contentHash = contentHash
        self.format = format
    }

    init?(record: CKRecord) {
        typealias Field = CloudSyncSchema.BookField
        guard record.recordType == CloudSyncSchema.RecordType.book,
              let title = record.encryptedValues[Field.title] as? String,
              let fileName = record.encryptedValues[Field.fileName] as? String,
              let dateAdded = record.encryptedValues[Field.dateAdded] as? Date,
              let wordCount = record.encryptedValues[Field.wordCount] as? Int64,
              let contentHash = record.encryptedValues[Field.contentHash] as? String else { return nil }
        let chapters = (record.encryptedValues[Field.chapters] as? Data)
            .flatMap { try? JSONDecoder().decode([Chapter].self, from: $0) } ?? []
        self.init(
            title: title,
            fileName: fileName,
            dateAdded: dateAdded,
            wordCount: Int(wordCount),
            chapters: chapters,
            contentHash: contentHash,
            format: record.encryptedValues[Field.format] as? Int64 ?? CloudSyncSchema.bookFormat
        )
    }

    /// The title alone, from a record that may carry only changed fields.
    static func title(in record: CKRecord) -> String? {
        record.encryptedValues[CloudSyncSchema.BookField.title] as? String
    }
}

nonisolated extension StampedReadingPosition {
    func write(to record: CKRecord) {
        typealias Field = CloudSyncSchema.StateField
        record.encryptedValues[Field.currentWordIndex] = Int64(position.currentWordIndex)
        record.encryptedValues[Field.furthestWordIndex] = Int64(position.furthestWordIndex)
        record.encryptedValues[Field.wordsPerMinute] = Int64(position.wordsPerMinute)
        record.encryptedValues[Field.modifiedAt] = modifiedAt
        if let lastReadDate = position.lastReadDate {
            record.encryptedValues[Field.lastReadDate] = lastReadDate
        }
    }

    init?(record: CKRecord) {
        typealias Field = CloudSyncSchema.StateField
        guard record.recordType == CloudSyncSchema.RecordType.readingState,
              let current = record.encryptedValues[Field.currentWordIndex] as? Int64,
              let furthest = record.encryptedValues[Field.furthestWordIndex] as? Int64,
              let wordsPerMinute = record.encryptedValues[Field.wordsPerMinute] as? Int64,
              let modifiedAt = record.encryptedValues[Field.modifiedAt] as? Date else { return nil }
        self.init(
            position: ReadingPosition(
                currentWordIndex: Int(current),
                furthestWordIndex: Int(furthest),
                wordsPerMinute: Int(wordsPerMinute),
                lastReadDate: record.encryptedValues[Field.lastReadDate] as? Date
            ),
            modifiedAt: modifiedAt
        )
    }
}

// MARK: - Helpers

/// A record's system fields (its ID and change tag) without its values,
/// which is all a later save needs to update it in place.
nonisolated enum CloudRecordArchive {
    static func systemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }
}

/// SHA-256 of a document's words, in hex.
nonisolated enum ContentFingerprint {
    static func of(_ wordsBlob: Data) -> String {
        SHA256.hash(data: wordsBlob).map { String(format: "%02x", $0) }.joined()
    }
}

/// A book's assets written out for upload.
nonisolated struct BookUpload {
    let wordsURL: URL?
    let complexityURL: URL?
    /// Only for chapter lists too long for the record.
    let chaptersURL: URL?
    let contentHash: String
    let byteCount: Int

    /// Where upload files wait until their send finishes. CloudKit reads
    /// them during the send, so they're only cleared between sends.
    static var directory: URL {
        FileManager.default.temporaryDirectory.appending(path: "CloudSyncUploads", directoryHint: .isDirectory)
    }

    static func prepare(documentID: UUID, words: Data, complexity: Data?, chapters: [Chapter]) throws -> BookUpload {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        func write(_ data: Data, as fileExtension: String) throws -> URL {
            let url = directory.appending(path: "\(documentID.uuidString).\(fileExtension)")
            try data.write(to: url, options: .atomic)
            return url
        }
        let wordsURL = try words.isEmpty ? nil : write(words, as: "words")
        let complexityURL = try complexity.flatMap { $0.isEmpty ? nil : try write($0, as: "complexity") }
        let chapterData = try JSONEncoder().encode(chapters)
        let chaptersURL = try chapterData.count > CloudSyncSchema.maxInlineChapterBytes
            ? write(chapterData, as: "chapters")
            : nil
        return BookUpload(
            wordsURL: wordsURL,
            complexityURL: complexityURL,
            chaptersURL: chaptersURL,
            contentHash: ContentFingerprint.of(words),
            byteCount: words.count + (complexity?.count ?? 0) + (chaptersURL == nil ? 0 : chapterData.count)
        )
    }

    static func removeAllFiles() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A downloaded book's words and complexity scores, checked against its record.
nonisolated struct BookContent {
    let words: Data
    let complexity: Data?
    /// Chapters that came as an asset; nil when they were in the record.
    var chapters: [Chapter]?

    /// Reads the asset files CloudKit downloaded. Returns nil when the words
    /// are missing or don't match the record's fingerprint.
    static func load(
        wordsURL: URL?,
        complexityURL: URL?,
        chaptersURL: URL? = nil,
        fields: BookRecordFields
    ) -> BookContent? {
        let words: Data
        if let wordsURL {
            guard let data = try? Data(contentsOf: wordsURL) else { return nil }
            words = data
        } else {
            guard fields.wordCount == 0 else { return nil }
            words = Data()
        }
        guard ContentFingerprint.of(words) == fields.contentHash else { return nil }
        // Scores that don't line up with the words are dropped; the reader
        // recomputes them.
        let complexity = complexityURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { $0.count == fields.wordCount * MemoryLayout<Float>.size ? $0 : nil }
        let chapters = chaptersURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([Chapter].self, from: $0) }
        return BookContent(words: words, complexity: complexity, chapters: chapters)
    }

    /// Splits books, in order, into runs saved together: each run's `sizes`
    /// add up to at most `limit`, except a single book larger than that,
    /// which is saved on its own. Books of size 0 (already here) join the
    /// run they fall in.
    static func saveRanges(sizes: [Int], limit: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var total = 0
        for (index, size) in sizes.enumerated() {
            if index > start, size > 0, total + size > limit {
                ranges.append(start..<index)
                start = index
                total = 0
            }
            total += size
        }
        if start < sizes.count {
            ranges.append(start..<sizes.count)
        }
        return ranges
    }
}
