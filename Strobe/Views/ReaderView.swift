import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The RSVP reading interface — displays words one at a time.
///
/// Gesture-driven: hold to play (or tap to toggle, when `holdToReadEnabled`
/// is off), release to pause, swipe to scrub, two fingers to read hands-free
/// (see ``ReaderTouch``). Includes a WPM slider, chapter navigation (when
/// chapters exist), progress bar scrubber, and completion overlay. Persists
/// reading state on disappear and scene phase changes.
struct ReaderView: View {
    private let navFadeDuration: Double = 0.3
    private let playIntentDelay: TimeInterval = 0.12

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ReaderSettings.Keys.fontSize) private var fontSize: Int = ReaderSettings.Defaults.fontSize
    @AppStorage(ReaderSettings.Keys.smartTimingEnabled) private var smartTimingEnabled: Bool = ReaderSettings.Defaults.smartTimingEnabled
    @AppStorage(ReaderSettings.Keys.sentencePauseEnabled) private var sentencePauseEnabled: Bool = ReaderSettings.Defaults.sentencePauseEnabled
    @AppStorage(ReaderSettings.Keys.smartTimingPercentPerLetter) private var smartTimingPercentPerLetter: Double = ReaderSettings.Defaults.smartTimingPercentPerLetter
    @AppStorage(ReaderSettings.Keys.smartTimingMinimumWordLength) private var smartTimingMinimumWordLength: Int = ReaderSettings.Defaults.smartTimingMinimumWordLength
    @AppStorage(ReaderSettings.Keys.sentencePauseMultiplier) private var sentencePauseMultiplierValue: Double = ReaderSettings.Defaults.sentencePauseMultiplier
    @AppStorage(ReaderSettings.Keys.complexityTimingEnabled) private var complexityTimingEnabled: Bool = ReaderSettings.Defaults.complexityTimingEnabled
    @AppStorage(ReaderSettings.Keys.complexityIntensity) private var complexityIntensity: Double = ReaderSettings.Defaults.complexityIntensity
    @AppStorage(ReaderSettings.Keys.clausePauseMultiplier) private var clausePauseMultiplier: Double = ReaderSettings.Defaults.clausePauseMultiplier
    @AppStorage(ReaderSettings.Keys.dashPauseMultiplier) private var dashPauseMultiplier: Double = ReaderSettings.Defaults.dashPauseMultiplier
    @AppStorage(ReaderSettings.Keys.ellipsisPauseMultiplier) private var ellipsisPauseMultiplier: Double = ReaderSettings.Defaults.ellipsisPauseMultiplier
    @AppStorage(ReaderSettings.Keys.bracketPauseMultiplier) private var bracketPauseMultiplier: Double = ReaderSettings.Defaults.bracketPauseMultiplier
    @AppStorage(ReaderSettings.Keys.sentenceBreakEnabled) private var sentenceBreakEnabled: Bool = ReaderSettings.Defaults.sentenceBreakEnabled
    @AppStorage(ReaderSettings.Keys.sentenceBreakLength) private var sentenceBreakLength: Double = ReaderSettings.Defaults.sentenceBreakLength
    @AppStorage(ReaderSettings.Keys.holdToReadEnabled) private var holdToReadEnabled: Bool = ReaderSettings.Defaults.holdToReadEnabled
    @AppStorage(ReaderSettings.Keys.holdSpeedAdjustEnabled) private var holdSpeedAdjustEnabled: Bool = ReaderSettings.Defaults.holdSpeedAdjustEnabled
    @AppStorage(ReaderSettings.Keys.contextWordsEnabled) private var contextWordsEnabled: Bool = ReaderSettings.Defaults.contextWordsEnabled
    @AppStorage(ReaderSettings.Keys.enclosingMarksEnabled) private var enclosingMarksEnabled: Bool = ReaderSettings.Defaults.enclosingMarksEnabled
    @Bindable var document: Document
    @State private var engine: RSVPEngine
    @State private var isTouching = false
    @State private var scrubAccumulator: CGFloat = 0
    @State private var touchMode: ReaderTouch.Mode = .undecided
    @State private var pendingPlayWorkItem: DispatchWorkItem?
    /// Reading started by a second finger with Hold to Read on: it goes on
    /// with nothing touching the screen, until any pause.
    @State private var isHandsFree = false
    /// Counts the times hands-free reading started, so its note shows once
    /// for each start and never comes back for the same one.
    @State private var handsFreeStarts = 0
    /// True while the reader's drag is under way. It resets however the
    /// drag finishes, but only a drag that ends normally reaches `onEnded`,
    /// so a reset while `isTouching` is still set means SwiftUI cancelled it.
    @GestureState private var isDragActive = false
    @State private var wpmSliderValue: Double
    @State private var isAdjustingWPM = false
    @State private var isBarScrubbing = false
    @State private var showCompletion = false
    @State private var showChapterPicker = false
    @State private var showPassage = false
    @State private var persistenceError: String?
    @State private var isLoaded = false
    @State private var isBackfillingComplexity = false
    @State private var enclosingMarks: EnclosingMarks?
    @State private var isRightToLeftDocument = false
    /// The engine position last written to the document. Persisting leaves
    /// the document's position alone while the reader hasn't moved from it,
    /// so a newer position synced from another device while this reader
    /// sat open isn't overwritten by a stale one.
    @State private var savedEngineIndex: Int?
    @FocusState private var readerFocused: Bool

    private let startingWordIndex: Int?

    /// The four per-type pause settings as the single value the engine takes,
    /// so one `onChange` forwards a change to any of them.
    private var punctuationPauses: PunctuationPauses {
        PunctuationPauses(
            clause: clausePauseMultiplier,
            dash: dashPauseMultiplier,
            ellipsis: ellipsisPauseMultiplier,
            bracket: bracketPauseMultiplier
        )
    }

    /// On iPad (regular width) we constrain controls to a comfortable column so
    /// sliders and buttons don't stretch the full width of a 12.9" display.
    private var controlsMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? 680 : .infinity
    }

    init(document: Document, startingWordIndex: Int? = nil) {
        self.document = document
        self.startingWordIndex = startingWordIndex
        // Read settings via the shared snapshot because @AppStorage properties
        // aren't accessible before `self` is fully initialized. ReaderSettings
        // owns the keys and defaults the @AppStorage declarations above use.
        let timing = ReaderSettings.timingSnapshot()
        // The engine starts empty; words are decoded off the main actor in
        // `.task` so opening a large document doesn't hitch navigation.
        self._engine = State(initialValue: RSVPEngine(
            words: [],
            wordsPerMinute: document.wordsPerMinute,
            smartTimingEnabled: timing.smartTimingEnabled,
            sentencePauseEnabled: timing.sentencePauseEnabled,
            smartTimingPercentPerLetter: timing.smartTimingPercentPerLetter,
            smartTimingMinimumWordLength: timing.smartTimingMinimumWordLength,
            sentencePauseMultiplier: timing.sentencePauseMultiplier,
            punctuationPauses: timing.punctuationPauses,
            sentenceBreakEnabled: timing.sentenceBreakEnabled,
            sentenceBreakLength: timing.sentenceBreakLength,
            complexityTimingEnabled: timing.complexityTimingEnabled,
            complexityIntensity: timing.complexityIntensity
        ))
        self._wpmSliderValue = State(initialValue: Double(document.wordsPerMinute))
    }

    /// Decodes the word and complexity blobs (off-main) and hands them to the
    /// engine. Runs once; `isLoaded` gates persistence so a reader closed
    /// mid-load can't overwrite the saved position with the empty state.
    private func loadDocumentIfNeeded() async {
        guard !isLoaded else { return }
        let words = await document.loadReadingWordsAsync()
        let scores = await document.loadComplexityScoresAsync()
        let effectiveIndex = startingWordIndex ?? document.currentWordIndex
        // The saved position, not the starting one: opening at a chapter
        // counts as moving there.
        savedEngineIndex = document.currentWordIndex
        engine.load(words: words, currentIndex: effectiveIndex, complexityScores: scores, chapters: document.chapters)
        isRightToLeftDocument = PassageView.isRTLDominant(words)
        isLoaded = true
        // A document resumed at its last word (with more than one word) opens
        // onto the completion card; single-word documents show their word.
        if engine.isAtEnd && engine.words.count > 1 {
            showCompletion = true
        }
        if scores == nil && complexityTimingEnabled {
            backfillComplexityScores()
        }
    }

    /// Pairs the document's quotation and bracket marks for the enclosing
    /// marks display, once the words are loaded and the setting is on. Runs
    /// off-main: it scans every word of the document.
    private func pairEnclosingMarksIfNeeded() async {
        guard enclosingMarksEnabled, isLoaded, enclosingMarks == nil else { return }
        let words = engine.words
        let chapters = document.chapters
        enclosingMarks = await Task.detached(priority: .userInitiated) {
            EnclosingMarks(words: words, chapters: chapters)
        }.value
    }

    /// Computes and stores complexity scores for documents imported before
    /// complexity timing existed — without this, the setting is a silent
    /// no-op for them. Runs off-main; playback works normally meanwhile.
    private func backfillComplexityScores() {
        guard !isBackfillingComplexity else { return }
        let words = engine.words
        guard !words.isEmpty else { return }
        isBackfillingComplexity = true
        Task {
            defer { isBackfillingComplexity = false }
            let scores = await Task.detached(priority: .utility) {
                WordComplexityAnalyzer.analyzeComplexity(words)
            }.value
            document.storeComplexityScores(scores)
            engine.updateComplexityScores(scores)
            // Benign if this fails — the scores are recomputed next open.
            try? modelContext.save()
        }
    }

    var body: some View {
        ZStack {
            // Immersive Background
            ReaderBackdrop()
                .ignoresSafeArea()
            
            // Gesture Layer
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .gesture(unifiedGesture)
                #if os(iOS)
                .modifier(SecondFingerDetector { secondFingerLanded() })
                #endif

            // The reader sits inside the safe area; the proxy's insets tell
            // the layout how far the screen extends beyond it.
            GeometryReader { geo in
                ReaderStageLayout(
                    topInset: geo.safeAreaInsets.top,
                    bottomInset: geo.safeAreaInsets.bottom
                ) {
                    topBar
                        .readerStageRole(.topBar)

                    if showCompletion {
                        completionView
                            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                            .readerStageRole(.betweenBars)
                    } else {
                        CurrentWordView(
                            engine: engine,
                            fontSize: CGFloat(fontSize),
                            showsContext: contextWordsEnabled,
                            contextIsRightToLeft: isRightToLeftDocument
                        )
                        .id("wordview") // stabilize identity
                        .transition(.opacity)
                        // Overlay (not a sibling) so the word never shifts when
                        // the readout appears.
                        .overlay {
                            HoldSpeedReadoutView(engine: engine)
                                .offset(y: CGFloat(fontSize) * 1.4)
                                .accessibilityHidden(true)
                        }
                        // Shown when hands-free reading starts. A finger
                        // coming down (a hold, or the tap that stops reading)
                        // or reading stopping puts it away for good.
                        .overlay {
                            HandsFreeLabelView(
                                engine: engine,
                                start: handsFreeStarts,
                                isDismissed: !isHandsFree || isTouching
                            )
                                .offset(y: CGFloat(fontSize) * 1.4)
                                .accessibilityHidden(true)
                        }
                        // The word display sits above the gesture layer; without
                        // this, holding directly on the word would swallow the
                        // hold-to-read gesture.
                        .allowsHitTesting(false)
                        .accessibilityAction(named: engine.isPlaying ? "Pause" : "Play") {
                            togglePlayback()
                        }
                        .accessibilityAction(named: "Increase speed") {
                            nudgeSpeed(by: Int(ReaderSettings.wpmStep))
                        }
                        .accessibilityAction(named: "Decrease speed") {
                            nudgeSpeed(by: -Int(ReaderSettings.wpmStep))
                        }

                        EnclosingMarksView(
                            engine: engine,
                            marks: enclosingMarks,
                            fontSize: CGFloat(fontSize),
                            isEnabled: enclosingMarksEnabled
                        )
                        .transition(.opacity)
                        .readerStageRole(.fixationSurround)
                    }

                    bottomBar
                        .opacity(engine.isPlaying ? 0.0 : 1.0)
                        .allowsHitTesting(!engine.isPlaying)
                        .animation(.easeInOut(duration: 0.2), value: engine.isPlaying)
                        .readerStageRole(.bottomBar)
                }
                .animation(.easeInOut(duration: 0.2), value: engine.isPlaying)
                // Overlay (not a stage subview) so the word never shifts
                // whether the header is on or off.
                .overlay(alignment: .top) {
                    ReaderHeaderView(
                        title: document.title,
                        chapters: document.chapters,
                        engine: engine,
                        fadeDuration: navFadeDuration
                    )
                }
            }
            // The reader never hosts a keyboard; one dismissing from the
            // passage view's search must not move the fixation line.
            .ignoresSafeArea(.keyboard)
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        #elseif os(macOS)
        // The window toolbar's back button would sit beside the top bar's.
        // The toolbar stays, empty and transparent, so the window keeps its
        // traffic lights.
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationTitle(document.title)
        .modifier(HidesWindowTitle())
        #endif
        .task {
            await loadDocumentIfNeeded()
        }
        .task(id: enclosingMarksEnabled && isLoaded) {
            await pairEnclosingMarksIfNeeded()
        }
        .onAppear {
            readerFocused = true
            AppRouter.shared.readerDidAppear(documentID: document.id)
        }
        .marksDocumentOpen(document.id)
        // Re-assert keyboard focus whenever any overlay (passage view, chapter
        // picker, save-error alert) closes, so Space/arrow shortcuts keep
        // working on macOS. One derived flag covers all presentations — adding
        // a new one only requires extending `isPresentingOverlay`.
        .onChange(of: isPresentingOverlay) { _, isPresenting in
            if !isPresenting { readerFocused = true }
        }
        .onDisappear {
            persistState(pauseEngine: true, touchLastReadDate: true)
            AppRouter.shared.readerDidDisappear(documentID: document.id)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .inactive || newPhase == .background {
                // Pause as well as persist — words advancing while the app is
                // covered (Notification Center, app switcher, a call) are
                // words the user never saw.
                persistState(pauseEngine: true, touchLastReadDate: false)
            }
        }
        .onChange(of: showPassage) { _, isShowing in
            // Tapping a word in the passage view seeks the engine — if the
            // completion overlay was up, it's stale once the position left
            // the end. (Deliberately keyed on the sheet, not on
            // `engine.currentIndex`: reading the index here would subscribe
            // the whole reader body to every word tick.)
            if !isShowing && showCompletion && !engine.isAtEnd {
                withAnimation { showCompletion = false }
            }
        }
        .onChange(of: isDragActive) { _, isActive in
            // The drag finished without reaching `onEnded`, which clears
            // `isTouching`: SwiftUI cancelled it.
            if !isActive && isTouching { touchWasCancelled() }
        }
        .onChange(of: engine.isPlaying) { wasPlaying, isNowPlaying in
            // Any pause ends hands-free reading: a tap, Space, the scene
            // going inactive, the last word.
            if !isNowPlaying { isHandsFree = false }
            if wasPlaying && !isNowPlaying && engine.isAtEnd {
                HapticManager.shared.completedReading()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    // The user may have scrubbed away or resumed during the
                    // delay — re-check before showing the overlay.
                    guard engine.isAtEnd, !engine.isPlaying else { return }
                    showCompletionOverlay()
                }
            }
        }
        .onChange(of: smartTimingEnabled) { _, newValue in
            engine.smartTimingEnabled = newValue
        }
        .onChange(of: sentencePauseEnabled) { _, newValue in
            engine.sentencePauseEnabled = newValue
        }
        .onChange(of: smartTimingPercentPerLetter) { _, newValue in
            engine.smartTimingPercentPerLetter = newValue
        }
        .onChange(of: smartTimingMinimumWordLength) { _, newValue in
            engine.smartTimingMinimumWordLength = newValue
        }
        .onChange(of: sentencePauseMultiplierValue) { _, newValue in
            engine.sentencePauseMultiplier = newValue
        }
        .onChange(of: complexityTimingEnabled) { _, newValue in
            engine.complexityTimingEnabled = newValue
            // The setting can be flipped on mid-session (macOS Settings
            // window) for a legacy document with no stored scores.
            if newValue && isLoaded && engine.complexityScores == nil {
                backfillComplexityScores()
            }
        }
        .onChange(of: complexityIntensity) { _, newValue in
            engine.complexityIntensity = newValue
        }
        .onChange(of: punctuationPauses) { _, newValue in
            engine.punctuationPauses = newValue
        }
        .onChange(of: sentenceBreakEnabled) { _, newValue in
            engine.sentenceBreakEnabled = newValue
        }
        .onChange(of: sentenceBreakLength) { _, newValue in
            engine.sentenceBreakLength = newValue
        }
        .alert("Save Error", isPresented: .init(isPresent: $persistenceError)) {
            Button("OK") { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "")
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showPassage) {
            // The cover hides the reader, which counts as closing it.
            PassageView(document: document, engine: engine)
                .marksDocumentOpen(document.id)
        }
        #elseif os(macOS)
        .sheet(isPresented: $showPassage) {
            PassageView(document: document, engine: engine)
                .frame(minWidth: 600, minHeight: 700)
        }
        #endif
        .preferredColorScheme(.dark)
        .focusable()
        .focusEffectDisabled()
        .focused($readerFocused)
        .onKeyPress(.space) {
            guard !showCompletion else { return .ignored }
            togglePlayback()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            scrubWithFeedback(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            scrubWithFeedback(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        #if os(macOS)
        // Cmd+Q doesn't reliably trigger onDisappear/scenePhase on macOS —
        // without this hook, quitting mid-read loses the session's position.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            persistState(pauseEngine: true, touchLastReadDate: true)
        }
        #endif
    }

    /// Shared pause + scrub + haptic used by both arrow keys.
    private func scrubWithFeedback(by delta: Int) {
        if engine.isPlaying { engine.pause() }
        if showCompletion {
            withAnimation { showCompletion = false }
        }
        if engine.scrub(by: delta) {
            HapticManager.shared.scrubBoundary()
        } else {
            HapticManager.shared.scrubTick()
        }
    }

    /// True while any focus-stealing presentation is up. Used to restore
    /// keyboard focus when the last one closes.
    private var isPresentingOverlay: Bool {
        showPassage || showChapterPicker || persistenceError != nil
    }

    // MARK: - Unified gesture

    private var unifiedGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isDragActive) { _, isActive, _ in isActive = true }
            .onChanged { value in
                guard !showCompletion else { return }
                let horizontal = abs(value.translation.width)

                if !isTouching {
                    isTouching = true
                    touchMode = .undecided
                    scrubAccumulator = 0
                    if holdToReadEnabled {
                        schedulePlayIntent()
                    }
                }

                if touchMode == .undecided {
                    if horizontal > 20 {
                        touchMode = .scrubbing
                        cancelPlayIntent()
                        if engine.isPlaying {
                            engine.pause()
                            HapticManager.shared.playPause()
                        }
                    }
                }

                if touchMode == .reading, holdSpeedAdjustEnabled {
                    // Vertical drag while holding adjusts speed live. The
                    // override is nil inside the dead zone so the readout
                    // only appears once the finger commits to adjusting.
                    guard engine.isPlaying else { return }
                    let base = engine.wordsPerMinute
                    let mapped = RSVPEngine.holdSpeedWPM(
                        baseWPM: base,
                        verticalTranslation: value.translation.height
                    )
                    if mapped != engine.effectiveWordsPerMinute {
                        engine.wpmOverride = mapped == base ? nil : mapped
                        // A distinct cue at the 100/1000 rail; otherwise the
                        // per-step selection tick the WPM slider uses.
                        if mapped == Int(ReaderSettings.wpmRange.lowerBound)
                            || mapped == Int(ReaderSettings.wpmRange.upperBound) {
                            HapticManager.shared.scrubBoundary()
                        } else {
                            HapticManager.shared.selectionTick()
                        }
                    }
                }

                if touchMode == .scrubbing {
                    // Scrubbing is a paused-only interaction.
                    guard !engine.isPlaying else { return }

                    let threshold: CGFloat = 30
                    let newAccumulator = value.translation.width
                    let delta = Int(newAccumulator / threshold) - Int(scrubAccumulator / threshold)
                    if delta != 0 {
                        if engine.scrub(by: delta) {
                            HapticManager.shared.scrubBoundary()
                        } else {
                            HapticManager.shared.scrubTick()
                        }
                        scrubAccumulator = newAccumulator
                    }
                }
            }
            .onEnded { _ in
                let endedMode = touchMode
                endTouch()
                apply(ReaderTouch.release(of: endedMode, in: touchSituation))
            }
    }

    /// Clears what a touch set up, however it finished.
    private func endTouch() {
        isTouching = false
        cancelPlayIntent()
        // pause() clears the override; this covers the not-playing
        // edge case (e.g. the document ended mid-hold).
        engine.wpmOverride = nil
        scrubAccumulator = 0
        touchMode = .undecided
    }

    /// A drag SwiftUI cancelled, which it does when a second finger lands
    /// or the system takes the touch over, never reaches `onEnded`. Without
    /// this, its state stays behind for the next touch to trip on.
    private func touchWasCancelled() {
        let cancelledMode = touchMode
        endTouch()
        apply(ReaderTouch.cancellation(
            of: cancelledMode,
            in: touchSituation,
            detection: secondFingerDetection
        ))
    }

    /// A second finger joined the touch: hands-free reading starts or
    /// stops, or with Hold to Read off, the touch counts as a tap.
    private func secondFingerLanded() {
        let outcome = ReaderTouch.secondFinger(in: touchSituation)
        guard outcome != .unchanged else { return }
        cancelPlayIntent()
        // The drag may carry on with the fingers. The rest of it changes
        // nothing: no swipe or speed drag, and lifting doesn't pause.
        if isTouching { touchMode = .twoFinger }
        apply(outcome)
    }

    private var touchSituation: ReaderTouch.Situation {
        ReaderTouch.Situation(
            holdToRead: holdToReadEnabled,
            isPlaying: engine.isPlaying,
            isAtEnd: engine.isAtEnd,
            isHandsFree: isHandsFree,
            showsCompletion: showCompletion
        )
    }

    private var secondFingerDetection: ReaderTouch.SecondFingerDetection {
        #if os(iOS)
        if #available(iOS 18.0, *) { return .counted }
        return .inferredFromCancellation
        #else
        return .unavailable
        #endif
    }

    private func apply(_ outcome: ReaderTouch.Outcome) {
        switch outcome {
        case .unchanged:
            break
        case .play:
            engine.play()
            HapticManager.shared.playPause()
        case .pause:
            engine.pause()
            HapticManager.shared.playPause()
        case .showCompletion:
            showCompletionOverlay()
        case .readHandsFree:
            readHandsFree()
        }
    }

    /// Starts reading with nothing holding the screen, or lets a hold's
    /// reading carry on that way, until a tap or any other pause.
    private func readHandsFree() {
        // pause() clears a hold's speed drag; reading on, it's cleared here.
        engine.wpmOverride = nil
        engine.play()
        // Nothing to read yet while the document loads.
        guard engine.isPlaying else { return }
        isHandsFree = true
        handsFreeStarts += 1
        HapticManager.shared.playPause()
        #if os(iOS)
        AccessibilityNotification.Announcement("Reading hands-free. Tap to stop.").post()
        #endif
    }

    private func schedulePlayIntent() {
        cancelPlayIntent()

        let workItem = DispatchWorkItem {
            guard isTouching, touchMode == .undecided, !showCompletion else { return }
            touchMode = .reading
            if !engine.isPlaying {
                if engine.isAtEnd {
                    showCompletionOverlay()
                } else {
                    engine.play()
                    HapticManager.shared.playPause()
                }
            }
        }
        pendingPlayWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + playIntentDelay, execute: workItem)
    }

    private func cancelPlayIntent() {
        pendingPlayWorkItem?.cancel()
        pendingPlayWorkItem = nil
    }

    /// Shared play/pause toggle used by the Space key and the VoiceOver
    /// custom action, so playback isn't gesture-only.
    private func togglePlayback() {
        if engine.isPlaying {
            engine.pause()
        } else if engine.isAtEnd {
            // Playing at the end is impossible — surface the completion card
            // instead of doing nothing (or worse, a false "playing" haptic).
            showCompletionOverlay()
            return
        } else {
            engine.play()
        }
        HapticManager.shared.playPause()
    }

    /// Presents the completion overlay, respecting Reduce Motion.
    private func showCompletionOverlay() {
        guard !showCompletion else { return }
        if reduceMotion {
            showCompletion = true
        } else {
            withAnimation(.spring(duration: 0.6)) {
                showCompletion = true
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        topBarContent
            .constrainedAndCentered(maxWidth: controlsMaxWidth)
            .animation(.easeInOut(duration: navFadeDuration), value: engine.isPlaying)
    }

    private var topBarContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                CircleIconButton(systemImage: "chevron.left", accessibilityLabel: "Back") {
                    dismiss()
                }

                Spacer()

                VStack(spacing: 2) {
                    Text(document.title)
                        .font(StrobeTheme.bodyFont(size: 16, bold: true))
                        .foregroundStyle(StrobeTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    WordCounterView(engine: engine)
                }

                Spacer()

                CircleIconButton(systemImage: "text.alignleft", accessibilityLabel: "View text") {
                    showPassage = true
                }
                .accessibilityHint("Shows the full passage with your current word highlighted")
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .opacity(engine.isPlaying ? 0.0 : 1.0)
            .allowsHitTesting(!engine.isPlaying)
            
            Spacer().frame(height: 20)
            
            // WPM Control
            HStack {
                Text("\(displayedWPM)")
                    .font(StrobeTheme.bodyFont(size: 24, bold: true))
                    .foregroundStyle(StrobeTheme.accent)
                    .frame(width: 80)

                Text("wpm")
                    .font(StrobeTheme.bodyFont(size: 14))
                    .foregroundStyle(StrobeTheme.textSecondary)
                    .padding(.bottom, 4)
                
                Slider(value: $wpmSliderValue, in: ReaderSettings.wpmRange, step: ReaderSettings.wpmStep) { editing in
                    isAdjustingWPM = editing
                    if !editing {
                        applyWPM(Int(wpmSliderValue), withHaptic: true)
                    }
                }
                .tint(StrobeTheme.accent)
                .frame(minHeight: 44)
                .accessibilityLabel("Words per minute")
                .accessibilityValue("\(displayedWPM) words per minute")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(StrobeTheme.surface.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
            .opacity(engine.isPlaying ? 0.0 : 1.0)
            // Zero opacity does not disable hit testing — without this, taps
            // during playback land on the invisible slider instead of the
            // gesture layer (and can silently change the reading speed).
            .allowsHitTesting(!engine.isPlaying)
        }
        .animation(.easeInOut(duration: navFadeDuration), value: engine.isPlaying)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 16) {
            if !document.chapters.isEmpty {
                ChapterNavigationView(
                    chapters: document.chapters,
                    engine: engine,
                    showChapterPicker: $showChapterPicker
                ) {
                    if showCompletion {
                        withAnimation { showCompletion = false }
                    }
                }
            }

            ProgressScrubberView(
                engine: engine,
                isBarScrubbing: $isBarScrubbing,
                showCompletion: $showCompletion
            )

            Text(hintText)
                .font(StrobeTheme.bodyFont(size: 14))
                .foregroundStyle(StrobeTheme.textSecondary)
                #if os(iOS)
                .multilineTextAlignment(.center)
                // Hold to Read's hint takes two lines. They stay reserved
                // while "Seeking..." stands in, so the progress bar above
                // doesn't jump under the finger dragging it.
                .lineLimit(2, reservesSpace: holdToReadEnabled)
                #endif
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .constrainedAndCentered(maxWidth: controlsMaxWidth)
    }

    // MARK: - Completion view

    private var completionView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(StrobeTheme.accent.opacity(0.2))
                    .frame(width: 100, height: 100)

                Image(systemName: "checkmark")
                    .font(.system(size: 48, weight: .black))
                    .foregroundStyle(StrobeTheme.accent)
            }
            .scaleEffect(reduceMotion ? 1 : (showCompletion ? 1 : 0.5))
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.6), value: showCompletion)

            VStack(spacing: 8) {
                Text("Finished!")
                    .font(StrobeTheme.titleFont(size: 32))
                    .foregroundStyle(StrobeTheme.textPrimary)

                Text(engine.words.count == 1 ? "1 word read" : "\(engine.words.count) words read")
                    .font(StrobeTheme.bodyFont(size: 18))
                    .foregroundStyle(StrobeTheme.textSecondary)
            }

            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(StrobeTheme.bodyFont(size: 16, bold: true))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 16)
                        .background(Color.white.opacity(0.08))
                        .foregroundStyle(StrobeTheme.textPrimary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Return to the previous screen")

                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showCompletion = false
                    }
                    engine.restart()
                } label: {
                    Text("Read Again")
                        .font(StrobeTheme.bodyFont(size: 16, bold: true))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 16)
                        .background(StrobeTheme.accent)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 16)
        }
        .padding(40)
        .background(StrobeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
    }

    // MARK: - Hint text

    // The hint lives in the bottom bar, which is hidden during playback —
    // so only paused-state hints exist.
    private var hintText: String {
        if showCompletion { return "Completed" }
        if isBarScrubbing { return "Seeking..." }
        #if os(macOS)
        return holdSpeedAdjustEnabled
            ? "Press Space to read, arrows to scrub · click-drag up/down for speed"
            : "Press Space to read, arrows to scrub"
        #else
        guard holdToReadEnabled else { return "Tap to read" }
        let hold = holdSpeedAdjustEnabled ? "Hold to read · drag up/down for speed" : "Hold to read"
        return hold + "\nTwo-finger tap to read hands-free"
        #endif
    }

    private var displayedWPM: Int {
        isAdjustingWPM ? Int(wpmSliderValue) : engine.wordsPerMinute
    }

    // MARK: - Persistence

    private func persistState(pauseEngine: Bool, touchLastReadDate: Bool) {
        // Before the async load completes the engine holds no words and index
        // 0 — persisting that would erase the real saved position.
        guard isLoaded else { return }
        if isAdjustingWPM {
            isAdjustingWPM = false
            applyWPM(Int(wpmSliderValue), withHaptic: false)
        }
        if pauseEngine {
            cancelPlayIntent()
            engine.pause()
        }
        let engineIndex = engine.currentIndex
        document.recordPosition(
            currentIndex: engineIndex == savedEngineIndex ? document.currentWordIndex : engineIndex,
            furthestIndex: engine.furthestPlayedIndex,
            // `applyWPM` writes speed changes to the document as they're
            // made; the document's value also keeps a speed synced from
            // another device while this reader was open.
            wordsPerMinute: document.wordsPerMinute,
            touchLastReadDate: touchLastReadDate
        )
        savedEngineIndex = engineIndex
        // Counted here, where every exit path passes, so words read before
        // the app is backgrounded and closed still count toward a reading day.
        let playedWords = engine.takePlayedWordCount()
        if playedWords > 0 {
            ReviewPrompt.update { $0.recordWordsRead(playedWords, at: .now) }
        }
        do {
            try modelContext.save()
        } catch {
            persistenceError = "Could not save reading progress: \(error.localizedDescription)"
        }
    }

    private func applyWPM(_ value: Int, withHaptic: Bool) {
        let clamped = max(1, value)
        guard clamped != engine.wordsPerMinute else { return }
        engine.wordsPerMinute = clamped
        document.wordsPerMinute = value
        if withHaptic {
            HapticManager.shared.selectionTick()
        }
    }

    /// Steps the configured speed by ±`wpmStep`, clamped to `wpmRange`. The
    /// accessible, touch-mode-independent equivalent of the hold-to-read speed
    /// drag — the WPM slider is hidden during playback, so VoiceOver / Switch
    /// Control users and tap-to-read users otherwise have no in-playback path.
    private func nudgeSpeed(by delta: Int) {
        let lower = Int(ReaderSettings.wpmRange.lowerBound)
        let upper = Int(ReaderSettings.wpmRange.upperBound)
        let target = min(upper, max(lower, engine.wordsPerMinute + delta))
        applyWPM(target, withHaptic: true)
    }
}

