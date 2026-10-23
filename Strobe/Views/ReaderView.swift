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
/// is off or a voice reads aloud), release to pause, swipe to scrub, two
/// fingers to read hands-free (see ``ReaderTouch``). Paused, a top bar holds
/// Back, the title, Read Aloud, View Text, and the speed slider, and a
/// bottom panel holds chapter navigation (when chapters exist) and the
/// progress bar with the time left; both fade out while reading. With
/// reading aloud on, a voice paces the words (``ReadAloudController``).
/// Shows a completion card at the end. Persists reading state on disappear
/// and scene phase changes.
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
    @AppStorage(ReaderSettings.Keys.wordPopEnabled) private var wordPopEnabled: Bool = ReaderSettings.Defaults.wordPopEnabled
    @AppStorage(ReaderSettings.Keys.readAloudEnabled) private var readAloudEnabled: Bool = ReaderSettings.Defaults.readAloudEnabled
    @AppStorage(ReaderSettings.Keys.readAloudVoice) private var readAloudVoice: String = ReaderSettings.Defaults.readAloudVoice
    @Bindable var document: Document
    @State private var engine: RSVPEngine
    @State private var readAloud = ReadAloudController()
    @State private var readAloudPrompt: ReadAloudPrompt?
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

    /// On iPad and Mac the bottom panel keeps to a comfortable column so its
    /// sliders don't stretch the full width of a 13" display.
    private var controlsMaxWidth: CGFloat {
        #if os(macOS)
        560
        #else
        horizontalSizeClass == .regular ? 560 : .infinity
        #endif
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
                let fold = ReaderFold(geo)
                ReaderStageLayout(
                    topInset: geo.safeAreaInsets.top,
                    bottomInset: geo.safeAreaInsets.bottom,
                    foldBand: fold.band,
                    wordHeight: CGFloat(fontSize) * WordView.guideLineHeightRatio
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
                            contextIsRightToLeft: isRightToLeftDocument,
                            popsWords: wordPopEnabled
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
                // Half open with the fold down the middle, the reader keeps
                // to the leading page. The gesture layer still spans both.
                .frame(width: fold.pageWidth)
            }
            // The reader never hosts a keyboard; one dismissing from the
            // passage view's search must not move the fixation line.
            .ignoresSafeArea(.keyboard)
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        .modifier(HorizontalSystemBars())
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
        // The time left follows the timing settings once the document's pace
        // is worked out, and again after they change.
        .task(id: ReadingPace.shared.key(for: document)) {
            ReadingPace.shared.prepare(document)
        }
        // Reading aloud follows its settings and the voice model's download
        // while the reader is open.
        .task(id: readAloudSetup) {
            if KokoroVoiceModel.isSupported {
                await readAloud.update(readAloudSetup, engine: engine)
            }
        }
        .onAppear {
            readerFocused = true
            AppRouter.shared.readerDidAppear(documentID: document.id)
        }
        .marksDocumentOpen(document.id)
        .keepsVoiceModelLoaded(readAloud.usesVoiceModel)
        // Re-assert keyboard focus whenever any overlay (passage view, chapter
        // picker, save-error or read-aloud alert) closes, so Space/arrow
        // shortcuts keep working on macOS. One derived flag covers all
        // presentations — adding a new one only requires extending
        // `isPresentingOverlay`.
        .onChange(of: isPresentingOverlay) { _, isPresenting in
            if !isPresenting { readerFocused = true }
        }
        .onDisappear {
            persistState(pauseEngine: true, touchLastReadDate: true)
            AppRouter.shared.readerDidDisappear(documentID: document.id)
        }
        .onChange(of: scenePhase) { _, newPhase in
            readAloud.isInForeground = newPhase == .active
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
            // going inactive, the last word. A voice that got ready while
            // the words played reads from here.
            if !isNowPlaying {
                isHandsFree = false
                readAloud.playbackDidPause()
            }
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
        .onChange(of: engine.effectiveWordsPerMinute) { _, newValue in
            // A speed set another way (VoiceOver's adjust actions, reading
            // aloud's cap) moves the slider with it.
            if !isAdjustingWPM { wpmSliderValue = Double(newValue) }
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
        .readAloudPrompts($readAloudPrompt, isEnabled: $readAloudEnabled, controller: readAloud)
        #if os(iOS)
        .fullScreenCover(isPresented: $showPassage) {
            // The cover hides the reader, which counts as closing it.
            PassageView(document: document, engine: engine)
                .marksDocumentOpen(document.id)
                .keepsVoiceModelLoaded(readAloud.usesVoiceModel)
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
        showPassage || showChapterPicker || persistenceError != nil || readAloudPrompt != nil
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
                    if holdsToRead {
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

    /// Whether a touch holds to read. Reading aloud, a tap plays and pauses.
    private var holdsToRead: Bool {
        ReaderTouch.holdsToRead(setting: holdToReadEnabled, readsAloud: readAloud.isReadingAloud)
    }

    private var touchSituation: ReaderTouch.Situation {
        ReaderTouch.Situation(
            holdToRead: holdsToRead,
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

    /// Back, the title, Read Aloud, and View Text, laid out like a
    /// navigation bar, over the speed. Speed sits up here rather than in
    /// the bottom panel so the two bars stay about the same height: the
    /// word's line has to clear both on the smallest screens, and the marks
    /// above the word get the room to the nearer bar.
    private var topBar: some View {
        VStack(spacing: 0) {
            navigationRow
            speedControl
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .constrainedAndCentered(maxWidth: controlsMaxWidth)
        }
        .opacity(engine.isPlaying ? 0.0 : 1.0)
        // Zero opacity does not disable hit testing — without this, taps
        // during playback land on the invisible controls instead of the
        // gesture layer (and can silently change the reading speed).
        .allowsHitTesting(!engine.isPlaying)
        .animation(.easeInOut(duration: navFadeDuration), value: engine.isPlaying)
    }

    private var navigationRow: some View {
        HStack(spacing: 12) {
            ReaderGlassButton(systemImage: "chevron.left", accessibilityLabel: "Back") {
                dismiss()
            }

            Text(document.title)
                .font(StrobeTheme.displayFont(size: 17, relativeTo: .headline))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                // The completion card shows the title itself.
                .opacity(showCompletion ? 0 : 1)
                .accessibilityAddTraits(.isHeader)

            // Only a device that can run the voice model reads aloud.
            if KokoroVoiceModel.isSupported {
                ReadAloudButton(controller: readAloud, isEnabled: readAloudEnabled) { tap in
                    readAloudButtonTapped(tap)
                }
            }

            ReaderGlassButton(systemImage: "text.alignleft", accessibilityLabel: "View Text") {
                showPassage = true
            }
            .accessibilityHint("Shows the full passage with your current word highlighted")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        let paceFactor = ReadingPace.shared.factor(for: document)

        return VStack(spacing: 0) {
            if !document.chapters.isEmpty {
                ChapterNavigationView(
                    chapters: document.chapters,
                    engine: engine,
                    wordsPerMinute: displayedWPM,
                    paceFactor: paceFactor,
                    furthestWordIndex: document.displayedFurthestWordIndex,
                    showChapterPicker: $showChapterPicker
                ) {
                    if showCompletion {
                        withAnimation { showCompletion = false }
                    }
                }
                .padding(.bottom, 22)
            }

            ReaderProgressView(
                engine: engine,
                wordsPerMinute: displayedWPM,
                paceFactor: paceFactor,
                showCompletion: $showCompletion
            )

            Text(hintText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                #if os(iOS)
                .multilineTextAlignment(.center)
                // Hold to Read's hint takes two lines, kept while the
                // completion card hides it so nothing above it moves.
                .lineLimit(2, reservesSpace: holdToReadEnabled)
                #endif
                .opacity(showCompletion ? 0 : 1)
                .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .constrainedAndCentered(maxWidth: controlsMaxWidth)
    }

    /// The reading speed: the value over a slider from slow to fast. Neutral,
    /// so the red stays with the progress bar and the word.
    private var speedControl: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Speed")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text("\(displayedWPM) wpm")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
            .font(StrobeTheme.metadataFont)
            .accessibilityHidden(true)

            // Continuous, rounding to steps itself: a stepped slider marks
            // each of the 91 steps with a tick on iOS 26 and later.
            Slider(value: steppedWPMSliderValue, in: speedRange) {
                Text("Speed")
            } minimumValueLabel: {
                Image(systemName: "tortoise.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } maximumValueLabel: {
                Image(systemName: "hare.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } onEditingChanged: { editing in
                isAdjustingWPM = editing
                if !editing {
                    applyWPM(Int(wpmSliderValue), withHaptic: true)
                }
            }
            // The row above names it; macOS would show "Speed" again beside
            // the slider.
            .labelsHidden()
            .tint(.white)
            .frame(minHeight: 44)
            .accessibilityLabel("Speed")
            .accessibilityValue("\(displayedWPM) words per minute")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    nudgeSpeed(by: Int(ReaderSettings.wpmStep))
                case .decrement:
                    nudgeSpeed(by: -Int(ReaderSettings.wpmStep))
                @unknown default:
                    break
                }
            }
        }
    }

    /// The speeds the slider offers: up to reading aloud's cap while a
    /// voice reads.
    private var speedRange: ClosedRange<Double> {
        readAloud.isReadingAloud ? ReaderSettings.readAloudWPMRange : ReaderSettings.wpmRange
    }

    /// The speed slider's value, held to whole `wpmStep`s.
    private var steppedWPMSliderValue: Binding<Double> {
        Binding(
            get: { wpmSliderValue },
            set: { wpmSliderValue = ($0 / ReaderSettings.wpmStep).rounded() * ReaderSettings.wpmStep }
        )
    }

    // MARK: - Completion view

    /// The end of the document, laid out like its book page: the cover, the
    /// title, and what to do next.
    private var completionView: some View {
        VStack(spacing: 0) {
            DocumentCover(document: document)
                .frame(width: 84)
                .scaleEffect(reduceMotion ? 1 : (showCompletion ? 1 : 0.8))
                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.7), value: showCompletion)
                .accessibilityHidden(true)

            Text("Finished")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StrobeTheme.accent)
                .padding(.top, 20)

            Text(document.title)
                .font(StrobeTheme.displayFont(size: 26, relativeTo: .title))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)

            Text(engine.words.count == 1 ? "1 word" : "\(engine.words.count.formatted()) words")
                .font(StrobeTheme.metadataFont)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .accessibilityHint("Return to the previous screen")

                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showCompletion = false
                    }
                    engine.restart()
                } label: {
                    Label("Read Again", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .frame(maxWidth: 400)
            .padding(.top, 24)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Hint text

    // The hint lives in the bottom bar, which is hidden during playback —
    // so only paused-state hints exist.
    private var hintText: String {
        #if os(macOS)
        return holdSpeedAdjustEnabled && !readAloud.isReadingAloud
            ? "Press Space to read, arrows to scrub · click-drag up/down for speed"
            : "Press Space to read, arrows to scrub"
        #else
        guard holdsToRead else { return "Tap to read" }
        let hold = holdSpeedAdjustEnabled ? "Hold to read · drag up/down for speed" : "Hold to read"
        return hold + "\nTwo-finger tap to read hands-free"
        #endif
    }

    /// The speed shown: the slider's while it's dragged, else the speed
    /// playback runs at, held to reading aloud's cap.
    private var displayedWPM: Int {
        isAdjustingWPM ? Int(wpmSliderValue) : engine.effectiveWordsPerMinute
    }

    // MARK: - Reading aloud

    private var readAloudSetup: ReadAloudController.Setup {
        readAloud.setup(
            isEnabled: readAloudEnabled,
            isLoaded: isLoaded,
            voice: KokoroVoices.chosen(readAloudVoice).id
        )
    }

    private func readAloudButtonTapped(_ tap: ReadAloudAvailability.Tap) {
        switch tap {
        case .turnOn:
            readAloudEnabled = true
        case .turnOff:
            readAloudEnabled = false
        case .offerDownload:
            readAloudPrompt = .download
        case .retry:
            readAloudEnabled = true
            readAloud.retry()
        case .explainEnglishOnly:
            readAloudPrompt = .englishOnly
        case .explainFailure(let message):
            readAloudPrompt = .failure(message: message)
        }
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
        // Against the speed shown, so leaving the slider at reading aloud's
        // cap keeps a faster speed saved for reading without a voice.
        guard clamped != engine.effectiveWordsPerMinute else { return }
        engine.wordsPerMinute = clamped
        document.wordsPerMinute = value
        if withHaptic {
            HapticManager.shared.selectionTick()
        }
    }

    /// Steps the speed shown by ±`wpmStep`, clamped to the slider's range. The
    /// accessible, touch-mode-independent equivalent of the hold-to-read speed
    /// drag — the WPM slider is hidden during playback, so VoiceOver / Switch
    /// Control users and tap-to-read users otherwise have no in-playback path.
    private func nudgeSpeed(by delta: Int) {
        let lower = Int(speedRange.lowerBound)
        let upper = Int(speedRange.upperBound)
        let target = min(upper, max(lower, engine.effectiveWordsPerMinute + delta))
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
/// Keeps the system bars horizontal where they would otherwise run down a
/// screen's edge (the folded iPhone Duo's outer screen). The reader and the
/// passage view hide the status bar and draw their own bars, so a vertical
/// bar would only reserve an empty column beside the text and push the word
/// off center.
struct HorizontalSystemBars: ViewModifier {
    func body(content: Content) -> some View {
        // Vertical bars arrived in the iOS 27.1 SDK.
        #if canImport(SwiftUI, _version: 8.0.85.29)
        if #available(iOS 27.1, *) {
            content.toolbarVerticalBehavior(.disabled)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

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
    /// Whether each new word pops in while playing (see ``WordPop``).
    let popsWords: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isWordShown = engine.chapterAnnouncement == nil && !engine.isInSentenceBreak
        WordView(
            word: engine.currentWord,
            fontSize: fontSize,
            context: showsContext ? ContextWords.neighbors(of: engine.currentIndex, in: engine.words) : nil,
            contextIsRightToLeft: contextIsRightToLeft,
            contextIsDimmed: showsContext && engine.isPlaying,
            pop: popsWords ? WordPop.readerCue(
                index: engine.currentIndex,
                isShown: isWordShown,
                isPlaying: engine.isPlaying,
                reduceMotion: reduceMotion,
                wordsPerMinute: engine.effectiveWordsPerMinute,
                wordInterval: engine.currentWordInterval
            ) : nil
        )
            .equatable()
            .opacity(isWordShown ? 1 : 0)
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
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
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
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
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

/// The reading position on the library's progress bar, with the share read
/// and the time left under it. Pressing anywhere on it seeks there, and the
/// bar thickens while it's held. VoiceOver adjusts it in 1% steps.
private struct ReaderProgressView: View {
    let engine: RSVPEngine
    /// The speed the time left is worked out at: the slider's while it's
    /// dragged, so the time follows it.
    let wordsPerMinute: Int
    let paceFactor: Double?
    @Binding var showCompletion: Bool
    @State private var isScrubbing = false
    @State private var width: CGFloat = 0

    var body: some View {
        let progress = engine.progress
        // As in the library, past the first word it never reads 0%.
        let percent = progress > 0 ? max(1, Int(progress * 100)) : 0
        let remainingWords = max(0, engine.words.count - 1 - engine.currentIndex)
        let minutesLeft = remainingWords > 0
            ? ReadingTime.minutes(words: remainingWords, wordsPerMinute: wordsPerMinute, paceFactor: paceFactor ?? 1)
            : nil

        VStack(spacing: 10) {
            ReadingProgressBar(progress: progress, height: isScrubbing ? 8 : 4)
                .frame(height: 8)

            ReaderProgressLabels(percent: percent, minutesLeft: minutesLeft)
        }
        // The labels take presses too, which makes a target taller than the
        // bar alone.
        .padding(.top, 8)
        .contentShape(Rectangle())
        .background {
            GeometryReader { geo in
                Color.clear.onChange(of: geo.size.width, initial: true) { _, newWidth in
                    width = newWidth
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard width > 0 else { return }
                    if engine.isPlaying { engine.pause() }
                    isScrubbing = true
                    if showCompletion {
                        withAnimation { showCompletion = false }
                    }
                    let fraction = max(0, min(value.location.x / width, 1))
                    engine.seek(to: Int(fraction * Double(engine.words.count - 1)))
                }
                .onEnded { _ in
                    isScrubbing = false
                }
        )
        .animation(.easeOut(duration: 0.15), value: isScrubbing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reading progress")
        .accessibilityValue(accessibilityValue(percent: percent, minutesLeft: minutesLeft))
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

    private func accessibilityValue(percent: Int, minutesLeft: Int?) -> String {
        var parts = ["\(percent) percent", "word \(engine.currentIndex + 1) of \(engine.words.count)"]
        if let minutesLeft {
            parts.append("\(ReadingTime.spokenLabel(minutes: minutesLeft)) left")
        }
        return parts.joined(separator: ", ")
    }
}

/// The share read and the time left under the progress bar. A view of
/// plain values, so the time is formatted when one of them changes rather
/// than on every word.
private struct ReaderProgressLabels: View {
    let percent: Int
    let minutesLeft: Int?

    var body: some View {
        HStack {
            Text(verbatim: "\(percent)%")
            Spacer(minLength: 12)
            if let minutesLeft {
                Text("\(ReadingTime.label(minutes: minutesLeft)) left")
            }
        }
        .font(StrobeTheme.metadataFont)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}
