import Foundation
import SwiftData
import Testing
@testable import Strobe

struct ReadingStatisticsTests {

    private static let documentID = UUID()
    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    // MARK: - Tracking sessions

    @Test func playingAndPausingAddUpOneSession() throws {
        var tracker = ReadingSessionTracker(documentID: Self.documentID)
        let endedOnStart = tracker.play(at: Self.at(0), playedWords: 0, isVoiced: false)
        #expect(endedOnStart == nil)
        tracker.pause(at: Self.at(60), playedWords: 300)
        let endedOnResume = tracker.play(at: Self.at(90), playedWords: 300, isVoiced: false)
        #expect(endedOnResume == nil)
        tracker.pause(at: Self.at(120), playedWords: 450)

        let sessionResult = tracker.finish(at: Self.at(200), playedWords: 450)
        let session = try #require(sessionResult)
        #expect(session.documentID == Self.documentID)
        #expect(session.startedAt == Self.at(0))
        // Ends when reading last stopped, not when the reader closed.
        #expect(session.endedAt == Self.at(120))
        // The pause between isn't reading.
        #expect(session.plain == ReadingAmount(words: 450, seconds: 90))
        #expect(session.voiced == ReadingAmount())
        #expect(session.total.wordsPerMinute == 300)
    }

    @Test func eachStretchCountsWithTheVoiceOrWithout() throws {
        var tracker = ReadingSessionTracker(documentID: Self.documentID)
        _ = tracker.play(at: Self.at(0), playedWords: 0, isVoiced: false)
        tracker.pause(at: Self.at(60), playedWords: 400)
        _ = tracker.play(at: Self.at(70), playedWords: 400, isVoiced: true)
        tracker.pause(at: Self.at(130), playedWords: 600)

        let sessionResult = tracker.finish(at: Self.at(130), playedWords: 600)
        let session = try #require(sessionResult)
        #expect(session.plain == ReadingAmount(words: 400, seconds: 60))
        #expect(session.voiced == ReadingAmount(words: 200, seconds: 60))
        #expect(session.voiced.wordsPerMinute == 200)
    }

    @Test func aLongPauseStartsAnotherSession() throws {
        var tracker = ReadingSessionTracker(documentID: Self.documentID)
        _ = tracker.play(at: Self.at(0), playedWords: 0, isVoiced: false)
        tracker.pause(at: Self.at(60), playedWords: 300)

        // Just within the pause allowed: the same session.
        let gap = ReadingSessionTracker.maximumPause
        let endedWithinThePause = tracker.play(at: Self.at(60 + gap), playedWords: 300, isVoiced: false)
        #expect(endedWithinThePause == nil)
        tracker.pause(at: Self.at(120 + gap), playedWords: 600)

        // Past it: the first session ends, and the next play starts another.
        let resumed = Self.at(120 + gap * 2 + 1)
        let firstResult = tracker.play(at: resumed, playedWords: 600, isVoiced: false)
        let first = try #require(firstResult)
        #expect(first.total == ReadingAmount(words: 600, seconds: 120))
        tracker.pause(at: resumed.addingTimeInterval(30), playedWords: 700)

        let secondResult = tracker.finish(at: resumed.addingTimeInterval(30), playedWords: 700)
        let second = try #require(secondResult)
        #expect(second.id != first.id)
        #expect(second.startedAt == resumed)
        #expect(second.total == ReadingAmount(words: 100, seconds: 30))
    }

    @Test func aFewWordsAreNotASession() {
        var tracker = ReadingSessionTracker(documentID: Self.documentID)
        _ = tracker.play(at: Self.at(0), playedWords: 0, isVoiced: false)
        tracker.pause(at: Self.at(2), playedWords: ReadingSessionTracker.minimumWords - 1)
        #expect(tracker.current(at: Self.at(2), playedWords: ReadingSessionTracker.minimumWords - 1) == nil)
        let finished = tracker.finish(at: Self.at(3), playedWords: ReadingSessionTracker.minimumWords - 1)
        #expect(finished == nil)

        // A long pause after so little drops it without a session.
        _ = tracker.play(at: Self.at(10), playedWords: 0, isVoiced: false)
        tracker.pause(at: Self.at(11), playedWords: 3)
        let endedByThePause = tracker.play(at: Self.at(1000), playedWords: 3, isVoiced: false)
        #expect(endedByThePause == nil)
    }

