import Foundation

/// Words read in some time: a session's, a day's, or a period's, with or
/// without a voice.
nonisolated struct ReadingAmount: Hashable, Codable, Sendable {
    var words = 0
    var seconds: TimeInterval = 0

    /// The speed these words were read at, or nil without any time.
    var wordsPerMinute: Double? {
        seconds > 0 ? Double(words) / seconds * 60 : nil
    }

    static func + (lhs: ReadingAmount, rhs: ReadingAmount) -> ReadingAmount {
        ReadingAmount(words: lhs.words + rhs.words, seconds: lhs.seconds + rhs.seconds)
    }

    static func += (lhs: inout ReadingAmount, rhs: ReadingAmount) {
        lhs = lhs + rhs
    }
}

/// One reading session's values, apart from where they're stored: what the
/// reader records, sync sends, and statistics add up.
nonisolated struct ReadingSessionSnapshot: Hashable, Sendable, Identifiable {
    let id: UUID
    /// The document read, which may since have left the library.
    let documentID: UUID?
    var startedAt: Date
    /// When reading last stopped, or the latest moment counted while it
    /// goes on.
    var endedAt: Date
    /// Read with the words alone.
    var plain = ReadingAmount()
    /// Read while the voice paced the words.
    var voiced = ReadingAmount()

    var total: ReadingAmount { plain + voiced }
}

/// Turns one reader's plays and pauses into reading sessions.
///
/// A session's time is the time words were playing, chapter titles and the
/// blanks after sentences included; its words are the ones playback moved
/// past, as the engine counts them (``RSVPEngine/playedWordTotal``). Each
/// stretch of playing counts toward reading with the voice or without, as it
/// started: the voice can only start or stop while playback is paused.
///
/// A pause longer than ``maximumPause`` ends the session, and the next play
/// starts another; closing the reader ends it too. A session with fewer than
/// ``minimumWords`` words, a tap to look or a scrub, isn't one.
nonisolated struct ReadingSessionTracker {
    static let maximumPause: TimeInterval = 5 * 60
    static let minimumWords = 10
    /// The most a word can honestly take: far slower than the slowest speed
    /// with every pause. A stretch that took longer, as when a Mac slept
    /// while playing, counts at this rate.
    static let maximumSecondsPerWord: TimeInterval = 6
    /// What a stretch may take beyond its words' share, for a chapter title
    /// or the voice's first load.
    static let stretchAllowance: TimeInterval = 10

    let documentID: UUID?
    private var session: ReadingSessionSnapshot?
    private var stretch: Stretch?

    private struct Stretch {
        let startedAt: Date
        let playedWords: Int
        let isVoiced: Bool
    }

    init(documentID: UUID?) {
        self.documentID = documentID
    }

    /// Whether words are playing in a stretch the tracker is timing.
    var isPlaying: Bool { stretch != nil }

    /// Playback started, with `playedWords` played so far by the engine.
    /// Returns the session a long pause just ended, if it counts.
    mutating func play(at date: Date, playedWords: Int, isVoiced: Bool) -> ReadingSessionSnapshot? {
        guard stretch == nil else { return nil }
        var ended: ReadingSessionSnapshot?
        if let session, date.timeIntervalSince(session.endedAt) > Self.maximumPause {
            ended = Self.counted(session)
            self.session = nil
        }
        if session == nil {
            session = ReadingSessionSnapshot(id: UUID(), documentID: documentID, startedAt: date, endedAt: date)
        }
        stretch = Stretch(startedAt: date, playedWords: playedWords, isVoiced: isVoiced)
        return ended
    }

    /// Playback paused, with `playedWords` played so far by the engine.
    mutating func pause(at date: Date, playedWords: Int) {
        guard let session, let stretch else { return }
        self.session = Self.adding(stretch, to: session, at: date, playedWords: playedWords)
        self.stretch = nil
    }

    /// The session so far, the stretch playing now included, or nil while
    /// it doesn't count yet. For saving it before it ends.
    func current(at date: Date, playedWords: Int) -> ReadingSessionSnapshot? {
        guard var session else { return nil }
        if let stretch {
            session = Self.adding(stretch, to: session, at: date, playedWords: playedWords)
        }
        return Self.counted(session)
    }

    /// Ends the session, as when the reader closes. Returns it if it counts.
    mutating func finish(at date: Date, playedWords: Int) -> ReadingSessionSnapshot? {
        let finished = current(at: date, playedWords: playedWords)
        session = nil
        stretch = nil
        return finished
    }

    private static func counted(_ session: ReadingSessionSnapshot) -> ReadingSessionSnapshot? {
        session.total.words >= minimumWords ? session : nil
    }

    private static func adding(
        _ stretch: Stretch,
        to session: ReadingSessionSnapshot,
        at date: Date,
        playedWords: Int
    ) -> ReadingSessionSnapshot {
        let words = max(0, playedWords - stretch.playedWords)
        let elapsed = max(0, date.timeIntervalSince(stretch.startedAt))
        let seconds = min(elapsed, Double(words) * maximumSecondsPerWord + stretchAllowance)
        var session = session
        let amount = ReadingAmount(words: words, seconds: seconds)
        if stretch.isVoiced {
            session.voiced += amount
        } else {
            session.plain += amount
        }
        session.endedAt = max(session.endedAt, date)
        return session
    }
}
