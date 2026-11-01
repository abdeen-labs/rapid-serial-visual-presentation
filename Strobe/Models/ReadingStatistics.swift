import Foundation

/// Reading sessions added up over a period, for the Statistics sheet: time
/// and words read, per day or month and in all, averages, and speeds with
/// and without the voice.
///
/// A session counts toward the day it started, in the current calendar.
/// Speeds are words over time, so a long session weighs more than a short
/// one.
nonisolated struct ReadingStatistics {
    enum Period: String, CaseIterable, Identifiable, Sendable {
        /// The last 7 days, by day.
        case week
        /// The last 30 days, by day.
        case month
        /// The last 12 months, by month.
        case year
        /// Since the first session: by day within 30 days, by month within
        /// two years, and by year past that.
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .week: "Week"
            case .month: "Month"
            case .year: "Year"
            case .all: "All"
            }
        }

        /// What the period covers, as a sentence's end: "in the last 7 days".
        var phrase: String {
            switch self {
            case .week: "in the last 7 days"
            case .month: "in the last 30 days"
            case .year: "in the last 12 months"
            case .all: "so far"
            }
        }
    }

    /// One day's, month's, or year's reading.
    struct Bucket: Identifiable, Hashable, Sendable {
        let start: Date
        var plain = ReadingAmount()
        var voiced = ReadingAmount()

        var id: Date { start }
        var total: ReadingAmount { plain + voiced }
    }

    let period: Period
    /// The bucket size: `.day`, `.month`, or `.year`.
    let unit: Calendar.Component
    /// Every day, month, or year of the period, oldest first, empty ones
    /// included.
    let buckets: [Bucket]
    let plain: ReadingAmount
    let voiced: ReadingAmount
    let sessionCount: Int
    /// The days the period covers, today included.
    let dayCount: Int

    var total: ReadingAmount { plain + voiced }

    var isEmpty: Bool { sessionCount == 0 }

    /// Time and words per day over the period's days, read or not.
    var dailyAverage: ReadingAmount {
        let days = Double(max(1, dayCount))
        return ReadingAmount(words: Int((Double(total.words) / days).rounded()), seconds: total.seconds / days)
    }

    /// The average session's reading time, or nil without sessions.
    var averageSessionSeconds: TimeInterval? {
        sessionCount > 0 ? total.seconds / Double(sessionCount) : nil
    }

    init(
        sessions: [ReadingSessionSnapshot],
        period: Period,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        self.period = period
        let today = calendar.startOfDay(for: now)
        let earliest = sessions.map(\.startedAt).min().map { min(calendar.startOfDay(for: $0), today) } ?? today

        let unit: Calendar.Component
        let firstBucket: Date
        switch period {
        case .week:
            unit = .day
            firstBucket = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month:
            unit = .day
            firstBucket = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .year:
            unit = .month
            let thisMonth = Self.start(of: .month, for: today, calendar: calendar)
            firstBucket = calendar.date(byAdding: .month, value: -11, to: thisMonth) ?? thisMonth
        case .all:
            let days = calendar.dateComponents([.day], from: earliest, to: today).day ?? 0
            let months = calendar.dateComponents([.month], from: earliest, to: today).month ?? 0
            unit = days < 30 ? .day : months < 24 ? .month : .year
            firstBucket = Self.start(of: unit, for: earliest, calendar: calendar)
        }
        self.unit = unit

        // The period's own start: a year's bucket starts on the 1st of its
        // month, but all time starts on the first day read.
        let periodStart = period == .all ? earliest : firstBucket
        dayCount = (calendar.dateComponents([.day], from: periodStart, to: today).day ?? 0) + 1

        var buckets: [Bucket] = []
        var bucketStart = firstBucket
        while bucketStart <= today {
            buckets.append(Bucket(start: bucketStart))
            guard let next = calendar.date(byAdding: unit, value: 1, to: bucketStart), next > bucketStart else { break }
            bucketStart = next
        }

        var plain = ReadingAmount()
        var voiced = ReadingAmount()
        var sessionCount = 0
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        for session in sessions where session.startedAt >= periodStart && session.startedAt < end {
            let bucketStart = Self.start(of: unit, for: session.startedAt, calendar: calendar)
            if let index = buckets.firstIndex(where: { $0.start == bucketStart }) {
                buckets[index].plain += session.plain
                buckets[index].voiced += session.voiced
            }
            plain += session.plain
            voiced += session.voiced
            sessionCount += 1
        }
        self.buckets = buckets
        self.plain = plain
        self.voiced = voiced
        self.sessionCount = sessionCount
    }

    private static func start(of unit: Calendar.Component, for date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: unit, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}
