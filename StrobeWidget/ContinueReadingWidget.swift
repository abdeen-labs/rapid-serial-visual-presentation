import SwiftUI
import WidgetKit

/// The document to pick up next, from the snapshot the app saves (see
/// ``ContinueReadingSnapshot``). Tapping it opens the reader there.
struct ContinueReadingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: ContinueReadingSnapshot.widgetKind,
            provider: ContinueReadingProvider()
        ) { entry in
            ContinueReadingWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Continue Reading")
        .description("Pick up where you left off.")
        .supportedFamilies(Self.supportedFamilies)
    }

    private static var supportedFamilies: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium]
        #endif
    }
}

nonisolated struct ContinueReadingEntry: TimelineEntry {
    let date: Date
    /// Nil until the app has saved a snapshot.
    let snapshot: ContinueReadingSnapshot?
}

/// Reads the snapshot the app saved. The app reloads the widget each time it
/// saves a new one, so the timeline is a single entry that lasts until then.
nonisolated struct ContinueReadingProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueReadingEntry {
        ContinueReadingEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueReadingEntry) -> Void) {
        var snapshot = savedSnapshot()
        // The widget gallery shows a sample until there's something to read.
        if context.isPreview && snapshot?.item == nil {
            snapshot = .sample
        }
        completion(ContinueReadingEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueReadingEntry>) -> Void) {
        let entry = ContinueReadingEntry(date: .now, snapshot: savedSnapshot())
        completion(Timeline(entries: [entry], policy: .never))
    }

    private func savedSnapshot() -> ContinueReadingSnapshot? {
        SharedContainer.defaults.flatMap { ContinueReadingSnapshot.load(from: $0) }
    }
}

nonisolated extension ContinueReadingSnapshot {
    /// A document in progress, for the widget gallery and placeholders.
    static let sample = ContinueReadingSnapshot(
        item: Item(
            id: UUID(uuidString: "5A1F1D00-0000-4000-8000-000000000012") ?? UUID(),
            title: "Pride and Prejudice",
            fileName: "Pride and Prejudice.epub",
            progress: 0.42,
            chapterTitle: "Chapter 12",
            remainingMinutes: 185,
            preview: "In consequence of an agreement between the sisters, Elizabeth wrote the next morning to her mother…"
        ),
        libraryIsEmpty: false
    )
}

#Preview("Small", as: .systemSmall) {
    ContinueReadingWidget()
} timeline: {
    ContinueReadingEntry(date: .now, snapshot: .sample)
    ContinueReadingEntry(date: .now, snapshot: ContinueReadingSnapshot(item: nil, libraryIsEmpty: false))
}

#Preview("Medium", as: .systemMedium) {
    ContinueReadingWidget()
} timeline: {
    ContinueReadingEntry(date: .now, snapshot: .sample)
    ContinueReadingEntry(date: .now, snapshot: ContinueReadingSnapshot(item: nil, libraryIsEmpty: true))
}
