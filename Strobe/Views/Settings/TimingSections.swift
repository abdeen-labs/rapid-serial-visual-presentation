import SwiftUI

/// Per-word timing: smart timing by length, punctuation pauses, the blank
/// after sentences, and complexity timing. Each feature's fine-tuning shows
/// only while it's on.
struct TimingSections: View {
    @AppStorage(ReaderSettings.Keys.smartTimingEnabled) private var smartTimingEnabled: Bool = ReaderSettings.Defaults.smartTimingEnabled
    @AppStorage(ReaderSettings.Keys.smartTimingPercentPerLetter) private var smartTimingPercentPerLetter: Double = ReaderSettings.Defaults.smartTimingPercentPerLetter
    @AppStorage(ReaderSettings.Keys.smartTimingMinimumWordLength) private var smartTimingMinimumWordLength: Int = ReaderSettings.Defaults.smartTimingMinimumWordLength
    @AppStorage(ReaderSettings.Keys.sentencePauseEnabled) private var sentencePauseEnabled: Bool = ReaderSettings.Defaults.sentencePauseEnabled
    @AppStorage(ReaderSettings.Keys.sentencePauseMultiplier) private var sentencePauseMultiplier: Double = ReaderSettings.Defaults.sentencePauseMultiplier
    @AppStorage(ReaderSettings.Keys.clausePauseMultiplier) private var clausePauseMultiplier: Double = ReaderSettings.Defaults.clausePauseMultiplier
    @AppStorage(ReaderSettings.Keys.dashPauseMultiplier) private var dashPauseMultiplier: Double = ReaderSettings.Defaults.dashPauseMultiplier
    @AppStorage(ReaderSettings.Keys.ellipsisPauseMultiplier) private var ellipsisPauseMultiplier: Double = ReaderSettings.Defaults.ellipsisPauseMultiplier
    @AppStorage(ReaderSettings.Keys.bracketPauseMultiplier) private var bracketPauseMultiplier: Double = ReaderSettings.Defaults.bracketPauseMultiplier
    @AppStorage(ReaderSettings.Keys.sentenceBreakEnabled) private var sentenceBreakEnabled: Bool = ReaderSettings.Defaults.sentenceBreakEnabled
    @AppStorage(ReaderSettings.Keys.sentenceBreakLength) private var sentenceBreakLength: Double = ReaderSettings.Defaults.sentenceBreakLength
    @AppStorage(ReaderSettings.Keys.complexityTimingEnabled) private var complexityTimingEnabled: Bool = ReaderSettings.Defaults.complexityTimingEnabled
    @AppStorage(ReaderSettings.Keys.complexitySpeedUpIntensity) private var complexitySpeedUpIntensity: Double = ReaderSettings.Defaults.complexitySpeedUpIntensity
    @AppStorage(ReaderSettings.Keys.complexitySlowDownIntensity) private var complexitySlowDownIntensity: Double = ReaderSettings.Defaults.complexitySlowDownIntensity

    /// The punctuation types with their own pause multiplier.
    private enum PauseType: CaseIterable, Identifiable {
        case sentenceEnd, clause, dash, ellipsis, bracket

        var id: Self { self }

        var title: String {
            switch self {
            case .sentenceEnd: "Sentence End"
            case .clause: "Commas, Colons, Semicolons"
            case .dash: "Dashes"
            case .ellipsis: "Ellipses"
            case .bracket: "Closing Brackets and Quotes"
            }
        }

        /// The marks the pause applies to.
        var sample: String {
            switch self {
            case .sentenceEnd: ". ! ?"
            case .clause: ", ; :"
            case .dash: "\u{2014}"
            case .ellipsis: "\u{2026}"
            case .bracket: ") \u{201D}"
            }
        }
    }

    private func multiplier(for type: PauseType) -> Binding<Double> {
        switch type {
        case .sentenceEnd: $sentencePauseMultiplier
        case .clause: $clausePauseMultiplier
        case .dash: $dashPauseMultiplier
        case .ellipsis: $ellipsisPauseMultiplier
        case .bracket: $bracketPauseMultiplier
        }
    }

    /// A multiplier of 1.0 adds no pause, so it reads as "Off" rather than "1.0×".
    private func multiplierLabel(_ multiplier: Double) -> String {
        multiplier < 1.05 ? "Off" : String(format: "%.1f\u{00D7}", multiplier)
    }

