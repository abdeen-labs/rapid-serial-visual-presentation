import SwiftUI

// MARK: - Rows

/// A settings row: a title and the current value above a stepped slider,
/// with a haptic tick when the slider is let go.
struct SettingsSliderRow<Title: View>: View {
    let value: String
    let accessibilityLabel: String
    let accessibilityValue: String
    @Binding var sliderValue: Double
    let range: ClosedRange<Double>
    let step: Double
    let title: Title

    init(
        value: String,
        accessibilityLabel: String,
        accessibilityValue: String? = nil,
        sliderValue: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        @ViewBuilder title: () -> Title
    ) {
        self.value = value
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue ?? value
        self._sliderValue = sliderValue
        self.range = range
        self.step = step
        self.title = title()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                title
                Spacer(minLength: 12)
                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityHidden(true)

            Slider(value: $sliderValue, in: range, step: step) { editing in
                if !editing {
                    HapticManager.shared.selectionTick()
                }
            }
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
        }
        .padding(.vertical, 2)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
}

extension SettingsSliderRow where Title == Text {
    init(
        _ title: String,
        value: String,
        accessibilityValue: String? = nil,
        sliderValue: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double
    ) {
        self.init(
            value: value,
            accessibilityLabel: title,
            accessibilityValue: accessibilityValue,
            sliderValue: sliderValue,
            in: range,
            step: step
        ) {
            Text(title)
        }
    }
}

/// An `Int` setting as the `Double` a `Slider` edits.
private func sliderBinding(_ value: Binding<Int>) -> Binding<Double> {
    Binding(
        get: { Double(value.wrappedValue) },
        set: { value.wrappedValue = Int($0.rounded()) }
    )
}

// MARK: - Reading

/// The word "Strobe" as the reader draws it, in the current font, size,
/// color, and background, so appearance changes show as they're made. It
/// pops in once when Pop Words In turns on, at the default speed's pace.
struct ReaderPreview: View {
    @AppStorage(ReaderSettings.Keys.defaultWPM) private var defaultWPM: Int = ReaderSettings.Defaults.defaultWPM
    @AppStorage(ReaderSettings.Keys.fontSize) private var fontSize: Int = ReaderSettings.Defaults.fontSize
    @AppStorage(ReaderSettings.Keys.contextWordsEnabled) private var contextWordsEnabled: Bool = ReaderSettings.Defaults.contextWordsEnabled
    @AppStorage(ReaderSettings.Keys.wordPopEnabled) private var wordPopEnabled: Bool = ReaderSettings.Defaults.wordPopEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts the times Pop Words In turned on, so each one pops the word.
    @State private var popCount = 0

    var body: some View {
        WordView(
            word: "Strobe",
            fontSize: CGFloat(fontSize),
            context: contextWordsEnabled ? ContextWords.Neighbors(previous: "read", next: "faster") : nil,
            pop: WordPop.Cue(
                trigger: popCount,
                style: wordPopEnabled ? WordPop.style(reduceMotion: reduceMotion) : .still,
                duration: WordPop.duration(wordsPerMinute: defaultWPM)
            )
        )
        .onChange(of: wordPopEnabled) { _, isOn in
            if isOn { popCount += 1 }
        }
        .frame(maxWidth: .infinity)
        .background { ReaderBackdrop() }
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview")
        .accessibilityValue("Strobe, \(fontSize) points")
    }
}

