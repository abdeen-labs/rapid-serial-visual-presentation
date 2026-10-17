import SwiftUI
import SwiftData

/// The book page for a document with chapters: its cover and reading
/// progress, one button that starts, resumes, or restarts it, and the
/// chapters with their lengths and not-started / in-progress / completed
/// status, judged by the furthest position the user has read to.
struct ChapterListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let document: Document

    @FocusState private var pageFocused: Bool

    private var isRegularWidth: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                chapterList
                    .padding(.top, 32)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { StrobeTheme.background.ignoresSafeArea() }
        .navigationTitle(document.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // The header already shows the title in full.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        #endif
        // Escape pops this page on macOS, matching the reader and passage
        // view. Focus is taken on appear so the key has a responder.
        .focusable()
        .focusEffectDisabled()
        .focused($pageFocused)
        .onAppear { pageFocused = true }
        .marksDocumentOpen(document.id)
        // Time left and chapter lengths follow the timing settings once the
        // document's pace is worked out, and again after they change.
        .task(id: ReadingPace.shared.key(for: document)) {
            ReadingPace.shared.prepare(document)
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    // MARK: - Header

    private var header: some View {
        let status = document.readingStatus

        return VStack(spacing: 0) {
            DocumentCover(document: document)
                .frame(width: isRegularWidth ? 150 : 128)
                .padding(.top, 8)

            Text(document.title)
                .font(StrobeTheme.displayFont(size: 26, relativeTo: .title))
                .multilineTextAlignment(.center)
                .padding(.top, 20)

            Text(detailLine)
                .font(StrobeTheme.metadataFont)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            NavigationLink(value: ReaderRoute(
                document: document,
                startingWordIndex: status == .finished ? 0 : nil
            )) {
                Label(primaryActionTitle(for: status), systemImage: status == .finished ? "arrow.counterclockwise" : "play.fill")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .frame(maxWidth: 420)
            .padding(.top, 22)

            if status.isInProgress {
                progressSummary(status: status)
                    .frame(maxWidth: 420)
                    .padding(.top, 16)
            }
        }
    }

    private var detailLine: String {
        let words = document.wordCount == 1 ? "1 word" : "\(document.wordCount.formatted()) words"
        let chapters = document.chapters.count == 1 ? "1 chapter" : "\(document.chapters.count) chapters"
        return "\(words) · \(chapters)"
    }

    private func primaryActionTitle(for status: ReadingStatus) -> String {
        switch status {
        case .new:
            return "Start Reading"
        case .inProgress:
            let chapter = ChapterTimeline(document.chapters).chapter(containing: document.currentWordIndex)
            return chapter.map { "Resume \($0.title)" } ?? "Resume"
        case .finished:
            return "Read Again"
        }
    }

    private func progressSummary(status: ReadingStatus) -> some View {
        let minutesLeft = ReadingPace.shared.remainingMinutes(for: document)
        // The speed stands beside the time, not under it: the time also
        // counts the timing settings.
        return VStack(spacing: 6) {
            ReadingProgressBar(progress: document.progress)
            HStack {
                Text(status.label)
                Spacer()
                Text("\(ReadingTime.label(minutes: minutesLeft)) left · \(document.wordsPerMinute) wpm")
            }
            .font(StrobeTheme.metadataFont)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(status.label), \(ReadingTime.spokenLabel(minutes: minutesLeft)) left, \(document.wordsPerMinute) words per minute")
    }

    // MARK: - Chapters

    private var chapterList: some View {
        // One snapshot per render: every row derives its bounds from it.
        let chapters = document.chapters
        let totalWordCount = document.wordCount
        let currentIndex = currentChapterIndex(in: chapters)
        let paceFactor = ReadingPace.shared.factor(for: document) ?? 1

        return VStack(alignment: .leading, spacing: 8) {
            Text("Chapters")
                .font(StrobeTheme.metadataFont)
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
                .accessibilityAddTraits(.isHeader)

            LazyVStack(spacing: 0) {
                ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                    let (start, end) = Self.chapterBounds(at: index, chapters: chapters, totalWordCount: totalWordCount)
                    let minutes = ReadingTime.minutes(
                        words: max(0, end - start),
                        wordsPerMinute: document.wordsPerMinute,
                        paceFactor: paceFactor
                    )
                    let state = rowState(at: index, currentIndex: currentIndex, chapters: chapters)

                    NavigationLink(value: ReaderRoute(
                        document: document,
                        startingWordIndex: Self.startingWordIndex(
                            forChapterAt: index,
                            chapters: chapters,
                            totalWordCount: totalWordCount,
                            currentWordIndex: document.currentWordIndex
                        )
                    )) {
                        ChapterRow(title: chapter.title, minutes: minutes, state: state)
                    }
                    .buttonStyle(ChapterRowButtonStyle())
                    .accessibilityLabel(chapter.title)
                    .accessibilityValue(ChapterRow.accessibilityStatus(state: state, minutes: minutes))

                    if index < chapters.count - 1 {
                        Divider()
                            .padding(.leading, 16)
                    }
                }
            }
            .background(StrobeTheme.elevatedSurface)
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
        }
    }

    /// The chapter holding the resume position, while the document is
    /// partway through.
    private func currentChapterIndex(in chapters: [Chapter]) -> Int? {
        guard document.readingStatus.isInProgress else { return nil }
        let position = document.currentWordIndex
        return chapters.indices.first { index in
            let (start, end) = Self.chapterBounds(at: index, chapters: chapters, totalWordCount: document.wordCount)
            return position >= start && position < end
        }
    }

    private func rowState(at index: Int, currentIndex: Int?, chapters: [Chapter]) -> ChapterRow.ReadState {
        let (start, end) = Self.chapterBounds(at: index, chapters: chapters, totalWordCount: document.wordCount)
        if index == currentIndex {
            let fraction = Double(document.currentWordIndex - start) / Double(max(1, end - start))
            return .current(fraction: fraction)
        }
        switch Self.chapterStatus(
            at: index,
            chapters: chapters,
            totalWordCount: document.wordCount,
            furthestWordIndex: document.displayedFurthestWordIndex
        ) {
        case .completed: return .completed
        case .inProgress: return .partial
        case .notStarted: return .unread
        }
    }

    // nonisolated so the synthesized Equatable can be used off the main
    // actor (tests compare statuses inside nonisolated #expect closures).
    nonisolated enum ChapterStatus {
        case notStarted, inProgress, completed
    }

    // MARK: - Pure helpers (testable)

    /// Half-open word-index bounds of the chapter at `index`.
    nonisolated static func chapterBounds(at index: Int, chapters: [Chapter], totalWordCount: Int) -> (start: Int, end: Int) {
        let start = chapters[index].wordIndex
        let end = index + 1 < chapters.count
            ? chapters[index + 1].wordIndex
            : totalWordCount
        return (start, end)
    }

    /// Where the reader should start when a chapter row is tapped.
    ///
    /// Resumes at the user's current position when it falls inside this
    /// chapter — otherwise tapping the chapter you're partway through (and
    /// then leaving the reader) would overwrite your saved position with the
    /// chapter start. Judged on `currentWordIndex`, not the furthest-read
    /// marker: status can say "in progress" for a chapter the user has read
    /// into and then scrubbed back out of.
    nonisolated static func startingWordIndex(
        forChapterAt index: Int,
        chapters: [Chapter],
        totalWordCount: Int,
        currentWordIndex: Int
    ) -> Int {
        let (start, end) = chapterBounds(at: index, chapters: chapters, totalWordCount: totalWordCount)
        if currentWordIndex > start && currentWordIndex < end - 1 {
            return currentWordIndex
        }
        return start
    }

    /// Chapter completion state, judged against the furthest position ever
    /// reached so navigating backward doesn't mark finished chapters
    /// un-finished.
    nonisolated static func chapterStatus(
        at index: Int,
        chapters: [Chapter],
        totalWordCount: Int,
        furthestWordIndex: Int
    ) -> ChapterStatus {
        let (start, end) = chapterBounds(at: index, chapters: chapters, totalWordCount: totalWordCount)
        if furthestWordIndex >= end - 1 {
            return .completed
        } else if furthestWordIndex > start {
            return .inProgress
        }
        return .notStarted
    }
}

/// One chapter on the book page: its title, its length at the document's
/// speed, and where the reader stands in it.
private struct ChapterRow: View {
    enum ReadState: Equatable {
        /// The chapter holding the resume position, `fraction` of the way in.
        case current(fraction: Double)
        case completed
        case partial
        case unread
    }

    let title: String
    let minutes: Int
    let state: ReadState

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(state == .completed ? .secondary : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 8)

            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .current(let fraction):
            HStack(spacing: 6) {
                Text("Reading")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(StrobeTheme.accent)
                ChapterProgressRing(fraction: fraction)
            }
        case .completed:
            HStack(spacing: 6) {
                durationText
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        case .partial:
            HStack(spacing: 6) {
                durationText
                Image(systemName: "circle.lefthalf.filled")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .unread:
            durationText
        }
    }

    private var durationText: some View {
        Text(ReadingTime.label(minutes: minutes))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    static func accessibilityStatus(state: ReadState, minutes: Int) -> String {
        let duration = ReadingTime.spokenLabel(minutes: minutes)
        return switch state {
        case .current: "Reading, \(duration)"
        case .completed: "Finished, \(duration)"
        case .partial: "Started, \(duration)"
        case .unread: duration
        }
    }
}

/// How far the reader is into the current chapter.
private struct ChapterProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(StrobeTheme.accent.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0.04), 1))
                .stroke(StrobeTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
    }
}

/// Highlights a chapter row while it's pressed.
private struct ChapterRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.white.opacity(0.08) : Color.clear)
    }
}