    /// At the minimum (1) smart timing applies to every word.
    private var minimumWordLengthLabel: String {
        smartTimingMinimumWordLength <= 1 ? "All words" : "\(smartTimingMinimumWordLength)+ letters"
    }

    /// The blank's length counted in words at the reader's speed.
    private var sentenceBreakLengthLabel: String {
        sentenceBreakLength == 1 ? "1 word" : String(format: "%g words", sentenceBreakLength)
    }

    private var minimumWordLength: Binding<Double> {
        Binding(
            get: { Double(smartTimingMinimumWordLength) },
            set: { smartTimingMinimumWordLength = Int($0.rounded()) }
        )
    }

    var body: some View {
        Section {
            Toggle(isOn: $smartTimingEnabled.animation()) {
                Text("Smart Timing")
                Text("Longer words stay on screen longer")
            }
            if smartTimingEnabled {
                SettingsSliderRow(
                    "Slowdown per Letter",
                    value: "\(Int(smartTimingPercentPerLetter.rounded()))%",
                    accessibilityValue: "\(Int(smartTimingPercentPerLetter.rounded())) percent",
                    sliderValue: $smartTimingPercentPerLetter,
                    in: 0...50,
                    step: 1
                )
                SettingsSliderRow(
                    "Minimum Word Length",
                    value: minimumWordLengthLabel,
                    accessibilityValue: smartTimingMinimumWordLength <= 1
                        ? "All words"
                        : "\(smartTimingMinimumWordLength) or more letters",
                    sliderValue: minimumWordLength,
                    in: 1...15,
                    step: 1
                )
            }
        } footer: {
            if smartTimingEnabled {
                Text("Words shorter than the minimum get no extra time.")
            }
        }

        Section {
            Toggle(isOn: $sentencePauseEnabled.animation()) {
                Text("Punctuation Pauses")
                Text("A brief pause after punctuation marks")
            }
            if sentencePauseEnabled {
                ForEach(PauseType.allCases) { type in
                    let binding = multiplier(for: type)
                    SettingsSliderRow(
                        value: multiplierLabel(binding.wrappedValue),
                        accessibilityLabel: "\(type.title) pause",
                        sliderValue: binding,
                        in: 1...4,
                        step: 0.1
                    ) {
                        HStack(spacing: 8) {
                            Text(type.title)
                            Text(type.sample)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        } footer: {
            if sentencePauseEnabled {
                Text("A word with several marks pauses once, for the longest.")
            }
        }

        Section {
            Toggle(isOn: $sentenceBreakEnabled.animation()) {
                Text("Blank After Sentences")
                Text("An empty screen for a moment after each sentence")
            }
            if sentenceBreakEnabled {
                SettingsSliderRow(
                    "Blank For",
                    value: sentenceBreakLengthLabel,
                    sliderValue: $sentenceBreakLength,
                    in: 0.5...4,
                    step: 0.5
                )
            }
        } footer: {
            if sentenceBreakEnabled {
                Text("Measured in words.")
            }
        }

        Section {
            Toggle(isOn: $complexityTimingEnabled.animation()) {
                Text("Complexity Timing")
                Text("Adapts speed to how hard each word is")
            }
            if complexityTimingEnabled {
                SettingsSliderRow(
                    "Simple Words",
                    value: "\(Int((complexitySpeedUpIntensity * 100).rounded()))%",
                    accessibilityValue: "\(Int((complexitySpeedUpIntensity * 100).rounded())) percent",
                    sliderValue: $complexitySpeedUpIntensity,
                    in: 0...1,
                    step: 0.05
                )
                SettingsSliderRow(
                    "Complex Words",
                    value: "\(Int((complexitySlowDownIntensity * 100).rounded()))%",
                    accessibilityValue: "\(Int((complexitySlowDownIntensity * 100).rounded())) percent",
                    sliderValue: $complexitySlowDownIntensity,
                    in: 0...1,
                    step: 0.05
                )
            }
        } footer: {
            if complexityTimingEnabled {
                Text("Speeds up simple, common words and slows down complex, rare ones. Higher means a bigger change.")
            }
        }
    }
}