/// Speed, size, font, colors, background, and how words come in.
struct ReadingAppearanceSection: View {
    @AppStorage(ReaderSettings.Keys.defaultWPM) private var defaultWPM: Int = ReaderSettings.Defaults.defaultWPM
    @AppStorage(ReaderSettings.Keys.fontSize) private var fontSize: Int = ReaderSettings.Defaults.fontSize
    @AppStorage(ReaderSettings.Keys.trueBlackBackgroundEnabled) private var trueBlackBackgroundEnabled: Bool = ReaderSettings.Defaults.trueBlackBackgroundEnabled
    @AppStorage(ReaderSettings.Keys.wordPopEnabled) private var wordPopEnabled: Bool = ReaderSettings.Defaults.wordPopEnabled
    @AppStorage(ReaderFont.storageKey) private var readerFontSelection = ReaderFont.defaultValue.rawValue
    @AppStorage(ReaderTextTone.storageKey) private var readerTextToneSelection = ReaderTextTone.defaultValue.rawValue
    @AppStorage(ReaderHighlightColor.storageKey) private var readerHighlightColorSelection = ReaderHighlightColor.defaultValue.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Section {
            SettingsSliderRow(
                "Default Speed",
                value: "\(defaultWPM) wpm",
                accessibilityValue: "\(defaultWPM) words per minute",
                sliderValue: sliderBinding($defaultWPM),
                in: ReaderSettings.wpmRange,
                step: ReaderSettings.wpmStep
            )

            SettingsSliderRow(
                "Text Size",
                value: "\(fontSize) pt",
                accessibilityValue: "\(fontSize) points",
                sliderValue: sliderBinding($fontSize),
                in: 24...72,
                step: 2
            )

            Picker("Font", selection: $readerFontSelection) {
                ForEach(ReaderFont.allCases) { font in
                    Text(font.displayName)
                        .font(font.regularFont(size: 17))
                        .tag(font.rawValue)
                }
            }
            #if os(iOS)
            .pickerStyle(.navigationLink)
            #endif

            ToneRow(
                selection: $readerTextToneSelection,
                font: ReaderFont.resolve(readerFontSelection),
                highlight: ReaderHighlightColor.resolve(readerHighlightColorSelection)
            )

            HighlightColorRow(
                selection: $readerHighlightColorSelection,
                font: ReaderFont.resolve(readerFontSelection),
                tone: ReaderTextTone.resolve(readerTextToneSelection)
            )

            Toggle(isOn: $trueBlackBackgroundEnabled) {
                Text("True Black Background")
                Text("Pure black behind the words, for reading in the dark")
            }

            // Reduce Motion holds it off without changing the stored choice,
            // which comes back when Reduce Motion is turned off.
            Toggle(isOn: Binding(
                get: { wordPopEnabled && !reduceMotion },
                set: { wordPopEnabled = $0 }
            )) {
                Text("Pop Words In")
                Text(reduceMotion
                     ? "Off because Reduce Motion is turned on in Accessibility settings"
                     : "Each word springs in as it appears, like video captions")
            }
            .disabled(reduceMotion)
        } header: {
            Text("Reading")
        } footer: {
            Text("Speed applies to documents you add from now on. Each document remembers its own speed.")
        }
    }
}