    /// The session so far includes the stretch still playing, without
    /// ending it.
    @Test func currentSessionCountsTheStretchPlaying() throws {
        var tracker = ReadingSessionTracker(documentID: Self.documentID)
        _ = tracker.play(at: Self.at(0), playedWords: 0, isVoiced: true)
        let partway = try #require(tracker.current(at: Self.at(30), playedWords: 100))
        #expect(partway.voiced == ReadingAmount(words: 100, seconds: 30))
        #expect(partway.endedAt == Self.at(30))
        #expect(tracker.isPlaying)

        let finishedResult = tracker.finish(at: Self.at(60), playedWords: 200)
        let finished = try #require(finishedResult)
        #expect(finished.id == partway.id)
        #expect(finished.voiced == ReadingAmount(words: 200, seconds: 60))
        #expect(!tracker.isPlaying)
    }

    /// A stretch that took far longer than its words could, as when a Mac
    /// slept while playing, counts at the slowest honest rate.
    @Test func aStretchThatHungCountsAtTheSlowestRate() throws {
        var tracker = ReadingSessionTracker(documentID: Self.documentID)
        _ = tracker.play(at: Self.at(0), playedWords: 0, isVoiced: false)
        tracker.pause(at: Self.at(8 * 3600), playedWords: 20)
        let sessionResult = tracker.finish(at: Self.at(8 * 3600), playedWords: 20)
        let session = try #require(sessionResult)
        let limit = 20 * ReadingSessionTracker.maximumSecondsPerWord + ReadingSessionTracker.stretchAllowance
        #expect(session.plain.seconds == limit)
    }

    @Test func pausingWithoutPlayingAndPlayingTwiceChangeNothing() throws {
        var tracker = ReadingSessionTracker(documentID: nil)
        tracker.pause(at: Self.at(0), playedWords: 0)
        _ = tracker.play(at: Self.at(0), playedWords: 0, isVoiced: false)
        _ = tracker.play(at: Self.at(30), playedWords: 50, isVoiced: true)
        tracker.pause(at: Self.at(60), playedWords: 100)
        let sessionResult = tracker.finish(at: Self.at(60), playedWords: 100)
        let session = try #require(sessionResult)
        #expect(session.plain == ReadingAmount(words: 100, seconds: 60))
        #expect(session.voiced == ReadingAmount())
    }

