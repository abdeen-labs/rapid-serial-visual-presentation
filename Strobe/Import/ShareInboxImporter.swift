import Foundation
import SwiftData
import SwiftUI
import os

/// Adds what the share extension left in the ``ShareInbox`` to the library.
///
/// The app owns one, so several windows never import the same item twice.
/// It imports when a scene becomes active and when the extension posts
/// ``ShareInbox/didChangeNotification`` while the app is running.
@MainActor
final class ShareInboxImporter {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.abdeen.strobe",
        category: "ShareInboxImporter"
    )

    private let container: ModelContainer
    private let inbox: ShareInbox?
    private var isImporting = false
    /// A request that arrived mid-import, for items added since it began.
    private var needsAnotherPass = false

    init(container: ModelContainer, inbox: ShareInbox? = .shared) {
        self.container = container
        self.inbox = inbox
        guard inbox != nil else { return }
        // The app keeps its importer for its whole life, so the observer is
        // never removed; retaining it keeps the pointer valid regardless.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passRetained(self).toOpaque(),
            shareInboxDidChange,
            ShareInbox.didChangeNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        // Settings change while the app is open, so republish on the way
        // out as well as on the way in.
        ShareInbox.publishReadingSpeed(Self.defaultWordsPerMinute)
        if phase == .active {
            importPendingItems()
        }
    }

    func importPendingItems() {
        guard let inbox else { return }
        guard !isImporting else {
            needsAnotherPass = true
            return
        }
        isImporting = true
        Task {
            repeat {
                needsAnotherPass = false
                await importItems(from: inbox)
            } while needsAnotherPass
            isImporting = false
        }
    }

    private func importItems(from inbox: ShareInbox) async {
        let cleaningLevel = TextCleaningLevel.resolve(
            UserDefaults.standard.string(forKey: TextCleaningLevel.storageKey) ?? ""
        )
        let wordsPerMinute = Self.defaultWordsPerMinute
        let pending = await Task.detached(priority: .userInitiated) {
            inbox.pendingItems().map { item in
                (item: item, prepared: TextImport.prepare(ShareInboxImporter.readableText(of: item, cleaningLevel: cleaningLevel)))
            }
        }.value

        let context = container.mainContext
        for (item, prepared) in pending {
            guard let prepared else {
                // The extension checks for words before offering Add, so
                // cleaning left nothing to read. Retrying won't change that.
                Self.logger.error("Discarding shared item with no readable words")
                inbox.remove(item)
                continue
            }
            let document = TextImport.makeDocument(
                from: prepared,
                title: item.title,
                // A page keeps its address, which the library labels WEB.
                fileName: item.sourceURL?.absoluteString,
                // Ordered in the library by when it was shared.
                dateAdded: item.dateShared,
                wordsPerMinute: wordsPerMinute
            )
            context.insert(document)
            do {
                try context.save()
                inbox.remove(item)
            } catch {
                // Left in the inbox to try again on the next activation.
                context.delete(document)
                Self.logger.error("Could not save shared item: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The text to add for `item`. A page's article is cleaned like a text
    /// file, since it can carry page furniture; text the person chose is
    /// kept as shared, like New Text.
    nonisolated static func readableText(of item: SharedItem, cleaningLevel: TextCleaningLevel) -> String {
        switch item.source {
        // Line ends first: the cleaner splits at every newline character, so
        // a `\r\n` would leave a blank line, which ends a paragraph.
        case .webPage: TextCleaner.cleanText(PlainTextParagraphs.normalizingLineEnds(item.text), level: cleaningLevel)
        case .text: item.text
        }
    }

    private static var defaultWordsPerMinute: Int {
        UserDefaults.standard.object(forKey: ReaderSettings.Keys.defaultWPM) as? Int
            ?? ReaderSettings.Defaults.defaultWPM
    }
}

/// Hears the extension's ``ShareInbox/didChangeNotification``. A C callback
/// can't capture, so the importer arrives as the observer pointer.
nonisolated private func shareInboxDidChange(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    guard let observer else { return }
    let importer = Unmanaged<ShareInboxImporter>.fromOpaque(observer).takeUnretainedValue()
    Task { @MainActor in
        importer.importPendingItems()
    }
}