#if os(macOS)
/// Leaves the reader's title bar empty on macOS 15 and later.
private struct HidesWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}
#endif

#if os(iOS)
/// Calls `action` when a second finger joins a touch on the view. Counts
/// the fingers with a `SpatialEventGesture` beside the view's own gestures,
/// which needs iOS 18. Before that nothing counts them, and the reader
/// takes a cancelled touch for a second finger instead (see
/// ``ReaderTouch/SecondFingerDetection``).
private struct SecondFingerDetector: ViewModifier {
    let action: () -> Void
    /// The most fingers down at once since the touch began. A gesture
    /// state, so it goes back to zero however the touch finishes, and
    /// passes two once per touch.
    @GestureState private var peakTouchCount = 0

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .simultaneousGesture(
                    SpatialEventGesture()
                        .updating($peakTouchCount) { events, peak, _ in
                            peak = max(peak, events.filter { $0.phase == .active }.count)
                        }
                )
                .onChange(of: peakTouchCount) { old, new in
                    if old < 2 && new >= 2 { action() }
                }
        } else {
            content
        }
    }
}
#endif

// MARK: - Per-tick child views
//
// These read `engine.currentIndex`/`currentWord`/`progress` in their own
// bodies so @Observable tracking invalidates only these small subtrees on
// every word tick (16×/sec at 1000 WPM) — not the entire reader.

