import SwiftUI
import SwiftData

/// Full-screen passage view shown over the reader when the user wants to
/// "find their place." Renders every word as a tappable view in a flowing
/// layout, highlights the current reading position, and supports in-text
/// search with previous/next match navigation. Tapping a word seeks the
/// `RSVPEngine` to that index without dismissing the view, so the user
/// can keep browsing.
struct PassageView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let document: Document
    let engine: RSVPEngine
    @AppStorage(ReaderFont.storageKey) private var readerFontSelection = ReaderFont.defaultValue.rawValue
    @AppStorage(ReaderTextTone.storageKey) private var readerTextToneSelection = ReaderTextTone.defaultValue.rawValue
    @AppStorage(ReaderHighlightColor.storageKey) private var readerHighlightColorSelection = ReaderHighlightColor.defaultValue.rawValue

    /// Whether the passage content is dominantly right-to-left script.
    /// Computed once at init — it drives the flow layout's direction, which
    /// must not flip mid-session.
    private let isRTLContent: Bool

    /// The word slices rendered as separate `WordChunkView`s. Chunks live in a
    /// `LazyVStack` so very long documents only render visible regions.
    private let chunks: PassageChunks

    init(document: Document, engine: RSVPEngine) {
        self.document = document
        self.engine = engine
        self.isRTLContent = Self.isRTLDominant(engine.words)
        self.chunks = PassageChunks(
            words: engine.words,
            blockStarts: Self.headingBoundaries(of: document.chapters, engine: engine)
        )
    }

    /// The first word of every chapter heading that repeats its chapter's
    /// title, and the first word after it. A chapter without one isn't a
    /// boundary: a PDF bookmark can start it mid-sentence.
    private static func headingBoundaries(of chapters: [Chapter], engine: RSVPEngine) -> [Int] {
        chapters.flatMap { chapter -> [Int] in
            let bodyStart = engine.readingStart(ofChapterAt: chapter.wordIndex)
            return bodyStart > chapter.wordIndex ? [chapter.wordIndex, bodyStart] : []
        }
    }

    @State private var searchQuery: String = ""
    /// Start word index of each match, ascending. Phrase queries span several
    /// words; navigation, counting, and scrolling all key off the start.
    @State private var matchIndices: [Int] = []
    /// Word range each match covers, parallel to `matchIndices` — one word
    /// unless the query is a phrase reaching past a word's end.
    @State private var matchRanges: [Range<Int>] = []
    /// Every word index inside a match, for O(1) per-word highlight lookups
    /// so chunk renders don't rebuild a Set. Only ever assigned through
    /// ``setMatches(_:precomputedSet:)`` so it can't drift from
    /// `matchIndices` and `matchRanges`.
    @State private var matchSet: Set<Int> = []
    @State private var currentMatchPosition: Int = 0
    @State private var renderedChunks: Set<Int> = []
    @State private var pendingWordScroll: PendingWordScroll?
    /// Lazily-built lowercased copy of `words`, computed off-main on first
    /// search so each keystroke doesn't re-lowercase the whole document.
    @State private var lowercasedWords: [String]?
    /// The in-flight lowercase pass, memoized so racing searches during the
    /// initial build all await one pass instead of spawning duplicates.
    @State private var lowercaseTask: Task<[String], Never>?
    /// The query whose results `matchIndices` currently holds. Lets onSubmit
    /// distinguish fresh matches from a stale set awaiting the debounce.
    @State private var lastCompletedQuery: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    @FocusState private var passageFocused: Bool

    /// A word-center scroll that's waiting for its containing chunk to be
    /// realized. Consumed by the `renderedChunks` `onChange` handler in the
    /// passage scroll body.
    private struct PendingWordScroll {
        let target: Int
        let animated: Bool
    }

    private var readerFont: ReaderFont {
        ReaderFont.resolve(readerFontSelection)
    }

    private var textTone: ReaderTextTone {
        ReaderTextTone.resolve(readerTextToneSelection)
    }

    private var highlightColor: ReaderHighlightColor {
        ReaderHighlightColor.resolve(readerHighlightColorSelection)
    }

    private var contentMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? 720 : .infinity
    }

    private var words: [String] {
        engine.words
    }

    /// Stable scroll id for an individual word. Distinct namespace from the
    /// `LazyVStack` chunk ids (plain `Int`) so they can't collide.
    fileprivate static func wordScrollID(_ wordIndex: Int) -> String {
        "word-\(wordIndex)"
    }

    /// Word range of the active match — one word for plain queries, the full
    /// span for phrases. Clamped defensively; matches always fit by
    /// construction.
    private var currentMatchRange: Range<Int>? {
        guard currentMatchPosition < matchRanges.count else { return nil }
        let range = matchRanges[currentMatchPosition]
        return range.lowerBound..<min(range.upperBound, words.count)
    }

    var body: some View {
        ZStack {
            ReaderBackdrop().ignoresSafeArea()

            VStack(spacing: 0) {
                header
                searchBar
                if !searchQuery.isEmpty {
                    searchNav
                }
                passageScroll
            }
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .preferredColorScheme(.dark)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        .modifier(HorizontalSystemBars())
        #endif
        .focusable()
        .focusEffectDisabled()
        .focused($passageFocused)
        .onAppear {
            // Take keyboard focus so Escape works immediately on macOS —
            // without this the key press has no responder until the user
            // clicks somewhere.
            passageFocused = true
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(StrobeTheme.displayFont(size: 20, relativeTo: .title3))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
                Text("Word \(engine.currentIndex + 1) of \(words.count)")
                    .font(StrobeTheme.metadataFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 12)

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
            }
            .buttonStyle(ReaderGlassButtonStyle(shape: Capsule()))
            .accessibilityHint("Close text view")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// The round button at the lower right of the scroll that brings the
    /// current word back into view, in the color that marks it. Publishes
    /// via `scrollIntent` so the actual `scrollTo` runs inside the
    /// `ScrollViewReader` closure that owns the proxy.
    private var floatingFocusButton: some View {
        ReaderGlassButton(
            systemImage: "scope",
            accessibilityLabel: "Center on current word",
            tint: textTone.anchorColor(for: highlightColor),
            diameter: 48
        ) {
            scrollIntent = .currentWord
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        StrobeSearchBar(
            placeholder: "Search text",
            text: $searchQuery,
            onClear: {
                searchTask?.cancel()
                searchQuery = ""
                setMatches([])
                currentMatchPosition = 0
                lastCompletedQuery = nil
            }
        ) { field in
            field
                .focused($searchFocused)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.search)
                #endif
                .onSubmit {
                    if searchQuery == lastCompletedQuery, !matchIndices.isEmpty {
                        stepMatch(by: 1)
                    } else {
                        // The debounced search hasn't landed for this query
                        // yet — run it now rather than stepping through the
                        // previous query's stale matches.
                        runSearch(immediate: true)
                    }
                }
                .onChange(of: searchQuery) { _, _ in
                    runSearch()
                }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var searchNav: some View {
        HStack(spacing: 10) {
            Text(matchCountLabel)
                .font(.footnote)
                .foregroundStyle(matchIndices.isEmpty ? HierarchicalShapeStyle.tertiary : .secondary)
                .monospacedDigit()

            Spacer()

            ReaderGlassButton(systemImage: "chevron.up", accessibilityLabel: "Previous match") {
                stepMatch(by: -1)
            }
            .disabled(matchIndices.isEmpty)

            ReaderGlassButton(systemImage: "chevron.down", accessibilityLabel: "Next match") {
                stepMatch(by: 1)
            }
            .disabled(matchIndices.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    private var matchCountLabel: String {
        if matchIndices.isEmpty {
            let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            return q.isEmpty ? "" : "No matches"
        }
        return "\(currentMatchPosition + 1) of \(matchIndices.count)"
    }

    // MARK: - Scroll intent
    //
    // SwiftUI's `ScrollViewProxy` can only be used inside a `ScrollViewReader`'s
    // closure. We publish "scroll requests" from buttons / search nav into this
    // state and have a single `onChange` inside the reader actually issue the
    // scrollTo. Nil after the scroll has been consumed.
    enum ScrollIntent: Equatable {
        case currentWord
        case matchPosition(Int)
    }
    @State private var scrollIntent: ScrollIntent?

    // MARK: - Passage scroll

    @ViewBuilder
    private var passageScroll: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<chunks.count, id: \.self) { idx in
                            WordChunkView(
                                words: words,
                                range: chunks.range(at: idx),
                                currentIndex: engine.currentIndex,
                                matchSet: matchSet,
                                currentMatchRange: currentMatchRange,
                                font: readerFont,
                                tone: textTone,
                                highlight: highlightColor,
                                onTap: handleWordTap
                            )
                            .id(idx)
                            .padding(.horizontal, 18)
                            .onAppear { renderedChunks.insert(idx) }
                            .onDisappear { renderedChunks.remove(idx) }
                        }
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Follow the *content's* script, not the UI locale — an
                    // Arabic book read on an English device must still flow
                    // right-to-left or every line renders in reversed order.
                    .environment(\.layoutDirection, isRTLContent ? .rightToLeft : .leftToRight)
                }
                .mask(edgeFadeMask)
                .onAppear {
                    performScroll(.currentWord, proxy: proxy, animated: false)
                }
                .onChange(of: scrollIntent) { _, intent in
                    guard let intent else { return }
                    performScroll(intent, proxy: proxy, animated: true)
                    scrollIntent = nil
                }
                .onChange(of: renderedChunks) { _, newChunks in
                    guard let pending = pendingWordScroll,
                          newChunks.contains(chunks.index(containing: pending.target)) else { return }
                    pendingWordScroll = nil
                    scrollToWord(pending.target, proxy: proxy, animated: pending.animated)
                }
            }

            floatingFocusButton
                .padding(.trailing, 20)
                .padding(.bottom, 24)
        }
    }

    /// Top + bottom alpha fade applied to the passage scroll so words ease
    /// in/out of the viewport instead of being abruptly clipped. Mask values
    /// are alpha only — the actual gradient colors don't matter.
    private var edgeFadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.clear, .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 36)

            Rectangle().fill(Color.black)

            LinearGradient(
                colors: [.black, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 36)
        }
    }

    private func performScroll(_ intent: ScrollIntent, proxy: ScrollViewProxy, animated: Bool) {
        let targetWord: Int
        switch intent {
        case .currentWord:
            targetWord = engine.currentIndex
        case .matchPosition(let pos):
            guard !matchIndices.isEmpty, pos < matchIndices.count else { return }
            targetWord = matchIndices[pos]
        }
        let chunk = chunks.index(containing: targetWord)

        if renderedChunks.contains(chunk) {
            // Chunk is in the hierarchy — the word-level id resolves now.
            scrollToWord(targetWord, proxy: proxy, animated: animated)
        } else {
            // Off-screen target: pre-scroll to the chunk using an anchor that
            // approximates the word's vertical position within the chunk. That
            // way the pre-scroll lands close to the final centered position,
            // so the word-level fine-tune (consumed by the renderedChunks
            // onChange below) is a small smooth adjustment rather than a jump.
            pendingWordScroll = PendingWordScroll(target: targetWord, animated: animated)
            let range = chunks.range(at: chunk)
            let posInChunk = CGFloat(targetWord - range.lowerBound) / CGFloat(max(1, range.count))
            let approxAnchor = UnitPoint(x: 0.5, y: posInChunk)
            if animated {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(chunk, anchor: approxAnchor)
                }
            } else {
                proxy.scrollTo(chunk, anchor: approxAnchor)
            }
        }
    }

    private func scrollToWord(_ wordIndex: Int, proxy: ScrollViewProxy, animated: Bool) {
        let wordID = Self.wordScrollID(wordIndex)
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(wordID, anchor: .center)
            }
        } else {
            proxy.scrollTo(wordID, anchor: .center)
        }
    }

    // MARK: - Actions

    private func handleWordTap(_ index: Int) {
        guard index >= 0, index < words.count else { return }
        engine.seek(to: index)
        scrollIntent = .currentWord
        HapticManager.shared.scrubTick()
    }

    /// Single funnel for updating the search results: assigns `matchIndices`,
    /// `matchRanges`, and the covering `matchSet` together. `precomputedSet`
    /// lets the search task reuse the Set it already built off the main
    /// thread.
    private func setMatches(_ ranges: [Range<Int>], precomputedSet: Set<Int>? = nil) {
        matchIndices = ranges.map(\.lowerBound)
        matchRanges = ranges
        matchSet = precomputedSet ?? Self.coveredIndices(of: ranges)
    }

    private func runSearch(immediate: Bool = false) {
        searchTask?.cancel()
        let query = searchQuery
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setMatches([])
            currentMatchPosition = 0
            lastCompletedQuery = nil
            return
        }

        // Debounced (unless submitted explicitly): scanning every word of a
        // long document per keystroke would waste work mid-typing. Both the
        // one-time lowercasing and the per-query scan run off the main thread.
        searchTask = Task {
            if !immediate {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
            }

            let lowered = await lowercasedWordsCache()
            guard !Task.isCancelled else { return }

            let (results, resultSet) = await Task.detached(priority: .userInitiated) {
                let ranges = Self.findMatchRanges(query: query, inLowercasedWords: lowered)
                return (ranges, Self.coveredIndices(of: ranges))
            }.value
            guard !Task.isCancelled, query == searchQuery else { return }
            setMatches(results, precomputedSet: resultSet)
            lastCompletedQuery = query
            if results.isEmpty {
                currentMatchPosition = 0
                return
            }
            // Land on the match closest to the user's current reading position
            // so they don't get yanked far away from where they were.
            currentMatchPosition = Self.nearestMatchPosition(to: engine.currentIndex, in: matchIndices)
            scrollIntent = .matchPosition(currentMatchPosition)
        }
    }

    /// Returns the lowercased word list, building it off-main at most once.
    /// The result is cached even when the awaiting search was cancelled —
    /// the completed pass is valid for every future query.
    private func lowercasedWordsCache() async -> [String] {
        if let cached = lowercasedWords { return cached }
        let task: Task<[String], Never>
        if let existing = lowercaseTask {
            task = existing
        } else {
            let snapshot = words
            task = Task.detached(priority: .userInitiated) {
                snapshot.map { $0.lowercased() }
            }
            lowercaseTask = task
        }
        let lowered = await task.value
        lowercasedWords = lowered
        return lowered
    }

    private func stepMatch(by delta: Int) {
        guard !matchIndices.isEmpty else { return }
        let n = matchIndices.count
        currentMatchPosition = (currentMatchPosition + delta + n) % n
        scrollIntent = .matchPosition(currentMatchPosition)
        HapticManager.shared.scrubTick()
    }

    // MARK: - Pure helpers (testable)

    /// Case-insensitive search over `words`. A single-word query matches as a
    /// substring inside any word; a query containing whitespace matches as a
    /// phrase, exactly as the phrase reads in the space-joined passage text.
    /// Empty/whitespace-only queries yield no matches. Returned indices are
    /// the first word of each match, ascending and distinct.
    nonisolated static func findMatches(query: String, in words: [String]) -> [Int] {
        findMatchRanges(query: query, inLowercasedWords: words.map { $0.lowercased() }).map(\.lowerBound)
    }

    /// The word range of every match of `query`, over pre-lowercased words so
    /// the per-keystroke search path can reuse a cached lowercased copy
    /// instead of re-lowercasing the whole document each time. Ranges are
    /// ascending with distinct starts.
    ///
    /// A word can hold a space — the tokenizer joins number units such as
    /// `2000 BCE` — so a phrase match covers as many words as it reaches
    /// into, which can be fewer than the query has tokens.
    nonisolated static func findMatchRanges(query: String, inLowercasedWords words: [String]) -> [Range<Int>] {
        let tokens = queryTokens(query)
        guard let first = tokens.first else { return [] }
        var results: [Range<Int>] = []
        results.reserveCapacity(min(words.count, 256))

        if tokens.count == 1 {
            for (i, word) in words.enumerated() where word.contains(first) {
                results.append(i..<(i + 1))
            }
            return results
        }

        // Phrase query: the passage renders words separated by single spaces,
        // so the query matches wherever it occurs in that joined text.
        // Matching runs over pieces, the space-separated parts of each word:
        // the first token must end a piece, middle tokens must equal whole
        // pieces, and the last token must begin the piece after.
        let lastToken = tokens.count - 1

        /// Adds a match, merged into the previous one when both start in the
        /// same word, so starts stay distinct.
        func addMatch(_ range: Range<Int>) {
            if let previous = results.last, previous.lowerBound == range.lowerBound {
                results[results.count - 1] = previous.lowerBound..<max(previous.upperBound, range.upperBound)
            } else {
                results.append(range)
            }
        }

        /// The word where the match ends, given that the first token ends the
        /// piece of word `start` that stops at `firstEnd`; `nil` when the
        /// pieces after it don't match the rest of the query.
        func matchEnd(from start: Int, firstEnd: String.Index) -> Int? {
            var word = start
            var pieceEnd = firstEnd
            for k in 1...lastToken {
                let pieceStart: String.Index
                if pieceEnd < words[word].endIndex {
                    pieceStart = words[word].utf8.index(after: pieceEnd)
                } else if word + 1 < words.count {
                    word += 1
                    pieceStart = words[word].startIndex
                } else {
                    return nil
                }
                pieceEnd = words[word].utf8[pieceStart...].firstIndex(of: UInt8(ascii: " ")) ?? words[word].endIndex
                let piece = words[word][pieceStart..<pieceEnd]
                guard k == lastToken ? piece.hasPrefix(tokens[k]) : piece == tokens[k] else { return nil }
            }
            return word
        }

        for (i, word) in words.enumerated() {
            var pieceStart = word.startIndex
            while let space = word.utf8[pieceStart...].firstIndex(of: UInt8(ascii: " ")) {
                if word[..<space].hasSuffix(first), let end = matchEnd(from: i, firstEnd: space) {
                    addMatch(i..<(end + 1))
                }
                pieceStart = word.utf8.index(after: space)
            }
            if word.hasSuffix(first), let end = matchEnd(from: i, firstEnd: word.endIndex) {
                addMatch(i..<(end + 1))
            }
        }
        return results
    }

    /// Every word index inside a match — the set driving per-word highlight
    /// lookups.
    nonisolated static func coveredIndices(of ranges: [Range<Int>]) -> Set<Int> {
        var covered = Set<Int>(minimumCapacity: ranges.count)
        for range in ranges {
            covered.formUnion(range)
        }
        return covered
    }

    /// Lowercased whitespace-separated tokens of `query`; empty for
    /// whitespace-only queries. Splitting also normalizes runs of interior
    /// whitespace, mirroring how the tokenizer collapsed the document text.
    nonisolated private static func queryTokens(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Whether the words are dominantly right-to-left (Arabic) script,
    /// sampled from the first `sampleLimit` words.
    nonisolated static func isRTLDominant(_ words: [String], sampleLimit: Int = 200) -> Bool {
        var rtlCount = 0
        var totalCount = 0
        for word in words.prefix(sampleLimit) {
            for scalar in word.unicodeScalars where scalar.properties.isAlphabetic {
                totalCount += 1
                if isRTLScalar(scalar) { rtlCount += 1 }
            }
        }
        return totalCount > 0 && rtlCount * 2 > totalCount
    }

    nonisolated private static func isRTLScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x0600...0x06FF).contains(v)   // Arabic
            || (0x0750...0x077F).contains(v)   // Arabic Supplement
            || (0x08A0...0x08FF).contains(v)   // Arabic Extended-A
            || (0xFB50...0xFDFF).contains(v)   // Arabic presentation forms A
            || (0xFE70...0xFEFF).contains(v)   // Arabic presentation forms B
    }

    /// Position into `matches` of the entry closest to `wordIndex`. Ties
    /// break toward the earlier (smaller-index) match. `matches` must be
    /// sorted ascending. Returns 0 for an empty array.
    static func nearestMatchPosition(to wordIndex: Int, in matches: [Int]) -> Int {
        guard !matches.isEmpty else { return 0 }
        var lo = 0
        var hi = matches.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if matches[mid] < wordIndex { lo = mid + 1 } else { hi = mid }
        }
        if lo == 0 { return 0 }
        if lo == matches.count { return matches.count - 1 }
        let prevDelta = abs(matches[lo - 1] - wordIndex)
        let nextDelta = abs(matches[lo] - wordIndex)
        return prevDelta <= nextDelta ? lo - 1 : lo
    }
}

