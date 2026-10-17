import AppIntents
import Foundation
import SwiftData

/// A library document as Shortcuts and Siri see it.
///
/// The App Intents types here aren't marked `nonisolated`. Conforming to
/// the framework's `Sendable` protocols already makes them nonisolated, and
/// an explicit mark draws a warning on `@Property` and `@Parameter` storage
/// (an error in Swift 6).
struct DocumentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Document")
    static let defaultQuery = DocumentQuery()

    let id: UUID

    @Property(title: "Title")
    var title: String

    @Property(title: "Percent Read")
    var percentRead: Int

    @Property(title: "Minutes Left")
    var minutesLeft: Int

    /// "42% · 3 hr 12 min left", as the Continue Reading card puts it.
    let statusLine: String
    let symbolName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(statusLine)",
            image: DisplayRepresentation.Image(systemName: symbolName)
        )
    }
}

extension DocumentEntity {
    @MainActor
    init(document: Document) {
        let status = document.readingStatus
        // At the document's pace when it's known. Listing documents doesn't
        // wait for any to be worked out.
        let remainingMinutes = ReadingPace.shared.remainingMinutes(for: document)
        let timeLeft = ReadingTime.label(minutes: remainingMinutes)
        id = document.id
        switch status {
        case .new:
            statusLine = "\(status.label) · \(timeLeft)"
        case .inProgress:
            statusLine = "\(status.label) · \(timeLeft) left"
        case .finished:
            statusLine = status.label
        }
        switch document.kind {
        case .epub: symbolName = "book.closed"
        case .pdf: symbolName = "doc.richtext"
        case .text: symbolName = "doc.plaintext"
        case .web: symbolName = "globe"
        }
        title = document.title
        percentRead = status.percent
        minutesLeft = status == .finished ? 0 : remainingMinutes
    }
}

/// Finds library documents for Shortcuts and Siri: by ID, by title, and as
/// suggestions, most recently read or added first.
struct DocumentQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [DocumentEntity] {
        let wanted = Set(identifiers)
        return try IntentLibrary.documents()
            .filter { wanted.contains($0.id) }
            .map { DocumentEntity(document: $0) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [DocumentEntity] {
        try IntentLibrary.documentsBySuggestion()
            .filter { $0.title.localizedStandardContains(string) }
            .map { DocumentEntity(document: $0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [DocumentEntity] {
        try IntentLibrary.documentsBySuggestion().map { DocumentEntity(document: $0) }
    }
}

/// The library as App Intents reach it. Intents run in the app's process,
/// sometimes before any window opens, so they use the app's own container
/// and its main context. Their saves then reach the library's views,
/// the widget, and sync just as the app's own do.
enum IntentLibrary {
    static func context() throws -> ModelContext {
        guard let container = StrobeApp.sharedBootstrap.container else {
            throw LibraryIntentError.libraryUnavailable
        }
        return container.mainContext
    }

    static func documents() throws -> [Document] {
        try context().fetch(FetchDescriptor<Document>())
    }

    /// Every document, most recently read or added first.
    static func documentsBySuggestion() throws -> [Document] {
        try documents().sorted {
            ($0.lastReadDate ?? $0.dateAdded) > ($1.lastReadDate ?? $1.dateAdded)
        }
    }

    static func document(id: UUID) throws -> Document {
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate<Document> { $0.id == id })
        guard let document = try context().fetch(descriptor).first else {
            throw LibraryIntentError.documentNotFound
        }
        return document
    }
}

enum LibraryIntentError: Error, CustomLocalizedStringResourceConvertible {
    case libraryUnavailable
    case documentNotFound
    case noReadableText
    case nothingInProgress

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .libraryUnavailable: "Strobe couldn't open your library."
        case .documentNotFound: "That document isn't in your library anymore."
        case .noReadableText: "There's no readable text to read."
        case .nothingInProgress: "You aren't reading anything right now."
        }
    }
}