/// The word display. Isolates the per-tick `currentWord` read, and the
/// neighbours' while context words are on.
private struct CurrentWordView: View {
    let engine: RSVPEngine
    let fontSize: CGFloat
    let showsContext: Bool
    let contextIsRightToLeft: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WordView(
            word: engine.currentWord,
            fontSize: fontSize,
            context: showsContext ? ContextWords.neighbors(of: engine.currentIndex, in: engine.words) : nil,
            contextIsRightToLeft: contextIsRightToLeft,
            contextIsDimmed: showsContext && engine.isPlaying
        )
            .equatable()
            .opacity(engine.chapterAnnouncement == nil && !engine.isInSentenceBreak ? 1 : 0)
            .animation(nil, value: engine.chapterAnnouncement != nil)
            .animation(nil, value: engine.isInSentenceBreak)
            // A sentence break leaves the word in the accessibility tree so
            // VoiceOver focus doesn't move at every sentence.
            .accessibilityHidden(engine.chapterAnnouncement != nil)
            .overlay {
                if let chapter = engine.chapterAnnouncement {
                    ChapterAnnouncementView(title: chapter.title)
                        .opacity(engine.isChapterTitleVisible ? 1 : 0)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: RSVPEngine.chapterFadeDuration),
                       value: engine.isChapterTitleVisible)
    }
}