/// The text color choices, each drawn the way the reader draws a word: the
/// name in the tone's color on the reader background, with the anchor
/// letter in the chosen highlight color.
private struct ToneRow: View {
    @Binding var selection: String
    let font: ReaderFont
    let highlight: ReaderHighlightColor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Text Color")
            HStack(spacing: 8) {
                ForEach(ReaderTextTone.allCases) { tone in
                    ReaderSwatch(
                        sample: ReaderSwatch.makeSample(tone.displayName, font: font, tone: tone, highlight: highlight),
                        name: tone.displayName,
                        isSelected: selection == tone.rawValue
                    ) {
                        selection = tone.rawValue
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
}

/// The highlight color choices, each drawn on the current text color: the
/// name in the tone's color on the reader background, with the anchor
/// letter in that highlight color as tuned for the tone.
private struct HighlightColorRow: View {
    @Binding var selection: String
    let font: ReaderFont
    let tone: ReaderTextTone

    /// One column per text color swatch, so the two rows of swatches line up.
    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: ReaderTextTone.allCases.count
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Highlight Color")
            LazyVGrid(columns: Self.columns, spacing: 8) {
                ForEach(ReaderHighlightColor.allCases) { highlight in
                    ReaderSwatch(
                        sample: ReaderSwatch.makeSample(highlight.displayName, font: font, tone: tone, highlight: highlight),
                        name: highlight.displayName,
                        isSelected: selection == highlight.rawValue
                    ) {
                        selection = highlight.rawValue
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
}

/// A reader color choice: a sample word on the reader background, outlined
/// in the accent while selected.
private struct ReaderSwatch: View {
    let sample: AttributedString
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(sample)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 6)
                .padding(.vertical, 12)
                .background { ReaderBackdrop() }
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isSelected ? StrobeTheme.accent : Color.white.opacity(0.14),
                            lineWidth: isSelected ? 2 : 0.5
                        )
                }
                .contentShape(.rect(cornerRadius: 10))
        }
        // Each swatch keeps its own tap target inside the form row.
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// `text` the way the reader draws a word: in the tone's color, with the
    /// anchor letter bold in the highlight color.
    static func makeSample(
        _ text: String,
        font: ReaderFont,
        tone: ReaderTextTone,
        highlight: ReaderHighlightColor
    ) -> AttributedString {
        var sample = AttributedString(text)
        sample.font = font.regularFont(size: 15)
        sample.foregroundColor = tone.textColor

        let anchorOffset = WordView.orpLetterPosition(letterCount: text.count)
        let anchorStart = sample.index(sample.startIndex, offsetByCharacters: anchorOffset)
        let anchorEnd = sample.index(anchorStart, offsetByCharacters: 1)
        sample[anchorStart..<anchorEnd].foregroundColor = tone.anchorColor(for: highlight)
        sample[anchorStart..<anchorEnd].font = font.boldFont(size: 15)
        return sample
    }
}

// MARK: - Controls

/// How playback is started and how speed changes mid-read.
struct ReadingControlsSection: View {
    @AppStorage(ReaderSettings.Keys.holdToReadEnabled) private var holdToReadEnabled: Bool = ReaderSettings.Defaults.holdToReadEnabled
    @AppStorage(ReaderSettings.Keys.holdSpeedAdjustEnabled) private var holdSpeedAdjustEnabled: Bool = ReaderSettings.Defaults.holdSpeedAdjustEnabled

    var body: some View {
        Section {
            #if os(iOS)
            Toggle("Hold to Read", isOn: $holdToReadEnabled.animation())
            if holdToReadEnabled {
                Toggle("Drag to Change Speed", isOn: $holdSpeedAdjustEnabled)
            }
            #else
            Toggle("Drag to Change Speed", isOn: $holdSpeedAdjustEnabled)
            #endif
        } header: {
            Text("Controls")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        #if os(iOS)
        guard holdToReadEnabled else {
            return "Tap the screen to start reading and tap again to pause."
        }
        let hold = holdSpeedAdjustEnabled
            ? "Hold the screen to read and let go to pause. While holding, drag up or down to change speed."
            : "Hold the screen to read and let go to pause."
        return hold + " To read hands-free, tap with two fingers; reading goes on until you tap again."
        #else
        return "While reading, click and drag up or down to change speed."
        #endif
    }
}

// MARK: - While reading

/// Optional text shown around the word.
struct WhileReadingSections: View {
    @AppStorage(ReaderSettings.Keys.readingHeaderTitleEnabled) private var readingHeaderTitleEnabled: Bool = ReaderSettings.Defaults.readingHeaderTitleEnabled
    @AppStorage(ReaderSettings.Keys.readingHeaderChapterEnabled) private var readingHeaderChapterEnabled: Bool = ReaderSettings.Defaults.readingHeaderChapterEnabled
    @AppStorage(ReaderSettings.Keys.contextWordsEnabled) private var contextWordsEnabled: Bool = ReaderSettings.Defaults.contextWordsEnabled
    @AppStorage(ReaderSettings.Keys.enclosingMarksEnabled) private var enclosingMarksEnabled: Bool = ReaderSettings.Defaults.enclosingMarksEnabled
    @AppStorage(ReaderSettings.Keys.enclosingMarksSize) private var enclosingMarksSize: Double = ReaderSettings.Defaults.enclosingMarksSize
    @AppStorage(ReaderSettings.Keys.enclosingMarksOpacity) private var enclosingMarksOpacity: Double = ReaderSettings.Defaults.enclosingMarksOpacity
    @AppStorage(ReaderTextTone.storageKey) private var readerTextToneSelection = ReaderTextTone.defaultValue.rawValue

    private var enclosingMarksSizePercent: Int {
        Int((enclosingMarksSize * 100).rounded())
    }

    /// The marks' opacity in the current tone. The setting's default lands
    /// on each tone's own faded opacity, so the same level reads differently
    /// from tone to tone.
    private var enclosingMarksOpacityPercent: Int {
        let opacity = EnclosingMarksLayout.opacity(
            level: enclosingMarksOpacity,
            tone: ReaderTextTone.resolve(readerTextToneSelection)
        )
        return Int((opacity * 100).rounded())
    }

    var body: some View {
        Section {
            Toggle(isOn: $readingHeaderTitleEnabled) {
                Text("Document Title")
                Text("Faintly at the top while words play")
            }
            Toggle(isOn: $readingHeaderChapterEnabled) {
                Text("Current Chapter")
                Text("Faintly at the top while words play")
            }
        } header: {
            Text("Top of the Screen")
        }

        Section {
            Toggle(isOn: $contextWordsEnabled) {
                Text("Previous and Next Words")
                Text("Beside the word, readable only while paused")
            }
            Toggle(isOn: $enclosingMarksEnabled.animation()) {
                Text("Open Quotes and Parentheses")
                Text("Above the word until they close")
            }
            if enclosingMarksEnabled {
                EnclosingMarksPreview()
                SettingsSliderRow(
                    value: "\(enclosingMarksSizePercent)%",
                    accessibilityLabel: "Quote and parenthesis size",
                    accessibilityValue: "\(enclosingMarksSizePercent) percent",
                    sliderValue: $enclosingMarksSize,
                    in: EnclosingMarksLayout.sizeRange,
                    step: 0.1
                ) {
                    Text("Size")
                }
                SettingsSliderRow(
                    value: "\(enclosingMarksOpacityPercent)%",
                    accessibilityLabel: "Quote and parenthesis opacity",
                    accessibilityValue: "\(enclosingMarksOpacityPercent) percent",
                    sliderValue: $enclosingMarksOpacity,
                    in: 0...1,
                    step: 0.05
                ) {
                    Text("Opacity")
                }
            }
        } header: {
            Text("Around the Word")
        } footer: {
            if enclosingMarksEnabled {
                Text("Large marks shrink where there isn't room for them above the word.")
            }
        }
    }
}

// MARK: - Importing

struct ImportSettingsSection: View {
    @AppStorage(TextCleaningLevel.storageKey) private var textCleaningLevel = TextCleaningLevel.defaultValue.rawValue

    private var textCleaningEnabled: Binding<Bool> {
        Binding(
            get: { textCleaningLevel == TextCleaningLevel.standard.rawValue },
            set: { textCleaningLevel = $0 ? TextCleaningLevel.standard.rawValue : TextCleaningLevel.none.rawValue }
        )
    }

    var body: some View {
        Section {
            Toggle(isOn: textCleaningEnabled) {
                Text("Clean Up Text")
                Text("Removes page numbers, headers, footers, and common boilerplate")
            }
        } header: {
            Text("Importing")
        } footer: {
            Text("Applies to new imports. Documents already in your library don't change.")
        }
    }
}

// MARK: - About

struct AboutSection: View {
    @Binding var showWelcome: Bool
    @Binding var showWhatsNew: Bool
    #if os(macOS)
    @State private var showAcknowledgements = false
    #endif

    var body: some View {
        Section {
            Button("Show Welcome Screen") {
                showWelcome = true
            }
            .tint(.primary)
            if WhatsNew.runningRelease != nil {
                Button("What's New") {
                    showWhatsNew = true
                }
                .tint(.primary)
            }
            ExternalLinkRow(title: "Rate Strobe", url: Self.writeReviewURL)
            ExternalLinkRow(title: "Source Code", url: URL(string: "https://github.com/abdeen-labs/rapid-serial-visual-presentation")!)
            #if os(macOS)
            Button("Acknowledgements") {
                showAcknowledgements = true
            }
            .tint(.primary)
            .sheet(isPresented: $showAcknowledgements) {
                AcknowledgementsSheet()
            }
            #else
            NavigationLink("Acknowledgements") {
                AcknowledgementsView()
            }
            #endif
        } footer: {
            Text(appVersionLabel)
        }
    }

    /// Opens the App Store's review form for Strobe.
    private static let writeReviewURL: URL = {
        #if os(macOS)
        URL(string: "macappstore://apps.apple.com/app/id6759187873?action=write-review")!
        #else
        URL(string: "https://apps.apple.com/app/id6759187873?action=write-review")!
        #endif
    }()

    private var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "x.x"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "x"
        return "Strobe \(version) (\(build))"
    }
}

/// A settings row that opens a web page, marked with an arrow.
struct ExternalLinkRow: View {
    let title: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.primary)
    }
}
