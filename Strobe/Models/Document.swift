import Foundation
import SwiftData

/// A persisted document in the user's library.
///
/// Words are stored as a newline-delimited blob in external storage
/// (`wordsBlob`) to keep the SQLite database lean. The legacy `words`
/// array is retained only for migration from older versions.
@Model
final class Document {
    @Attribute(.unique) var id: UUID
    var title: String
    var fileName: String
    var dateAdded: Date
    var lastReadDate: Date?
    /// Security-scoped bookmark captured at import. Not currently consumed
    /// anywhere — retained (and still captured for new imports) so a future
    /// re-import/refresh feature can re-access the original file without
    /// re-prompting. Empty for documents created from typed/pasted text.
    var bookmarkData: Data
    /// Legacy word storage — empty for new documents. Retained for SwiftData
    /// schema compatibility with pre-blob versions. See ``compactWordStorageIfNeeded()``.
    var words: [String]
    /// Newline-delimited word data stored externally to avoid bloating the database.
    @Attribute(.externalStorage) var wordsBlob: Data?
    /// Per-word complexity scores stored as raw Float binary data.
    @Attribute(.externalStorage) var complexityBlob: Data?
    var chapters: [Chapter]
    var currentWordIndex: Int
    /// The furthest word index ever reached, used for progress display only —
    /// resuming uses `currentWordIndex`. Never decreased by backward
    /// navigation or "Read Again". The default lets stores created before
    /// this property existed migrate lightweightly (no custom migration plan).
    var furthestWordIndex: Int = 0
    var wordsPerMinute: Int

    /// Stored separately so the list view can display word count
    /// without deserializing the entire words array.
    var wordCount: Int

    /// In-memory cache of the decoded words array, invalidated on compaction.
    @Transient private var cachedWords: [String]?
    /// In-memory cache of decoded complexity scores.
    @Transient private var cachedComplexity: [Float]?

    /// The document's words, resolved from `wordsBlob` (preferred) or the legacy `words` array.
    /// Results are cached in memory for the lifetime of the model object.
    var readingWords: [String] {
        if let cachedWords {
            return cachedWords
        }

        let resolvedWords: [String]
        if let wordsBlob, !wordsBlob.isEmpty {
            resolvedWords = WordStorage.decode(wordsBlob)
        } else {
            resolvedWords = words
        }

        cachedWords = resolvedWords
        return resolvedWords
    }

    /// The document's per-word complexity scores, decoded from `complexityBlob`.
    /// Returns `nil` if no complexity data exists (legacy documents).
    var complexityScores: [Float]? {
        if let cachedComplexity {
            return cachedComplexity
        }

        guard let complexityBlob, !complexityBlob.isEmpty else { return nil }
        let decoded = ComplexityStorage.decode(complexityBlob)
        cachedComplexity = decoded
        return decoded
    }

    /// Asynchronously resolves ``readingWords``, decoding the blob off the
    /// main actor so opening a large document doesn't hitch the UI.
    func loadReadingWordsAsync() async -> [String] {
        if let cachedWords {
            return cachedWords
        }
        let resolvedWords: [String]
        if let wordsBlob, !wordsBlob.isEmpty {
            let blob = wordsBlob
            resolvedWords = await Task.detached(priority: .userInitiated) {
                WordStorage.decode(blob)
            }.value
        } else {
            resolvedWords = words
        }
        cachedWords = resolvedWords
        return resolvedWords
    }

    /// Asynchronously resolves ``complexityScores``, decoding the blob off
    /// the main actor.
    func loadComplexityScoresAsync() async -> [Float]? {
        if let cachedComplexity {
            return cachedComplexity
        }
        guard let complexityBlob, !complexityBlob.isEmpty else { return nil }
        let blob = complexityBlob
        let decoded = await Task.detached(priority: .userInitiated) {
            ComplexityStorage.decode(blob)
        }.value
        cachedComplexity = decoded
        return decoded
    }

    /// Stores freshly computed complexity scores (a backfill for documents
    /// imported before complexity timing existed) and refreshes the cache.
    /// The reading-time estimate's pace was timed without them, so it's
    /// dropped too.
    func storeComplexityScores(_ scores: [Float]) {
        complexityBlob = scores.isEmpty ? nil : ComplexityStorage.encode(scores)
        cachedComplexity = scores.isEmpty ? nil : scores
        ReadingPace.shared.forget(id)
    }