/// The transient speed readout shown while a hold-to-read vertical drag
/// has an active WPM override. Isolates the per-change speed read.
/// Every speed step restarts a 2s idle window; once idle, the readout
/// fades out over 1s. Release (nil override) fades it quickly.
private struct HoldSpeedReadoutView: View {
    let engine: RSVPEngine
    @State private var isVisible = false
    // Latched so the fade-out keeps showing the last held value instead of
    // flicking to the base WPM when the override clears.
    @State private var shownWPM = 0

    var body: some View {
        Text("\(shownWPM) wpm")
            .font(StrobeTheme.bodyFont(size: 14))
            .monospacedDigit()
            .foregroundStyle(StrobeTheme.textSecondary)
            .opacity(isVisible ? 1 : 0)
            .task(id: engine.wpmOverride) {
                guard let override = engine.wpmOverride else {
                    // Release: fade out quickly, keep the last shown number.
                    withAnimation(.easeInOut(duration: 0.2)) { isVisible = false }
                    return
                }
                shownWPM = override
                withAnimation(.easeInOut(duration: 0.2)) { isVisible = true }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 1)) { isVisible = false }
            }
    }
}

/// The note that reading has gone hands-free and how to stop it, so the
/// two-finger touch explains itself. Shows once when hands-free reading
/// starts and fades out 2s later; dismissing it fades it quickly, and it
/// doesn't return until the next start. Steps aside for a chapter title,
/// which it would run into. Isolates the announcement read.
private struct HandsFreeLabelView: View {
    let engine: RSVPEngine
    /// Changes each time hands-free reading starts; 0 before the first.
    let start: Int
    let isDismissed: Bool
    @State private var isVisible = false

