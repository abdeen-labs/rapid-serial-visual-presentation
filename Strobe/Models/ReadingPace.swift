import Foundation

/// How much longer a document takes to read under the timing settings than
/// its word count at plain words per minute: the time smart timing,
/// compounds, acronyms, punctuation pauses, complexity, and sentence breaks
/// add, as a factor on the plain estimate.
///
/// A document's factor is its reading time in base intervals (one word's
/// time at plain WPM) divided by its word count, timed word by word with the
/// engine's own math
/// (``RSVPEngine/interval(forWordAt:in:complexityScores:timing:baseInterval:)``).
/// Every term there scales with the base interval, so one factor holds at
/// every speed. It scales the time left from the resume position and each
/// chapter's length, taking the rest of a document to read like the whole.
/// Chapter announcements, a few fixed seconds each, are left out.
///
/// Working a factor out reads every word, so it runs off the main actor when
/// a view or the widget first needs it, and is kept by document, word count,
/// and timing settings: in memory, and in a small file in Caches so it
/// survives relaunch. Until a document's factor is known for the current
/// settings, its estimates stay plain.
@Observable
final class ReadingPace {
    static let shared = ReadingPace()

    /// Posted on the main actor when the timing settings change or a factor
    /// is worked out, so `LibraryObserver` can rewrite the widget's snapshot.
    static let didChange = Notification.Name("ReadingPace.didChange")

    nonisolated static let fileURL = URL.cachesDirectory.appending(path: "ReadingPace.plist")

    /// What a factor holds for. A document's words never change, so its word
    /// count stands for its content; new complexity scores, the one later
    /// change that matters, drop its factor through ``forget(_:)``. The
    /// speed isn't part of it: the factor is the same at every speed.
    nonisolated struct Key: Hashable, Codable, Sendable {
        let documentID: UUID
        let wordCount: Int
        let timing: ReaderSettings.TimingSnapshot
    }

    nonisolated private struct Entry: Codable {
        let key: Key
        let factor: Double
    }

    /// The timing settings estimates follow. Updated once a change to them
    /// settles, so dragging a slider doesn't start a computation per step.
    private(set) var timing: ReaderSettings.TimingSnapshot
    /// The latest factor worked out for each document, under whichever
    /// settings its key names.
    private var entries: [UUID: Entry]

