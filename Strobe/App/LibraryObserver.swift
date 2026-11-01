import Foundation
import SwiftData
import WidgetKit
import AppIntents

/// Keeps what Strobe shows outside the app in step with the library: the
/// Continue Reading widget's snapshot, and the document titles Siri
/// recognizes in shortcut phrases.
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
        publish(ContinueReadingSnapshot(documents: documents))
        updateShortcutTitlesIfNeeded(for: documents)
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
