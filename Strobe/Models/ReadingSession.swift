import Foundation
import SwiftData

/// One reading session, as the Statistics sheet counts it: when it started
/// and ended, and the words read and time taken with the words alone and
/// with the voice (see ``ReadingSessionTracker``).
///
/// The reader stores a session once it counts and updates it as reading
/// goes on, so a session survives the app being closed. Until it ends only
/// this device has it. Once it ends (``isFinished``) it never changes, and
/// iCloud sync sends it to the other devices, which store it finished.
/// Sync never deletes one, and deleting a document leaves its sessions.
@Model
final class ReadingSession {
    @Attribute(.unique) var id: UUID
    var documentID: UUID?
    var startedAt: Date
    var endedAt: Date
    var plainWords: Int
    var plainSeconds: Double
    var voicedWords: Int
    var voicedSeconds: Double
    var isFinished: Bool

    init(_ snapshot: ReadingSessionSnapshot, isFinished: Bool) {
        id = snapshot.id
        documentID = snapshot.documentID
        startedAt = snapshot.startedAt
        endedAt = snapshot.endedAt
        plainWords = snapshot.plain.words
        plainSeconds = snapshot.plain.seconds
        voicedWords = snapshot.voiced.words
        voicedSeconds = snapshot.voiced.seconds
        self.isFinished = isFinished
    }

    var snapshot: ReadingSessionSnapshot {
        ReadingSessionSnapshot(
            id: id,
            documentID: documentID,
            startedAt: startedAt,
            endedAt: endedAt,
            plain: ReadingAmount(words: plainWords, seconds: plainSeconds),
            voiced: ReadingAmount(words: voicedWords, seconds: voicedSeconds)
        )
    }

    /// Takes the values of `snapshot`, the same session further along.
    func update(from snapshot: ReadingSessionSnapshot, isFinished: Bool) {
        endedAt = snapshot.endedAt
        plainWords = snapshot.plain.words
        plainSeconds = snapshot.plain.seconds
        voicedWords = snapshot.voiced.words
        voicedSeconds = snapshot.voiced.seconds
        if isFinished { self.isFinished = true }
    }

    /// Ends the sessions a reader left open when the app last closed, as
    /// when iOS ended it in the background. No reader is open at launch, so
    /// every unfinished session is one of those. Returns whether any ended.
    @discardableResult
    static func finishAbandoned(in context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<ReadingSession>(predicate: #Predicate { !$0.isFinished })
        guard let abandoned = try? context.fetch(descriptor), !abandoned.isEmpty else { return false }
        for session in abandoned {
            session.isFinished = true
        }
        return true
    }
}

/// Records a reader's sessions in the library's store as it plays and
/// pauses (``ReadingSessionTracker``): a session is stored once it counts,
/// updated at each save, and finished when a long pause ends it or the
/// reader closes.
@MainActor
final class ReadingSessionRecorder {
    private var tracker: ReadingSessionTracker
    /// The stored copy of the session under way, once it counts.
    private var stored: ReadingSession?

    init(documentID: UUID) {
        tracker = ReadingSessionTracker(documentID: documentID)
    }

    /// Playback started or stopped, with the engine's played words so far.
    /// `isVoiced` matters on starting: whether a voice paces the words.
    func playbackChanged(isPlaying: Bool, playedWords: Int, isVoiced: Bool, in context: ModelContext) {
        let now = Date.now
        if isPlaying {
            if let ended = tracker.play(at: now, playedWords: playedWords, isVoiced: isVoiced) {
                store(ended, isFinished: true, in: context)
                try? context.save()
            }
        } else {
            tracker.pause(at: now, playedWords: playedWords)
        }
    }

    /// Stores the session so far, for the reader's own save to write. Takes
    /// a pause that came with the save (`isPlaying` false) before playback
    /// has reported it.
    func save(isPlaying: Bool, playedWords: Int, in context: ModelContext) {
        let now = Date.now
        if !isPlaying {
            tracker.pause(at: now, playedWords: playedWords)
        }
        if let session = tracker.current(at: now, playedWords: playedWords) {
            store(session, isFinished: false, in: context)
        }
    }

    /// Ends the session as the reader closes, and saves it.
    func finish(playedWords: Int, in context: ModelContext) {
        guard let session = tracker.finish(at: .now, playedWords: playedWords) else { return }
        store(session, isFinished: true, in: context)
        try? context.save()
    }

    private func store(_ session: ReadingSessionSnapshot, isFinished: Bool, in context: ModelContext) {
        if let stored, stored.id == session.id {
            stored.update(from: session, isFinished: isFinished)
        } else {
            let new = ReadingSession(session, isFinished: isFinished)
            context.insert(new)
            stored = new
        }
        if isFinished { stored = nil }
    }
}
