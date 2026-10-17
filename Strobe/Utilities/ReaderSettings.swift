import Foundation

/// Single source of truth for the reader's UserDefaults-backed settings:
/// key strings, default values, and a snapshot helper for contexts where
/// `@AppStorage` isn't available (e.g. `View` initializers).
///
/// Every `@AppStorage` declaration for these settings must reference
/// ``Keys`` and ``Defaults`` so a key or default can never drift between
/// the settings UI, the reader, and the engine bootstrap.
enum ReaderSettings {

    enum Keys {
        nonisolated static let defaultWPM = "defaultWPM"
        nonisolated static let fontSize = "fontSize"
        nonisolated static let smartTimingEnabled = "smartTimingEnabled"
        nonisolated static let sentencePauseEnabled = "sentencePauseEnabled"
        nonisolated static let smartTimingPercentPerLetter = "smartTimingPercentPerLetter"
        nonisolated static let smartTimingMinimumWordLength = "smartTimingMinimumWordLength"
        nonisolated static let sentencePauseMultiplier = "sentencePauseMultiplier"
        nonisolated static let complexityTimingEnabled = "complexityTimingEnabled"
        nonisolated static let complexityIntensity = "complexityIntensity"
        nonisolated static let clausePauseMultiplier = "clausePauseMultiplier"
        nonisolated static let dashPauseMultiplier = "dashPauseMultiplier"
        nonisolated static let ellipsisPauseMultiplier = "ellipsisPauseMultiplier"
        nonisolated static let bracketPauseMultiplier = "bracketPauseMultiplier"
        nonisolated static let holdToReadEnabled = "holdToReadEnabled"
        nonisolated static let holdSpeedAdjustEnabled = "holdSpeedAdjustEnabled"
        nonisolated static let trueBlackBackgroundEnabled = "trueBlackBackgroundEnabled"
        nonisolated static let readingHeaderTitleEnabled = "readingHeaderTitleEnabled"
        nonisolated static let readingHeaderChapterEnabled = "readingHeaderChapterEnabled"
        nonisolated static let sentenceBreakEnabled = "sentenceBreakEnabled"
        nonisolated static let sentenceBreakLength = "sentenceBreakLength"
        nonisolated static let contextWordsEnabled = "contextWordsEnabled"
        nonisolated static let enclosingMarksEnabled = "enclosingMarksEnabled"
        nonisolated static let enclosingMarksSize = "enclosingMarksSize"
        nonisolated static let enclosingMarksOpacity = "enclosingMarksOpacity"
        nonisolated static let iCloudSyncEnabled = "iCloudSyncEnabled"

        // App-level flags (not reader settings, but registered here so key
        // strings never drift between files).
        nonisolated static let hasSeenTutorial = "hasSeenTutorial"
        nonisolated static let didCompactLegacyWordStorage = "didCompactLegacyWordStorage"
        /// Set when sync turned itself off because Strobe's iCloud data was deleted.
        nonisolated static let iCloudSyncStoppedAfterDeletion = "iCloudSyncStoppedAfterDeletion"
    }

    enum Defaults {
        nonisolated static let defaultWPM = 300
        nonisolated static let fontSize = 40
        nonisolated static let smartTimingEnabled = false
        nonisolated static let sentencePauseEnabled = false
        nonisolated static let smartTimingPercentPerLetter = 4.0
        nonisolated static let smartTimingMinimumWordLength = 1
        nonisolated static let sentencePauseMultiplier = 1.5
        nonisolated static let complexityTimingEnabled = false
        nonisolated static let complexityIntensity = 0.5
        nonisolated static let clausePauseMultiplier = 1.3
        nonisolated static let dashPauseMultiplier = 1.4
        nonisolated static let ellipsisPauseMultiplier = 1.5
        nonisolated static let bracketPauseMultiplier = 1.2
        nonisolated static let holdToReadEnabled = true
        nonisolated static let holdSpeedAdjustEnabled = true
        nonisolated static let trueBlackBackgroundEnabled = true
        nonisolated static let readingHeaderTitleEnabled = false
        nonisolated static let readingHeaderChapterEnabled = false
        nonisolated static let sentenceBreakEnabled = false
        nonisolated static let sentenceBreakLength = 1.0
        nonisolated static let contextWordsEnabled = false
        nonisolated static let enclosingMarksEnabled = false
        /// A multiple of the marks' standard size; see `EnclosingMarksLayout.sizeRange`.
        nonisolated static let enclosingMarksSize = 1.0
        /// A level from 0 to 1. This one is the tone's faded text; see
        /// `EnclosingMarksLayout.opacity(level:tone:)`.
        nonisolated static let enclosingMarksOpacity = 0.5
        nonisolated static let iCloudSyncEnabled = true
    }

