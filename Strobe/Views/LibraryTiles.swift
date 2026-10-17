import SwiftUI

extension DocumentCover {
    init(document: Document, showsText: Bool = true) {
        self.init(
            title: document.title,
            kind: document.kind,
            tone: CoverTone.tone(for: document.id),
            showsText: showsText
        )
    }
}

/// A library grid item: the document's cover, which opens it, above its
/// reading status and a menu of document actions.
struct DocumentTile: View {
    let document: Document
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let status = document.readingStatus

        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: document) {
                DocumentCover(document: document)
            }
            .buttonStyle(StrobeCardButtonStyle())
            #if os(iOS)
            .contentShape(.contextMenuPreview, .rect(cornerRadius: 4, style: .continuous))
            .hoverEffect(.lift)
            #endif
            .contextMenu { actions }
            .accessibilityLabel(document.title)
            .accessibilityValue(status.label)

            HStack(spacing: 0) {
                Text(status.label)
                    .font(StrobeTheme.metadataFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)

                Spacer(minLength: 0)

                // On macOS the cover's right-click menu is the way in.
                #if os(iOS)
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 28)
                        .contentShape(Rectangle())
                }
                .iconMenuStyle()
                // The glyph sits near the cover's edge; the hit area spills
                // into the gap between columns.
                .padding(.trailing, -14)
                .accessibilityLabel("More")
                .accessibilityHint(document.title)
                #endif
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button(action: onRename) {
            Label("Rename…", systemImage: "pencil")
        }
        Button(role: .destructive, action: onDelete) {
            Label("Delete", systemImage: "trash")
        }
    }
}

/// Stands in the grid for a file that's still importing. When several are
/// queued, it counts them: file `position` of `count`.
struct ImportingTile: View {
    let fileName: String
    var position = 1
    var count = 1
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.secondary)
                        Text(fileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                        if count > 1 {
                            Text("\(position) of \(count)")
                                .font(StrobeTheme.metadataFont)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(12)
                }
                .background(StrobeTheme.elevatedSurface, in: .rect(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(count > 1
                    ? "Importing \(fileName), \(position) of \(count)"
                    : "Importing \(fileName)")

            HStack(spacing: 0) {
                Text("Importing…")
                    .font(StrobeTheme.metadataFont)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .font(StrobeTheme.metadataFont.weight(.semibold))
                    .buttonStyle(.borderless)
                    .accessibilityHint(count > 1 ? "Stops this import and the files after it" : "Stops the import")
            }
        }
    }
}

/// The document the reader was last in, shown above the grid so resuming
/// is one tap from the library. Wide layouts put the cover, the title with
/// its progress, and the Resume pill in one row; iPhone stacks the progress
/// under the title.
struct ContinueReadingCard: View {
    let document: Document
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isWide: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    var body: some View {
        let status = document.readingStatus
        let pace = ReadingPace.shared
        let minutesLeft = pace.remainingMinutes(for: document)
        let chapterTitle = ChapterTimeline(document.chapters).chapter(containing: document.currentWordIndex)?.title
        let progressLine = "\(status.label) · \(ReadingTime.label(minutes: minutesLeft)) left"

        NavigationLink(value: ReaderRoute(document: document)) {
            Group {
                if isWide {
                    wideLayout(chapterTitle: chapterTitle, progressLine: progressLine)
                } else {
                    compactLayout(chapterTitle: chapterTitle, progressLine: progressLine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StrobeTheme.elevatedSurface, in: .rect(cornerRadius: 16, style: .continuous))
            .contentShape(.rect(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(StrobeCardButtonStyle())
        .accessibilityLabel("Continue reading \(document.title)")
        .accessibilityValue(
            [chapterTitle, status.label, "\(ReadingTime.spokenLabel(minutes: minutesLeft)) left"]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
        // The time left follows the timing settings once the document's pace
        // is worked out, and again after they change.
        .task(id: pace.key(for: document)) {
            pace.prepare(document)
        }
    }

    private func wideLayout(chapterTitle: String?, progressLine: String) -> some View {
        HStack(spacing: 18) {
            DocumentCover(document: document, showsText: false)
                .frame(width: 56)

            VStack(alignment: .leading, spacing: 0) {
                label
                title
                    .padding(.top, 1)
                Text([chapterTitle, progressLine].compactMap { $0 }.joined(separator: " · "))
                    .font(wideDetailFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.top, 3)
                ReadingProgressBar(progress: document.progress)
                    .frame(maxWidth: 280)
                    .padding(.top, 10)
            }

            Spacer(minLength: 16)

            resumePill
        }
        .padding(16)
    }

    private func compactLayout(chapterTitle: String?, progressLine: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            DocumentCover(document: document, showsText: false)
                .frame(width: 64)

            VStack(alignment: .leading, spacing: 0) {
                label
                title
                    .padding(.top, 2)
                if let chapterTitle {
                    Text(chapterTitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                }

                Spacer(minLength: 12)

                ReadingProgressBar(progress: document.progress)

                HStack(spacing: 8) {
                    Text(progressLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    resumePill
                }
                .padding(.top, 8)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
    }

    private var label: some View {
        Text("Continue Reading")
            .font(isWide ? wideLabelFont : .caption)
            .foregroundStyle(.secondary)
    }

    private var wideLabelFont: Font {
        #if os(macOS)
        .subheadline
        #else
        .caption
        #endif
    }

    private var wideDetailFont: Font {
        #if os(macOS)
        .body
        #else
        .subheadline
        #endif
    }

    private var title: some View {
        Text(document.title)
            .font(StrobeTheme.displayFont(size: isWide ? 22 : 20, relativeTo: isWide ? .title2 : .title3))
            .foregroundStyle(.primary)
            .lineLimit(isWide ? 1 : 2)
            .multilineTextAlignment(.leading)
    }

    private var resumePill: some View {
        Label("Resume", systemImage: "play.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(StrobeTheme.accent, in: .capsule)
    }
}

/// A thin reading-progress bar in the accent color.
struct ReadingProgressBar: View {
    let progress: Double
    /// The reader's bar thickens while it's dragged.
    var height: CGFloat = 4

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.16))
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(StrobeTheme.accent)
                        .frame(width: geo.size.width * min(max(progress, 0), 1))
                }
            }
            .accessibilityHidden(true)
    }
}

extension View {
    /// Shows a `Menu` as its bare label in the label's own colors: no
    /// accent tint and no pull-down arrow.
    func iconMenuStyle() -> some View {
        self
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}