    @ObservationIgnored private var pending: [UUID: (key: Key, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheURL: URL?

    /// Lives as long as the app. Tests pass their own defaults, and a nil
    /// `cacheURL` to keep factors in memory only.
    init(defaults: UserDefaults = .standard, cacheURL: URL? = ReadingPace.fileURL) {
        self.defaults = defaults
        self.cacheURL = cacheURL
        timing = ReaderSettings.timingSnapshot(from: defaults)
        entries = Self.load(from: cacheURL)
        // Any change to any defaults: checking the settings is cheap, and
        // it doesn't depend on which instance wrote them.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.settingsDidChange() }
        }
    }

    // MARK: - Estimates

    func key(for document: Document) -> Key {
        Key(documentID: document.id, wordCount: document.wordCount, timing: timing)
    }

    /// `document`'s factor under the current timing settings, or nil until
    /// it's worked out. Never starts the work; see ``prepare(_:)``.
    func factor(for document: Document) -> Double? {
        let key = self.key(for: document)
        guard let entry = entries[key.documentID], entry.key == key else { return nil }
        return entry.factor
    }

    /// Minutes to finish `document` from its resume position: at its
    /// factor once that's known, at plain WPM until then.
    func remainingMinutes(for document: Document) -> Int {
        document.remainingMinutes(paceFactor: factor(for: document))
    }

    /// Starts working out `document`'s factor for the current timing
    /// settings, unless it's known or under way. The blobs are read here and
    /// decoded and timed off the main actor. Views call this from
    /// `.task(id: key(for:))`, so it runs again when the settings change.
    func prepare(_ document: Document) {
        let key = self.key(for: document)
        guard key.wordCount > 0,
              entries[key.documentID]?.key != key,
              pending[key.documentID]?.key != key else { return }

        let wordsBlob = document.wordsBlob
        let legacyWords = wordsBlob?.isEmpty == false ? [] : document.words
        // Scores only matter with complexity timing on.
        let complexityBlob = key.timing.complexityTimingEnabled ? document.complexityBlob : nil
        let chapters = document.chapters
        let task = Task {
            let factor = await Task.detached(priority: .utility) {
                let words = wordsBlob.flatMap { $0.isEmpty ? nil : WordStorage.decode($0) } ?? legacyWords
                let scores = complexityBlob.flatMap { $0.isEmpty ? nil : ComplexityStorage.decode($0) }
                return ReadingPace.factor(words: words, complexityScores: scores, chapters: chapters, timing: key.timing)
            }.value
            self.finish(key, factor: factor)
        }
        pending[key.documentID] = (key, task)
    }

    /// `document`'s factor, waiting for it to be worked out if need be. For
    /// answers that can't update later, such as a spoken one.
    func preparedFactor(for document: Document) async -> Double? {
        prepare(document)
        if let task = pending[document.id]?.task {
            await task.value
        }
        return factor(for: document)
    }

    /// Drops a document's factor, after its complexity scores change. The
    /// next ``prepare(_:)`` works it out again.
    func forget(_ documentID: UUID) {
        pending[documentID] = nil
        guard entries.removeValue(forKey: documentID) != nil else { return }
        save()
    }

    /// Stores a finished factor unless a newer request for the document
    /// replaced it, or ``forget(_:)`` dropped it.
    private func finish(_ key: Key, factor: Double) {
        guard pending[key.documentID]?.key == key else { return }
        pending[key.documentID] = nil
        entries[key.documentID] = Entry(key: key, factor: factor)
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// A document's factor under `timing`: its words' total time in base
    /// intervals, the blanks after sentences included, per word. 1 when
    /// there are no words.
    nonisolated static func factor(
        words: [String],
        complexityScores: [Float]?,
        chapters: [Chapter],
        timing: ReaderSettings.TimingSnapshot
    ) -> Double {
        guard !words.isEmpty else { return 1 }
        let chapterStarts = RSVPEngine.announcedChapters(chapters, wordCount: words.count)
        let breakIntervals = RSVPEngine.sentenceBreakInterval(timing: timing, baseInterval: 1)
        var total = 0.0
        for index in words.indices {
            total += RSVPEngine.interval(
                forWordAt: index,
                in: words,
                complexityScores: complexityScores,
                timing: timing,
                baseInterval: 1
            )
            if RSVPEngine.breaksAfterWord(
                at: index,
                in: words,
                nextWordStartsChapter: chapterStarts[index + 1] != nil,
                timing: timing
            ) {
                total += breakIntervals
            }
        }
        return total / Double(words.count)
    }

    // MARK: - Settings

    private func settingsDidChange() {
        settingsTask?.cancel()
        settingsTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            reloadTiming()
        }
    }

    /// Reads the timing settings now. A change makes every factor stale, and
    /// estimates plain until each is worked out again.
    func reloadTiming() {
        let timing = ReaderSettings.timingSnapshot(from: defaults)
        guard timing != self.timing else { return }
        self.timing = timing
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - Storage

    private static func load(from url: URL?) -> [UUID: Entry] {
        guard let url, let data = try? Data(contentsOf: url),
              let saved = try? PropertyListDecoder().decode([Entry].self, from: data) else { return [:] }
        return Dictionary(saved.map { ($0.key.documentID, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Saves the factors that hold for the current settings. Losing the file
    /// only means working them out again.
    private func save() {
        guard let cacheURL else { return }
        let current = entries.values.filter { $0.key.timing == timing }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try? encoder.encode(current).write(to: cacheURL, options: .atomic)
    }
}
