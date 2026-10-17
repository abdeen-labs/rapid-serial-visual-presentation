import SwiftUI

/// Chapter navigation for the reader: previous and next chapter buttons
/// either side of the current chapter's title, in one capsule of the
/// reader's glass. The title opens the chapters, shown as on the book page,
/// to jump to one.
///
/// A separate view so its dependency on `engine.currentIndex` (via the
/// current-chapter computation) invalidates only this small subtree on every
/// word tick instead of the whole reader.
struct ChapterNavigationView: View {
    let chapters: [Chapter]
    let engine: RSVPEngine
    /// The speed and pace factor the chapter list gives lengths at.
    let wordsPerMinute: Int
    let paceFactor: Double?
    /// The furthest word read as last saved. The list marks chapters up to
    /// it, or up to the furthest played here if that's further, as read.
    let furthestWordIndex: Int
    @Binding var showChapterPicker: Bool
    /// Called after any chapter jump — the reader clears its completion overlay.
    var onNavigate: () -> Void = {}

    /// A "previous chapter" tap within this many words of where the chapter's
    /// reading starts, after any heading its announcement stands in for, goes
    /// to the prior chapter instead of restarting the current one.
    private static let nearChapterStartThreshold = 2

    /// Index of the chapter containing the current word (largest chapter whose
    /// `wordIndex` is at or before `engine.currentIndex`), or the first chapter
    /// while the position is still before its start. Nil if no chapters.
    private var currentChapterIndex: Int? {
        guard !chapters.isEmpty else { return nil }
        return ChapterTimeline.index(in: chapters, containing: engine.currentIndex) ?? 0
    }

    private var canGoPreviousChapter: Bool {
        guard let idx = currentChapterIndex else { return false }
        return !isNearStart(ofChapterAt: idx) || idx > 0
    }

    private func isNearStart(ofChapterAt idx: Int) -> Bool {
        engine.currentIndex <= engine.readingStart(ofChapterAt: chapters[idx].wordIndex) + Self.nearChapterStartThreshold
    }

    private var canGoNextChapter: Bool {
        guard let idx = currentChapterIndex else { return false }
        return idx + 1 < chapters.count
    }

    var body: some View {
        let idx = currentChapterIndex ?? 0
        let title = chapters.indices.contains(idx) ? chapters[idx].title : ""

        HStack(spacing: 0) {
            Button {
                jumpToPreviousChapter()
            } label: {
                Image(systemName: "backward.end.fill")
                    .frame(width: 52, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!canGoPreviousChapter)
            .accessibilityLabel("Previous chapter")

            Button {
                showChapterPicker = true
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .popover(isPresented: $showChapterPicker, arrowEdge: .bottom) {
                chapterPickerContent
            }
            .accessibilityLabel("Chapter")
            .accessibilityValue(title)
            .accessibilityHint("Pick a chapter to jump to")

            Button {
                jumpToNextChapter()
            } label: {
                Image(systemName: "forward.end.fill")
                    .frame(width: 52, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!canGoNextChapter)
            .accessibilityLabel("Next chapter")
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.primary)
        .buttonStyle(ReaderGlassItemButtonStyle())
        .readerGlass(in: Capsule())
    }

    // MARK: - Chapter list

    @ViewBuilder
    private var chapterPickerContent: some View {
        let activeIndex = currentChapterIndex
        let totalWordCount = engine.words.count
        let furthest = max(furthestWordIndex, engine.furthestPlayedIndex)

        VStack(spacing: 0) {
            Text("Chapters")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .accessibilityAddTraits(.isHeader)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(chapters.enumerated()), id: \.element.id) { i, chapter in
                            let (start, end) = ChapterListView.chapterBounds(at: i, chapters: chapters, totalWordCount: totalWordCount)
                            let minutes = ReadingTime.minutes(
                                words: max(0, end - start),
                                wordsPerMinute: wordsPerMinute,
                                paceFactor: paceFactor ?? 1
                            )
                            let state = rowState(at: i, activeIndex: activeIndex, furthest: furthest, totalWordCount: totalWordCount)

                            Button {
                                showChapterPicker = false
                                jumpToChapter(i)
                            } label: {
                                ChapterRow(title: chapter.title, minutes: minutes, state: state)
                            }
                            .buttonStyle(ChapterRowButtonStyle())
                            .accessibilityLabel(chapter.title)
                            .accessibilityValue(ChapterRow.accessibilityStatus(state: state, minutes: minutes))
                            .id(chapter.id)

                            if i < chapters.count - 1 {
                                Divider()
                                    .padding(.leading, 16)
                            }
                        }
                    }
                    .background(StrobeTheme.elevatedSurface)
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .onAppear {
                    guard let idx = activeIndex, chapters.indices.contains(idx) else { return }
                    // Defer one runloop so LazyVStack rows are registered before we scroll.
                    DispatchQueue.main.async {
                        proxy.scrollTo(chapters[idx].id, anchor: .center)
                    }
                }
            }
        }
        .background {
            ReaderBackdrop().ignoresSafeArea()
        }
        .frame(idealWidth: 380, idealHeight: 520)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// The chapter being read, with how far into it the position is; any
    /// other, by how far the furthest word read reaches into it.
    private func rowState(at index: Int, activeIndex: Int?, furthest: Int, totalWordCount: Int) -> ChapterRow.ReadState {
        let (start, end) = ChapterListView.chapterBounds(at: index, chapters: chapters, totalWordCount: totalWordCount)
        if index == activeIndex {
            let fraction = Double(engine.currentIndex - start) / Double(max(1, end - start))
            return .current(fraction: fraction)
        }
        switch ChapterListView.chapterStatus(
            at: index,
            chapters: chapters,
            totalWordCount: totalWordCount,
            furthestWordIndex: furthest
        ) {
        case .completed: return .completed
        case .inProgress: return .partial
        case .notStarted: return .unread
        }
    }

    private func jumpToChapter(_ index: Int) {
        guard chapters.indices.contains(index) else { return }
        if engine.isPlaying { engine.pause() }
        engine.seek(to: chapters[index].wordIndex)
        HapticManager.shared.scrubBoundary()
        onNavigate()
    }

    private func jumpToPreviousChapter() {
        guard let idx = currentChapterIndex else { return }
        if !isNearStart(ofChapterAt: idx) {
            jumpToChapter(idx)
        } else if idx > 0 {
            jumpToChapter(idx - 1)
        }
    }

    private func jumpToNextChapter() {
        guard let idx = currentChapterIndex, idx + 1 < chapters.count else { return }
        jumpToChapter(idx + 1)
    }
}
