import SwiftUI

/// The faded document title and current chapter at the top of the reader
/// while words are playing. Each line is opt-in from Settings.
///
/// Shown only during playback: paused, the top bar and the chapter
/// navigation already carry both. The lines fade on the top bar's timing so
/// the two cross-fade in the same spot.
struct ReaderHeaderView: View {
    let title: String
    let chapters: [Chapter]
    let engine: RSVPEngine
    /// The top bar's fade duration.
    let fadeDuration: Double

    @AppStorage(ReaderSettings.Keys.readingHeaderTitleEnabled) private var titleEnabled: Bool = ReaderSettings.Defaults.readingHeaderTitleEnabled
    @AppStorage(ReaderSettings.Keys.readingHeaderChapterEnabled) private var chapterEnabled: Bool = ReaderSettings.Defaults.readingHeaderChapterEnabled
    @AppStorage(ReaderTextTone.storageKey) private var readerTextToneSelection = ReaderTextTone.defaultValue.rawValue
    @State private var timeline = ChapterTimeline([])

    var body: some View {
        let tone = ReaderTextTone.resolve(readerTextToneSelection)

        if titleEnabled || chapterEnabled {
            VStack(spacing: 2) {
                if titleEnabled && !title.isEmpty {
                    ReaderHeaderLine(text: title, bold: true, tone: tone)
                        .equatable()
                        .opacity(engine.isPlaying ? 1 : 0)
                        .animation(.easeInOut(duration: fadeDuration), value: engine.isPlaying)
                        // The title never changes mid-session and the paused top
                        // bar already reads it out.
                        .accessibilityHidden(true)
                }

                if chapterEnabled {
                    ReaderHeaderChapterLine(
                        timeline: timeline,
                        engine: engine,
                        tone: tone,
                        fadeDuration: fadeDuration
                    )
                }
            }
            // Keeps the header smaller than the smallest reader word (24pt) and
            // clear of the word slot on a landscape phone.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .frame(maxWidth: 420)
            .padding(.horizontal, 32)
            .padding(.top, 12)
            // The hold-to-read gesture layer lies underneath.
            .allowsHitTesting(false)
            .onChange(of: chapters, initial: true) {
                timeline = ChapterTimeline(chapters)
            }
        }
    }
}

/// The header's current-chapter line. Isolates the per-tick
/// `engine.currentIndex` read; the lookup is a binary search and the text
/// below it only re-renders when the chapter changes.
private struct ReaderHeaderChapterLine: View {
    let timeline: ChapterTimeline
    let engine: RSVPEngine
    let tone: ReaderTextTone
    let fadeDuration: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hidden while a chapter title holds the word slot: it would show the
    /// same title twice.
    private var isVisible: Bool {
        engine.isPlaying && !engine.isChapterTitleVisible
    }

    private var visibilityAnimation: Animation? {
        // Dropping out at once hides the change to the new chapter's title.
        if engine.isChapterTitleVisible { return nil }
        // The announcement doesn't fade under Reduce Motion, so neither does
        // the hand-off from it.
        if reduceMotion && engine.chapterAnnouncement != nil { return nil }
        return .easeInOut(duration: fadeDuration)
    }

    var body: some View {
        // Nil before the first chapter starts and in documents without chapters.
        if let chapter = timeline.chapter(containing: engine.currentIndex) {
            ReaderHeaderLine(text: chapter.title, bold: false, tone: tone)
                .equatable()
                .opacity(isVisible ? 1 : 0)
                .animation(visibilityAnimation, value: isVisible)
                .accessibilityElement()
                .accessibilityLabel("Chapter")
                .accessibilityValue(chapter.title)
                .accessibilityHidden(!isVisible)
        }
    }
}

/// One line of header text in the tone's faded color.
private struct ReaderHeaderLine: View, Equatable {
    let text: String
    let bold: Bool
    let tone: ReaderTextTone

    var body: some View {
        Text(text)
            .font(bold ? .caption.weight(.semibold) : .caption)
            .foregroundStyle(tone.fadedTextColor)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
