import SwiftUI
import WidgetKit

private typealias Item = ContinueReadingSnapshot.Item

/// The Continue Reading widget in every family. Tapping it opens the
/// document's reader, or the library when there's nothing to pick up.
///
/// The Home Screen and desktop sizes follow the library's Continue Reading
/// card: the generated cover, the title in Fraunces, and progress in the
/// accent red, on the app's dark surface.
struct ContinueReadingWidgetView: View {
    let snapshot: ContinueReadingSnapshot?
    @Environment(\.widgetFamily) private var family

    private var item: Item? { snapshot?.item }

    private var emptyState: EmptyState {
        guard let snapshot else { return .notSaved }
        return snapshot.libraryIsEmpty ? .emptyLibrary : .allRead
    }

    var body: some View {
        content
            .widgetURL((item?.link ?? .library).url)
            .containerBackground(for: .widget) {
                background
            }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        #if os(iOS)
        case .accessoryCircular:
            CircularAccessory(item: item)
        case .accessoryRectangular:
            RectangularAccessory(item: item, emptyState: emptyState)
        case .accessoryInline:
            InlineAccessory(item: item)
        #endif
        case .systemMedium:
            if let item {
                MediumContent(item: item)
            } else {
                EmptyContent(state: emptyState)
            }
        default:
            if let item {
                SmallContent(item: item)
            } else {
                EmptyContent(state: emptyState)
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        switch family {
        case .systemSmall, .systemMedium:
            Backdrop(tone: item.map { CoverTone.tone(for: $0.id) })
        default:
            Color.clear
        }
    }
}

// MARK: - Home Screen and desktop

private struct SmallContent: View {
    let item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                WidgetCover(item: item, showsText: false)
                    .frame(width: 26)
                Spacer(minLength: 0)
                Text(item.status.label)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Text(item.title)
                .font(StrobeTheme.displayFont(size: 16, relativeTo: .headline))
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            WidgetProgressBar(progress: item.progress)
                .padding(.top, 8)

            Text(item.timeLabel)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
    }
}

private struct MediumContent: View {
    let item: Item

    var body: some View {
        HStack(spacing: 14) {
            WidgetCover(item: item, showsText: true)
                .frame(width: 80)

            // The preview takes what room the title leaves: two lines, one,
            // or none.
            ViewThatFits(in: .vertical) {
                details(previewLines: 2)
                details(previewLines: 1)
                details(previewLines: 0)
            }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabelWithPreview)
    }

    private func details(previewLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.status == .new ? "Up Next" : "Continue Reading")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(item.title)
                .font(StrobeTheme.displayFont(size: 19, relativeTo: .title3))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.top, 2)

            if let chapterTitle = item.chapterTitle {
                Text(chapterTitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 2)
            }

            if let preview = item.preview, previewLines > 0 {
                Text(verbatim: preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(previewLines)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, item.previewIsRightToLeft ? .rightToLeft : .leftToRight)
                    .padding(.top, 4)
            }

            Spacer(minLength: 8)

            WidgetProgressBar(progress: item.progress)

            Text(item.progressLine)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct EmptyContent: View {
    let state: EmptyState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: state.symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Text(state.title)
                .font(StrobeTheme.displayFont(size: 17, relativeTo: .headline))
                .lineLimit(2)

            Text(state.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}

/// Why there's no document to show.
private enum EmptyState {
    /// The app hasn't saved a snapshot since the widget was added.
    case notSaved
    case emptyLibrary
    /// Every document is finished.
    case allRead

    var title: String {
        switch self {
        case .notSaved: "Continue Reading"
        case .emptyLibrary: "Nothing to Read"
        case .allRead: "All Caught Up"
        }
    }

    var message: String {
        switch self {
        case .notSaved: "Open Strobe to pick up where you left off."
        case .emptyLibrary: "Import a book or paste text in Strobe."
        case .allRead: "You've finished everything in your library."
        }
    }

    var symbolName: String {
        switch self {
        case .notSaved: "book.closed"
        case .emptyLibrary: "books.vertical"
        case .allRead: "checkmark.circle"
        }
    }
}

/// The app's dark surface, washed at the top with the document's cover
/// color.
private struct Backdrop: View {
    let tone: CoverTone?

    var body: some View {
        ZStack {
            StrobeTheme.surface
            if let tone {
                LinearGradient(
                    colors: [tone.background.opacity(0.45), tone.background.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }
}

/// The document's cover: the book's own when the app left a thumbnail,
/// or else the generated one. The tinted and clear styles keep only
/// each view's opacity, which would turn the cover into a solid block, so
/// there it's a translucent card with a book symbol.
private struct WidgetCover: View {
    let item: Item
    let showsText: Bool
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if renderingMode == .fullColor {
            DocumentCover(
                title: item.title,
                kind: item.kind,
                tone: CoverTone.tone(for: item.id),
                showsText: showsText,
                artwork: item.loadCover()
            )
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.white.opacity(0.2))
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    if showsText {
                        Image(systemName: "book.closed")
                            .font(.title2)
                    }
                }
                .accessibilityHidden(true)
        }
    }
}

/// A thin progress bar in the accent color, like the library's.
private struct WidgetProgressBar: View {
    let progress: Double

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.16))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(StrobeTheme.accent)
                        .frame(width: geo.size.width * min(max(progress, 0), 1))
                        .widgetAccentable()
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Lock Screen

#if os(iOS)
private struct CircularAccessory: View {
    let item: Item?

    var body: some View {
        if let item {
            Gauge(value: min(max(item.progress, 0), 1)) {
                Image(systemName: "book.closed")
            } currentValueLabel: {
                Text(verbatim: "\(item.status.percent)%")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .accessibilityLabel(item.accessibilityLabel)
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "book.closed")
                    .font(.title3)
            }
            .accessibilityLabel("Strobe")
        }
    }
}

private struct RectangularAccessory: View {
    let item: Item?
    let emptyState: EmptyState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let item {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                    .widgetAccentable()
                ProgressView(value: min(max(item.progress, 0), 1))
                    .progressViewStyle(.linear)
                Text(item.progressLine)
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
            } else {
                Text("Strobe")
                    .font(.headline)
                    .widgetAccentable()
                Text(emptyState.message)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct InlineAccessory: View {
    let item: Item?

    var body: some View {
        if let item {
            Label {
                Text(verbatim: "\(item.status.label) · \(item.title)")
            } icon: {
                Image(systemName: "book.closed")
            }
        } else {
            Label("Strobe", systemImage: "book.closed")
        }
    }
}
#endif

// MARK: - Labels

private extension ContinueReadingSnapshot.Item {
    /// "3 hr 12 min left", or the whole length when it's not started.
    var timeLabel: String {
        let time = ReadingTime.label(minutes: remainingMinutes)
        return status == .new ? time : "\(time) left"
    }

    /// "42% · 3 hr 12 min left", as the library's Continue Reading card
    /// puts it.
    var progressLine: String {
        "\(status.label) · \(timeLabel)"
    }

    var accessibilityLabel: String {
        let time = ReadingTime.spokenLabel(minutes: remainingMinutes)
        let isNew = status == .new
        return [
            isNew ? "Up next" : "Continue reading",
            title,
            chapterTitle,
            status.label,
            isNew ? time : "\(time) left",
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    /// The label with the preview, for the medium size, the only one that
    /// shows it.
    var accessibilityLabelWithPreview: String {
        [accessibilityLabel, preview].compactMap { $0 }.joined(separator: ", ")
    }
}