    // MARK: - Adding up

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Noon on the given day of 2026, UTC.
    private static func day(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private static func session(
        _ date: Date,
        plain: ReadingAmount = ReadingAmount(),
        voiced: ReadingAmount = ReadingAmount()
    ) -> ReadingSessionSnapshot {
        ReadingSessionSnapshot(
            id: UUID(),
            documentID: nil,
            startedAt: date,
            endedAt: date.addingTimeInterval(plain.seconds + voiced.seconds),
            plain: plain,
            voiced: voiced
        )
    }

    @Test func aWeekHasSevenDaysEndingToday() throws {
        let now = Self.day(10, 31, hour: 20)
        let sessions = [
            Self.session(Self.day(10, 31), plain: ReadingAmount(words: 3000, seconds: 600)),
            Self.session(Self.day(10, 31, hour: 8), voiced: ReadingAmount(words: 1000, seconds: 300)),
            Self.session(Self.day(10, 25, hour: 0), plain: ReadingAmount(words: 600, seconds: 120)),
            // A day too early.
            Self.session(Self.day(10, 24, hour: 23), plain: ReadingAmount(words: 999, seconds: 99)),
        ]
        let week = ReadingStatistics(sessions: sessions, period: .week, now: now, calendar: Self.calendar)

        #expect(week.unit == .day)
        #expect(week.buckets.count == 7)
        #expect(week.buckets.first?.start == Self.calendar.startOfDay(for: Self.day(10, 25)))
        #expect(week.buckets.last?.start == Self.calendar.startOfDay(for: now))
        #expect(week.sessionCount == 3)
        #expect(week.plain == ReadingAmount(words: 3600, seconds: 720))
        #expect(week.voiced == ReadingAmount(words: 1000, seconds: 300))
        #expect(week.buckets.last?.total == ReadingAmount(words: 4000, seconds: 900))
        #expect(week.buckets.first?.total == ReadingAmount(words: 600, seconds: 120))
        #expect(week.dayCount == 7)
        #expect(week.dailyAverage.seconds == 1020.0 / 7)
        #expect(week.dailyAverage.words == 657)
        #expect(week.averageSessionSeconds == 340)
        #expect(week.plain.wordsPerMinute == 300)
        #expect(week.voiced.wordsPerMinute == 200)
    }

    @Test func aYearHasTwelveMonths() {
        let now = Self.day(10, 31)
        let sessions = [
            Self.session(Self.day(1, 3), plain: ReadingAmount(words: 100, seconds: 60)),
            Self.session(Self.day(10, 1), plain: ReadingAmount(words: 200, seconds: 60)),
            Self.session(Self.day(10, 30), plain: ReadingAmount(words: 300, seconds: 60)),
        ]
        let year = ReadingStatistics(sessions: sessions, period: .year, now: now, calendar: Self.calendar)
        #expect(year.unit == .month)
        #expect(year.buckets.count == 12)
        #expect(year.buckets.first?.start == Self.calendar.date(from: DateComponents(year: 2025, month: 11, day: 1)))
        #expect(year.buckets.last?.total == ReadingAmount(words: 500, seconds: 120))
        #expect(year.sessionCount == 3)
        // From November 1, 2025 through today.
        #expect(year.dayCount == 365)
    }

    @Test func allTimeStartsWithTheFirstSessionAndGrowsItsBuckets() {
        let now = Self.day(10, 31)
        let recent = ReadingStatistics(
            sessions: [Self.session(Self.day(10, 29), plain: ReadingAmount(words: 100, seconds: 60))],
            period: .all, now: now, calendar: Self.calendar
        )
        #expect(recent.unit == .day)
        #expect(recent.buckets.count == 3)
        #expect(recent.dayCount == 3)

        let months = ReadingStatistics(
            sessions: [Self.session(Self.day(3, 15), plain: ReadingAmount(words: 100, seconds: 60))],
            period: .all, now: now, calendar: Self.calendar
        )
        #expect(months.unit == .month)
        #expect(months.buckets.count == 8)

        let old = Self.calendar.date(from: DateComponents(year: 2022, month: 6, day: 1, hour: 12))!
        let years = ReadingStatistics(
            sessions: [Self.session(old, plain: ReadingAmount(words: 100, seconds: 60))],
            period: .all, now: now, calendar: Self.calendar
        )
        #expect(years.unit == .year)
        #expect(years.buckets.count == 5)
        #expect(years.sessionCount == 1)
    }

    @Test func nothingReadIsEmptyWithoutAverages() {
        let stats = ReadingStatistics(sessions: [], period: .month, now: Self.day(10, 31), calendar: Self.calendar)
        #expect(stats.isEmpty)
        #expect(stats.buckets.count == 30)
        #expect(stats.averageSessionSeconds == nil)
        #expect(stats.total.wordsPerMinute == nil)
        #expect(stats.dailyAverage == ReadingAmount())

        let allTime = ReadingStatistics(sessions: [], period: .all, now: Self.day(10, 31), calendar: Self.calendar)
        #expect(allTime.buckets.count == 1)
        #expect(allTime.dayCount == 1)
    }

    /// Speeds are words over time, so a long session weighs more than a
    /// short one.
    @Test func speedsWeighSessionsByTheirTime() {
        let sessions = [
            Self.session(Self.day(10, 30), plain: ReadingAmount(words: 6000, seconds: 1200)),
            Self.session(Self.day(10, 31), plain: ReadingAmount(words: 100, seconds: 60)),
        ]
        let stats = ReadingStatistics(sessions: sessions, period: .week, now: Self.day(10, 31), calendar: Self.calendar)
        #expect(abs((stats.plain.wordsPerMinute ?? 0) - 6100.0 / 21) < 1e-9)
    }
}

/// The reader's recorder against a store of its own.
@MainActor
struct ReadingSessionStoreTests {

