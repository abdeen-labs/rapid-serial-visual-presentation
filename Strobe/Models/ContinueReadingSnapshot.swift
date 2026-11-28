import Foundation
import ImageIO

/// What the Continue Reading widget shows: the document to pick up next, as
/// the app last saved it.
///
/// The app writes the snapshot to the App Group's defaults after every save
/// to the library (see `LibraryObserver`). The widget extension can't open
/// the library's store, so it reads the snapshot instead. The widget
/// extension compiles this file too, so it stays free of app-only types.
nonisolated struct ContinueReadingSnapshot: Codable, Equatable {
    /// The widget that shows the snapshot. The app reloads it when the
    /// snapshot changes.
    static let widgetKind = "ContinueReading"
    static let storageKey = "continueReadingSnapshot"

    /// The document to pick up, or nil when there's nothing left to read.
    var item: Item?
    /// True when the library has no documents at all. The empty widget uses
    /// it to tell an empty library from one that's all read.
    var libraryIsEmpty: Bool

    nonisolated struct Item: Codable, Equatable {
        let id: UUID
        let title: String
        /// The stored file name, which gives the document's kind.
        let fileName: String
        /// Reading progress from 0 to 1, measured as the library measures it.
        let progress: Double
        /// The chapter the resume position falls in.
        let chapterTitle: String?
        /// Minutes to finish from the resume position.
        let remainingMinutes: Int
        /// The document's text from the start of the sentence it resumes in
        /// (`ResumePreview`), for the medium widget. Nil when it has none, or
        /// in a snapshot saved before previews.
        var preview: String? = nil
        /// The document's cover as a thumbnail file in
        /// ``SharedContainer/widgetCoversURL``, or nil for the generated
        /// cover. Named for the document and its cover, so a new document
        /// or a changed cover reloads the widget.
        var coverFileName: String? = nil

        var kind: DocumentKind { DocumentKind(fileName: fileName) }
        var status: ReadingStatus { ReadingStatus(progress: progress) }
        var link: AppLink { .reader(documentID: id) }

        /// Whether the preview is mostly Arabic script, so it reads right to
        /// left whatever the interface's direction.
        var previewIsRightToLeft: Bool {
            guard let preview else { return false }
            var arabic = 0
            var letters = 0
            for scalar in preview.unicodeScalars where scalar.properties.isAlphabetic {
                letters += 1
                if (0x0600...0x06FF).contains(scalar.value) || (0x0750...0x077F).contains(scalar.value)
                    || (0x08A0...0x08FF).contains(scalar.value) || (0xFB50...0xFDFF).contains(scalar.value)
                    || (0xFE70...0xFEFF).contains(scalar.value) {
                    arabic += 1
                }
            }
            return letters > 0 && arabic * 2 > letters
        }

        /// The name of the thumbnail the app writes for `documentID`'s
        /// cover with this fingerprint (`Document.coverFingerprint`).
        static func coverFileName(for documentID: UUID, fingerprint: String?) -> String {
            guard let fingerprint, !fingerprint.isEmpty else { return "\(documentID.uuidString).jpg" }
            return "\(documentID.uuidString)-\(fingerprint.prefix(12)).jpg"
        }

        /// The cover thumbnail, or nil when there's none or it can't be
        /// read, which leaves the generated cover.
        func loadCover() -> CGImage? {
            guard let coverFileName,
                  let url = SharedContainer.widgetCoversURL?.appending(path: coverFileName),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(source) > 0 else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
    }

    /// The saved snapshot, or nil if none is saved or it can't be read.
    static func load(from defaults: UserDefaults) -> ContinueReadingSnapshot? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(ContinueReadingSnapshot.self, from: data)
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

extension ReadingStatus {
    /// The whole percentage read: 0 when new, 100 when finished.
    nonisolated var percent: Int {
        switch self {
        case .new: 0
        case .inProgress(let percent): percent
        case .finished: 100
        }
    }
}
