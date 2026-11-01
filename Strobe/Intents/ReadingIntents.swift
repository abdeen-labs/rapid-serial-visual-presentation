import AppIntents
import Foundation
import SwiftData

/// Opens the document to pick up next, the one the Continue Reading widget
/// shows, or the library when everything is read.
struct ContinueReadingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Reading"
    static let description = IntentDescription(
        "Opens the document you were last reading where you left off, or the newest one you haven't started."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let documents = try IntentLibrary.documents()
        if let document = Document.upNext(in: documents) {
            AppRouter.shared.open(.reader(documentID: document.id))
        } else {
            AppRouter.shared.open(.library)
        }
        return .result()
    }
}

/// Opens a document's reader at its saved position.
struct OpenDocumentIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Document"
    static let description = IntentDescription("Opens a document in the reader where you left off.")
    static let openAppWhenRun = true

    @Parameter(title: "Document")
    var target: DocumentEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.open(.reader(documentID: target.id))
        return .result()
    }
}

/// Adds text to the library as a new document and opens it in the reader,
/// for reading text from other apps through Shortcuts.
struct ReadTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Speed Read Text"
    static let description = IntentDescription(
        "Adds text to your library as a new document and opens it in the reader."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Text", requestValueDialog: "What do you want to read?")
    var text: String

    @Parameter(title: "Title", description: "Leave empty to title it with the date and time.")
    var documentTitle: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Speed read \(\.$text)") {
            \.$documentTitle
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<DocumentEntity> {
        let context = try IntentLibrary.context()
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tokenizing and scoring a long text is slow; keep it off the main
        // actor, as New Text does.
        let prepared = await Task.detached(priority: .userInitiated) {
            TextImport.prepare(trimmedText)
        }.value
        guard let prepared else {
            throw LibraryIntentError.noReadableText
        }

        let wordsPerMinute = UserDefaults.standard.object(forKey: ReaderSettings.Keys.defaultWPM) as? Int
            ?? ReaderSettings.Defaults.defaultWPM
        let document = TextImport.makeDocument(
            from: prepared,
            title: documentTitle ?? "",
            wordsPerMinute: wordsPerMinute
        )
        context.insert(document)
        do {
            try context.save()
        } catch {
            context.delete(document)
            throw error
        }

        AppRouter.shared.open(.reader(documentID: document.id))
        return .result(value: DocumentEntity(document: document))
    }
}

/// Says how far along a document is and how long it takes to finish, and
/// returns the percentage read.
struct GetReadingProgressIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Reading Progress"
    static let description = IntentDescription(
        "Tells you how far along you are in a document and how long it takes to finish, and returns the percentage read."
    )

    @Parameter(title: "Document", description: "Leave empty for the document you're reading now.")
    var document: DocumentEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get reading progress for \(\.$document)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let target: Document
        if let document {
            target = try IntentLibrary.document(id: document.id)
        } else {
            let documents = try IntentLibrary.documents()
            guard let current = Document.mostRecentlyRead(in: documents) else {
                throw LibraryIntentError.nothingInProgress
            }
            target = current
        }

        let status = target.readingStatus
        let title = target.title
        let timeLeft = ReadingTime.spokenLabel(minutes: target.remainingMinutes)
        let dialog: IntentDialog
        switch status {
        case .new:
            dialog = IntentDialog("You haven't started \(title) yet. It takes about \(timeLeft) to read.")
        case .inProgress(let percent):
            dialog = IntentDialog("You're \(percent) percent through \(title), with about \(timeLeft) left.")
        case .finished:
            dialog = IntentDialog("You've finished \(title).")
        }
        return .result(value: status.percent, dialog: dialog)
    }
}