    /// Shared words-per-minute domain: the reader slider, the settings slider,
    /// and the hold-to-read speed mapping all read these so the range and step
    /// can never drift between call sites.
    nonisolated static let wpmRange: ClosedRange<Double> = 100...1000
    nonisolated static let wpmStep: Double = 10

    /// The engine-relevant timing settings, read directly from UserDefaults.
    struct TimingSnapshot {
        let smartTimingEnabled: Bool
        let sentencePauseEnabled: Bool
        let smartTimingPercentPerLetter: Double
        let smartTimingMinimumWordLength: Int
        let sentencePauseMultiplier: Double
        let complexityTimingEnabled: Bool
        let complexityIntensity: Double
        let punctuationPauses: PunctuationPauses
        let sentenceBreakEnabled: Bool
        let sentenceBreakLength: Double
    }

    /// Reads the current timing settings for constructing an ``RSVPEngine``.
    nonisolated static func timingSnapshot(from defaults: UserDefaults = .standard) -> TimingSnapshot {
        TimingSnapshot(
            smartTimingEnabled: defaults.object(forKey: Keys.smartTimingEnabled) as? Bool
                ?? Defaults.smartTimingEnabled,
            sentencePauseEnabled: defaults.object(forKey: Keys.sentencePauseEnabled) as? Bool
                ?? Defaults.sentencePauseEnabled,
            smartTimingPercentPerLetter: defaults.object(forKey: Keys.smartTimingPercentPerLetter) as? Double
                ?? Defaults.smartTimingPercentPerLetter,
            smartTimingMinimumWordLength: defaults.object(forKey: Keys.smartTimingMinimumWordLength) as? Int
                ?? Defaults.smartTimingMinimumWordLength,
            sentencePauseMultiplier: defaults.object(forKey: Keys.sentencePauseMultiplier) as? Double
                ?? Defaults.sentencePauseMultiplier,
            complexityTimingEnabled: defaults.object(forKey: Keys.complexityTimingEnabled) as? Bool
                ?? Defaults.complexityTimingEnabled,
            complexityIntensity: defaults.object(forKey: Keys.complexityIntensity) as? Double
                ?? Defaults.complexityIntensity,
            punctuationPauses: PunctuationPauses(
                clause: defaults.object(forKey: Keys.clausePauseMultiplier) as? Double
                    ?? Defaults.clausePauseMultiplier,
                dash: defaults.object(forKey: Keys.dashPauseMultiplier) as? Double
                    ?? Defaults.dashPauseMultiplier,
                ellipsis: defaults.object(forKey: Keys.ellipsisPauseMultiplier) as? Double
                    ?? Defaults.ellipsisPauseMultiplier,
                bracket: defaults.object(forKey: Keys.bracketPauseMultiplier) as? Double
                    ?? Defaults.bracketPauseMultiplier
            ),
            sentenceBreakEnabled: defaults.object(forKey: Keys.sentenceBreakEnabled) as? Bool
                ?? Defaults.sentenceBreakEnabled,
            sentenceBreakLength: defaults.object(forKey: Keys.sentenceBreakLength) as? Double
                ?? Defaults.sentenceBreakLength
        )
    }
}