    var body: some View {
        Text("Hands-free · tap to stop")
            .font(StrobeTheme.bodyFont(size: 14))
            .foregroundStyle(StrobeTheme.textSecondary)
            .opacity(isVisible && engine.chapterAnnouncement == nil ? 1 : 0)
            .task(id: start) {
                guard start > 0 else { return }
                withAnimation(.easeInOut(duration: 0.2)) { isVisible = true }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 1)) { isVisible = false }
            }
            .onChange(of: isDismissed) { _, dismissed in
                guard dismissed else { return }
                withAnimation(.easeInOut(duration: 0.2)) { isVisible = false }
            }
    }
}

/// The "n / total" counter in the top bar.
private struct WordCounterView: View {
    let engine: RSVPEngine

    var body: some View {
        Text("\(engine.currentIndex + 1) / \(engine.words.count)")
            .font(StrobeTheme.bodyFont(size: 12))
            .foregroundStyle(StrobeTheme.textSecondary)
    }
}

/// The progress bar with drag-to-seek and VoiceOver adjustment.
private struct ProgressScrubberView: View {
    let engine: RSVPEngine
    @Binding var isBarScrubbing: Bool
    @Binding var showCompletion: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(StrobeTheme.surface)
                    .frame(height: 6)

                Capsule()
                    .fill(StrobeTheme.accent)
                    .frame(width: geo.size.width * engine.progress, height: 6)

                // Thumb
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                    .offset(x: (geo.size.width * engine.progress) - 8)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if engine.isPlaying { engine.pause() }
                        isBarScrubbing = true
                        if showCompletion {
                            withAnimation { showCompletion = false }
                        }
                        let pct = max(0, min(value.location.x / geo.size.width, 1))
                        let target = Int(pct * Double(engine.words.count - 1))
                        engine.seek(to: target)
                    }
                    .onEnded { _ in
                        isBarScrubbing = false
                    }
            )
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("Reading progress")
        .accessibilityValue("\(Int(engine.progress * 100)) percent, word \(engine.currentIndex + 1) of \(engine.words.count)")
        .accessibilityAdjustableAction { direction in
            // Step ~1% per adjustment — single-word steps made the scrubber
            // unusable with VoiceOver on book-length documents.
            let step = max(1, engine.words.count / 100)
            switch direction {
            case .increment:
                _ = engine.scrub(by: step)
            case .decrement:
                _ = engine.scrub(by: -step)
            @unknown default:
                break
            }
            if showCompletion && !engine.isAtEnd {
                showCompletion = false
            }
        }
    }
}
