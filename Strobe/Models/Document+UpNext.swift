import Foundation

extension Document {
    /// The most recently read document that's started but not finished: the
    /// one the library's Continue Reading card offers.
    static func mostRecentlyRead(in documents: [Document]) -> Document? {
        documents
            .filter { $0.lastReadDate != nil && $0.readingStatus.isInProgress }
            .max { ($0.lastReadDate ?? .distantPast) < ($1.lastReadDate ?? .distantPast) }
    }

    /// The document to pick up next: the ``mostRecentlyRead(in:)`` one, or
    /// else the newest one not yet started. Nil when everything is read. The
    /// Continue Reading widget and shortcut open this one.
    static func upNext(in documents: [Document]) -> Document? {
        mostRecentlyRead(in: documents)
            ?? documents
                .filter { $0.readingStatus == .new }
                .max { $0.dateAdded < $1.dateAdded }
    }
}

extension ContinueReadingSnapshot {
    /// The snapshot of a library: its ``Document/upNext(in:)`` document.
    @MainActor
    init(documents: [Document]) {
        self.init(
            item: Document.upNext(in: documents).map { Item(document: $0) },
            libraryIsEmpty: documents.isEmpty
        )
    }
}

extension ContinueReadingSnapshot.Item {
    @MainActor
    init(document: Document) {
        self.init(
            id: document.id,
            title: document.title,
            fileName: document.fileName,
            progress: document.progress,
            chapterTitle: ChapterTimeline(document.chapters).chapter(containing: document.currentWordIndex)?.title,
            remainingMinutes: document.remainingMinutes
        )
    }
}