    /// Migrates words from the legacy `words` array to the `wordsBlob` external storage format.
    /// No-op if `wordsBlob` already exists or the legacy array is empty.
    func compactWordStorageIfNeeded() {
        guard wordsBlob == nil, !words.isEmpty else { return }
        let legacyCount = words.count
        wordsBlob = WordStorage.encode(words)
        words.removeAll(keepingCapacity: false)
        wordCount = legacyCount
        cachedWords = nil
    }

    /// The furthest-read index used for progress display. Floors at
    /// `currentWordIndex` so documents saved before `furthestWordIndex`
    /// existed (migrated with 0) still report the progress they had.
    var displayedFurthestWordIndex: Int {
        max(furthestWordIndex, currentWordIndex)
    }

    /// Reading progress as a value from 0.0 to 1.0, measured against the
    /// furthest position ever reached — backing up to re-read doesn't
    /// lower it.
    var progress: Double {
        let furthest = displayedFurthestWordIndex
        guard wordCount > 1 else {
            // A single-word document can never advance its indices past 0,
            // so "has it been read" is the completion signal instead.
            if wordCount == 1 {
                return (lastReadDate != nil || furthest > 0) ? 1 : 0
            }
            return 0
        }
        return Double(furthest) / Double(wordCount - 1)
    }

    /// Folds the reader's outgoing position into the persisted state.
    ///
    /// The furthest-read marker only ever advances — leaving the reader
    /// after navigating backward (chapter peek, passage tap, scrubbing,
    /// "Read Again") must not erase display progress. The outgoing
    /// `currentWordIndex` is folded in so documents saved before the marker
    /// existed adopt their old position as the floor. `furthestIndex` is the
    /// furthest word the reader played to while open, which can lie beyond
    /// both positions after reading on and then going back.
    func recordPosition(currentIndex: Int, furthestIndex: Int = 0, wordsPerMinute: Int, touchLastReadDate: Bool) {
        furthestWordIndex = max(furthestWordIndex, currentWordIndex, currentIndex, furthestIndex)
        currentWordIndex = currentIndex
        self.wordsPerMinute = wordsPerMinute
        if touchLastReadDate {
            lastReadDate = Date()
        }
    }

    init(
        title: String,
        fileName: String,
        bookmarkData: Data,
        words: [String],
        complexityScores: [Float] = [],
        chapters: [Chapter] = [],
        currentWordIndex: Int = 0,
        wordsPerMinute: Int = 300
    ) {
        self.id = UUID()
        self.title = title
        self.fileName = fileName
        self.bookmarkData = bookmarkData
        self.wordsBlob = WordStorage.encode(words)
        self.complexityBlob = complexityScores.isEmpty ? nil : ComplexityStorage.encode(complexityScores)
        self.words = []
        self.chapters = chapters
        self.wordCount = words.count
        self.currentWordIndex = currentWordIndex
        self.furthestWordIndex = currentWordIndex
        self.wordsPerMinute = wordsPerMinute
        self.dateAdded = Date()
        self.cachedWords = words
        self.cachedComplexity = complexityScores.isEmpty ? nil : complexityScores
    }

    /// Creates a document from pre-encoded storage blobs. Import flows encode
    /// on their background task and use this so inserting a book-length
    /// document doesn't pay ~2 MB of blob encoding on the main thread.
    init(
        title: String,
        fileName: String,
        bookmarkData: Data,
        wordsBlob: Data,
        wordCount: Int,
        complexityBlob: Data?,
        chapters: [Chapter] = [],
        wordsPerMinute: Int = 300
    ) {
        self.id = UUID()
        self.title = title
        self.fileName = fileName
        self.bookmarkData = bookmarkData
        self.wordsBlob = wordsBlob
        self.complexityBlob = complexityBlob
        self.words = []
        self.chapters = chapters
        self.wordCount = wordCount
        self.currentWordIndex = 0
        self.furthestWordIndex = 0
        self.wordsPerMinute = wordsPerMinute
        self.dateAdded = Date()
    }
}
