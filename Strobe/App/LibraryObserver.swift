import Foundation
import SwiftData
import WidgetKit
import AppIntents

/// Keeps what Strobe shows outside the app in step with the library: the
/// Continue Reading widget's snapshot and cover thumbnail, and the document
/// titles Siri recognizes in shortcut phrases.
///
/// Refreshes after every save to the library, from any context. Reading
/// progress, imports, renames, deletions, and synced changes all save.
final class LibraryObserver {
    private static var current: LibraryObserver?

    private let container: ModelContainer
    private var saveObserver: NSObjectProtocol?
    /// The titles Siri last learned, so they're only sent again after a
    /// change.
    private var shortcutTitles: [UUID: String]?
    /// Refreshes once the up-next document's preview is worked out.
    private var previewTask: Task<Void, Never>?
    /// The up-next document and cover (`Document.coverFingerprint`) the
    /// widget's thumbnail was settled for, and the thumbnail's file name
    /// (nil for the generated cover). Nil until the first refresh settles it.
    private var widgetCover: (documentID: UUID?, fingerprint: String?, fileName: String?)?
    /// The thumbnail being written, by file name.
    private var writingCover: String?
    /// Thumbnails that couldn't be made, by file name, so they aren't
    /// tried again on every save.
    private var unwritableCovers: Set<String> = []

    /// Starts observing the library, once per launch.
    static func start(container: ModelContainer) {
        guard current == nil else { return }
        let observer = LibraryObserver(container: container)
        current = observer
        observer.observeSaves()
        // Deferred so the first fetch doesn't delay launch. It also writes a
        // snapshot for a widget added before the app ever saved one.
        Task { observer.refresh() }
    }

    private init(container: ModelContainer) {
        self.container = container
    }

    private func observeSaves() {
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            // Main-context saves refresh right away. A refresh that waited
            // for the next pass of the main queue would be lost when the
            // reader saves while macOS is quitting.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self.refresh() }
            } else {
                Task { @MainActor in self.refresh() }
            }
        }
    }

    private func refresh() {
        guard let documents = try? container.mainContext.fetch(FetchDescriptor<Document>()) else { return }
        var snapshot = ContinueReadingSnapshot(documents: documents)
        addPreview(to: &snapshot, from: documents)
        if var item = snapshot.item {
            item.coverFileName = widgetCoverFileName(for: documents.first { $0.id == item.id })
            snapshot.item = item
        } else {
            _ = widgetCoverFileName(for: nil)
        }
        publish(snapshot)
        updateShortcutTitlesIfNeeded(for: documents)
    }

    /// Adds the up-next document's ``ResumePreview``. A new resume position
    /// publishes at once with the preview it had, and again once the new
    /// one is worked out.
    private func addPreview(to snapshot: inout ContinueReadingSnapshot, from documents: [Document]) {
        guard let id = snapshot.item?.id,
              let document = documents.first(where: { $0.id == id }) else { return }
        let previews = ResumePreviews.shared
        snapshot.item?.preview = previews.preview(for: document)
        guard !previews.isCurrent(for: document) else { return }
        previews.prepare(document)
        previewTask?.cancel()
        previewTask = Task {
            await previews.waitForPending(id)
            guard !Task.isCancelled else { return }
            self.refresh()
        }
    }

    // MARK: - Widget cover

    /// The cover thumbnail for the up-next `document`, if it's written.
    /// When the up-next document or its cover changes, this writes the
    /// thumbnail off the main actor and refreshes again once it's there,
    /// removing the last one's. The file is named for the cover, so one
    /// written on an earlier launch still holds.
    private func widgetCoverFileName(for document: Document?) -> String? {
        let fingerprint = document?.coverFingerprint
        if let widgetCover, widgetCover.documentID == document?.id, widgetCover.fingerprint == fingerprint {
            return widgetCover.fileName
        }
        guard let document, let directory = SharedContainer.widgetCoversURL else {
            settleWidgetCover(documentID: document?.id, fingerprint: fingerprint, fileName: nil)
            return nil
        }
        let fileName = ContinueReadingSnapshot.Item.coverFileName(for: document.id, fingerprint: fingerprint)
        // Without a fingerprint there may be no cover, which is read below.
        if fingerprint != nil, FileManager.default.fileExists(atPath: directory.appending(path: fileName).path) {
            settleWidgetCover(documentID: document.id, fingerprint: fingerprint, fileName: fileName)
            return fileName
        }
        guard writingCover != fileName else { return nil }
        // Read once for each new up-next document or cover.
        guard !unwritableCovers.contains(fileName),
              let cover = document.coverImageData, !cover.isEmpty else {
            settleWidgetCover(documentID: document.id, fingerprint: fingerprint, fileName: nil)
            return nil
        }
        writingCover = fileName
        Task {
            let written = await Task.detached(priority: .utility) {
                Self.writeWidgetCover(cover, named: fileName, in: directory)
            }.value
            writingCover = nil
            if !written { unwritableCovers.insert(fileName) }
            refresh()
            // No longer the widget's cover by the time it was written.
            if written, widgetCover?.fileName != fileName {
                try? FileManager.default.removeItem(at: directory.appending(path: fileName))
            }
        }
        return nil
    }

    /// Records the thumbnail the widget has for this document and cover,
    /// and removes every other one.
    private func settleWidgetCover(documentID: UUID?, fingerprint: String?, fileName: String?) {
        widgetCover = (documentID, fingerprint, fileName)
        guard let directory = SharedContainer.widgetCoversURL,
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where file != fileName {
            try? FileManager.default.removeItem(at: directory.appending(path: file))
        }
    }

    /// Writes a widget-sized thumbnail of a stored cover. False when the
    /// cover doesn't decode or the file can't be written.
    private nonisolated static func writeWidgetCover(_ cover: Data, named fileName: String, in directory: URL) -> Bool {
        guard let thumbnail = CoverImage.thumbnail(of: cover) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try thumbnail.write(to: directory.appending(path: fileName), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Saves the snapshot for the widget and reloads it, if anything
    /// changed. The widget's reload budget is spent only on real changes.
    private func publish(_ snapshot: ContinueReadingSnapshot) {
        guard let defaults = SharedContainer.defaults,
              ContinueReadingSnapshot.load(from: defaults) != snapshot else { return }
        snapshot.save(to: defaults)
        WidgetCenter.shared.reloadTimelines(ofKind: ContinueReadingSnapshot.widgetKind)
    }

    /// Tells Siri the library's titles, for phrases like "Open Moby-Dick in
    /// Strobe", when documents are added, renamed, or deleted.
    private func updateShortcutTitlesIfNeeded(for documents: [Document]) {
        let titles = Dictionary(documents.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        guard titles != shortcutTitles else { return }
        shortcutTitles = titles
        StrobeShortcuts.updateAppShortcutParameters()
    }
}