// MARK: - Word chunk

/// Renders a contiguous slice of words in a flowing layout. Lifted out of
/// `PassageView` so SwiftUI can diff and re-render chunks independently,
/// keeping per-tap rerenders cheap on long documents.
private struct WordChunkView: View {
    let words: [String]
    let range: Range<Int>
    let currentIndex: Int
    let matchSet: Set<Int>
    let currentMatchRange: Range<Int>?
    let font: ReaderFont
    let tone: ReaderTextTone
    let highlight: ReaderHighlightColor
    let onTap: (Int) -> Void

    var body: some View {
        WordFlowLayout(spacing: 5, lineSpacing: 6) {
            ForEach(range, id: \.self) { i in
                WordToken(
                    text: words[i],
                    isCurrent: i == currentIndex,
                    isPrimaryMatch: currentMatchRange?.contains(i) ?? false,
                    isMatch: matchSet.contains(i),
                    font: font,
                    tone: tone,
                    highlight: highlight
                ) {
                    onTap(i)
                }
                .id(PassageView.wordScrollID(i))
            }
        }
    }
}

/// A single tappable word in the passage view. Visually conveys three states:
/// the current reading position (filled in the highlight color), the active
/// search match (solid yellow), and any other search match (faded yellow).
private struct WordToken: View {
    let text: String
    let isCurrent: Bool
    let isPrimaryMatch: Bool
    let isMatch: Bool
    let font: ReaderFont
    let tone: ReaderTextTone
    let highlight: ReaderHighlightColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(font.regularFont(size: 18))
                .foregroundStyle(textColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(backgroundColor)
                )
                // Expand the tap target beyond the visible token — word rows
                // are otherwise well under the 44pt minimum touch size. Kept
                // at 2pt per side so expanded shapes never overlap the 5pt
                // word gap / 6pt line gap (overlap would route edge taps to
                // the adjacent word).
                .contentShape(Rectangle().inset(by: -2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityHint(isCurrent ? "Current word" : "Tap to jump here")
    }

    private var textColor: Color {
        if isCurrent { return tone.textColorOnAnchor(for: highlight) }
        if isPrimaryMatch { return .black }
        return tone.textColor
    }

    private var backgroundColor: Color {
        if isCurrent { return tone.anchorColor(for: highlight) }
        if isPrimaryMatch { return Color.yellow.opacity(0.9) }
        if isMatch { return Color.yellow.opacity(0.28) }
        return .clear
    }
}

// MARK: - Flow layout

/// Wraps a row of words across multiple lines, sized by each subview's
/// intrinsic width. Follows the environment's layout direction: in
/// right-to-left contexts (set from the *content's* script by PassageView)
/// each line is mirrored so words flow right-to-left.
private struct WordFlowLayout: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let result = arrange(subviews: subviews, in: width)
        return CGSize(width: width.isFinite ? width : result.maxLineWidth, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews: subviews, in: bounds.width)
        // Custom layouts don't get automatic RTL mirroring — flip x manually.
        let isRTL = subviews.layoutDirection == .rightToLeft
        for (i, frame) in result.frames.enumerated() {
            let x = isRTL
                ? bounds.maxX - frame.minX - frame.width
                : bounds.minX + frame.minX
            subviews[i].place(
                at: CGPoint(x: x, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private struct Arrangement {
        var frames: [CGRect]
        var height: CGFloat
        var maxLineWidth: CGFloat
    }

    private func arrange(subviews: Subviews, in width: CGFloat) -> Arrangement {
        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                maxLineWidth = max(maxLineWidth, x - spacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        maxLineWidth = max(maxLineWidth, x - spacing)
        return Arrangement(frames: frames, height: y + lineHeight, maxLineWidth: maxLineWidth)
    }
}
