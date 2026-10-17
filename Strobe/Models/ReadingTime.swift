import Foundation

/// Reading-time estimates at a words-per-minute rate.
///
/// A pace factor stretches the plain rate to the time smart timing, pauses,
/// complexity, and the rest give individual words. The app works out a
/// library document's factor (`ReadingPace`); estimates made before import,
/// from an approximate word count, stay plain.
nonisolated enum ReadingTime {
    /// Whole minutes to read `words` words, rounded up so any remaining
    /// text counts as at least a minute. `paceFactor` multiplies the plain
    /// time; 1 leaves it plain.
    static func minutes(words: Int, wordsPerMinute: Int, paceFactor: Double = 1) -> Int {
        guard words > 0, wordsPerMinute > 0 else { return 0 }
        guard paceFactor != 1, paceFactor.isFinite, paceFactor > 0 else {
            return (words + wordsPerMinute - 1) / wordsPerMinute
        }
        return Int((Double(words) * paceFactor / Double(wordsPerMinute)).rounded(.up))
    }

    /// A duration such as "7 hr 38 min" or "12 min".
    static func label(minutes: Int, locale: Locale = .autoupdatingCurrent) -> String {
        format(minutes: minutes, width: .abbreviated, locale: locale)
    }

    /// The same duration spelled out for VoiceOver: "7 hours 38 minutes".
    static func spokenLabel(minutes: Int, locale: Locale = .autoupdatingCurrent) -> String {
        format(minutes: minutes, width: .wide, locale: locale)
    }

    private static func format(
        minutes: Int,
        width: Measurement<UnitDuration>.FormatStyle.UnitWidth,
        locale: Locale
    ) -> String {
        let total = max(1, minutes)
        let hours = total / 60
        let remainder = total % 60
        let style = Measurement<UnitDuration>.FormatStyle(width: width, locale: locale, usage: .asProvided)
        var parts: [String] = []
        if hours > 0 {
            parts.append(style.format(Measurement(value: Double(hours), unit: .hours)))
        }
        if remainder > 0 || hours == 0 {
            parts.append(style.format(Measurement(value: Double(remainder), unit: .minutes)))
        }
        return parts.joined(separator: " ")
    }
}