    private static func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ReadingSession.self, configurations: configuration)
        return ModelContext(container)
    }

    private static func sessions(in context: ModelContext) throws -> [ReadingSession] {
        try context.fetch(FetchDescriptor<ReadingSession>())
    }

    @Test func aSessionIsStoredOnceItCountsAndFinishedWhenTheReaderCloses() throws {
        let context = try Self.makeContext()
        let documentID = UUID()
        let recorder = ReadingSessionRecorder(documentID: documentID)
        recorder.playbackChanged(isPlaying: true, playedWords: 0, isVoiced: false, in: context)

        // Too few words to count: nothing stored yet.
        recorder.save(isPlaying: true, playedWords: ReadingSessionTracker.minimumWords - 1, in: context)
        #expect(try Self.sessions(in: context).isEmpty)

        // Saved while playing on: stored, and updated rather than repeated.
        recorder.save(isPlaying: true, playedWords: 40, in: context)
        recorder.save(isPlaying: true, playedWords: 50, in: context)
        let stored = try #require(try Self.sessions(in: context).first)
        #expect(try Self.sessions(in: context).count == 1)
        #expect(stored.documentID == documentID)
        #expect(stored.plainWords == 50)
        #expect(!stored.isFinished)

        // A save that pauses counts the pause.
        recorder.save(isPlaying: false, playedWords: 60, in: context)
        recorder.finish(playedWords: 60, in: context)
        #expect(try Self.sessions(in: context).count == 1)
        #expect(stored.plainWords == 60)
        #expect(stored.isFinished)
        #expect(stored.voicedWords == 0)
    }

    @Test func aSessionTooShortIsNeverStored() throws {
        let context = try Self.makeContext()
        let recorder = ReadingSessionRecorder(documentID: UUID())
        recorder.playbackChanged(isPlaying: true, playedWords: 0, isVoiced: true, in: context)
        recorder.playbackChanged(isPlaying: false, playedWords: 3, isVoiced: true, in: context)
        recorder.finish(playedWords: 3, in: context)
        #expect(try Self.sessions(in: context).isEmpty)
    }

    /// No reader is open at launch, so a session left unfinished was
    /// abandoned when the app last closed.
    @Test func launchFinishesAbandonedSessions() throws {
        let context = try Self.makeContext()
        #expect(!ReadingSession.finishAbandoned(in: context))
        let snapshot = ReadingSessionSnapshot(
            id: UUID(), documentID: nil, startedAt: .now, endedAt: .now,
            plain: ReadingAmount(words: 100, seconds: 20)
        )
        context.insert(ReadingSession(snapshot, isFinished: false))
        #expect(ReadingSession.finishAbandoned(in: context))
        #expect(try Self.sessions(in: context).allSatisfy(\.isFinished))
        #expect(!ReadingSession.finishAbandoned(in: context))
    }

    @Test func storedSessionsKeepEveryValue() throws {
        let snapshot = ReadingSessionSnapshot(
            id: UUID(),
            documentID: UUID(),
            startedAt: Date(timeIntervalSinceReferenceDate: 1000),
            endedAt: Date(timeIntervalSinceReferenceDate: 2000),
            plain: ReadingAmount(words: 700, seconds: 150.5),
            voiced: ReadingAmount(words: 300, seconds: 90.25)
        )
        #expect(ReadingSession(snapshot, isFinished: true).snapshot == snapshot)
    }
}
