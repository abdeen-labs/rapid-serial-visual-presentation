import Foundation

/// The files waiting to import from a drop or the file picker, which import
/// one after another, and what went wrong with the ones already tried.
///
/// A batch lasts until nothing is importing, waiting, or still loading from
/// a drop. Its failures are then reported together in one alert, so one bad
/// file in a stack of books neither stops the rest nor raises an alert per
/// file.
nonisolated struct ImportQueue {
    nonisolated struct Item: Equatable, Sendable {
        let url: URL
        /// A drop's private copy, deleted once it's imported or abandoned.
        let deleteAfterImport: Bool
    }

    /// A file that didn't make it into the library.
    nonisolated enum Failure: Equatable, Sendable {
        /// A dropped file that isn't a PDF, EPUB, or text file.
        case unsupported(fileName: String?)
        /// A dropped file whose contents couldn't be loaded.
        case unreadable(fileName: String?)
        /// A file whose import failed, with the error's message.
        case failed(fileName: String, message: String)
    }

    /// What a dropped file turned out to be once it loaded.
    nonisolated enum DropResult: Equatable, Sendable {
        case file(Item)
        case rejected(Failure)
    }

    /// One alert's title and message.
    nonisolated struct Report: Equatable {
        var title = "Couldn't Import File"
        var message: String
    }

    /// The most failures one alert names before summing up the rest.
    static let maxListedFailures = 5

    private(set) var pending: [Item] = []
    private(set) var failures: [Failure] = []
    /// Files taken from the queue in this batch; the one importing is the last.
    private(set) var startedCount = 0
    /// Files in this batch that never reached the queue.
    private var rejectedCount = 0
    /// Dropped files still loading.
    private var loadingCount = 0
    /// Moves on at every `cancel()`, so drops that finish loading after it
    /// are ignored.
    private var generation = 0

    /// The files this batch has queued so far, for "3 of 21".
    var queuedCount: Int { startedCount + pending.count }

    mutating func enqueue(_ item: Item) {
        pending.append(item)
    }

    /// Notes a failure. Any but `.failed` is a file that never reached the
    /// queue, and counts toward the batch's files.
    mutating func record(_ failure: Failure) {
        failures.append(failure)
        if case .failed = failure { return }
        rejectedCount += 1
    }

    /// Notes that `count` dropped files have started loading. Pass the
    /// returned generation to ``receive(_:from:)`` as each one arrives.
    mutating func beginLoading(_ count: Int) -> Int {
        loadingCount += count
        return generation
    }

    /// Queues or records a dropped file that finished loading. Returns false,
    /// changing nothing, if the batch it belonged to was cancelled.
    mutating func receive(_ result: DropResult, from generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        loadingCount -= 1
        switch result {
        case .file(let item): enqueue(item)
        case .rejected(let failure): record(failure)
        }
        return true
    }

    /// The next file to import, if one is waiting. Call only while no import
    /// is running.
    mutating func next() -> Item? {
        guard !pending.isEmpty else { return nil }
        startedCount += 1
        return pending.removeFirst()
    }

    /// Ends the batch once nothing is waiting or loading, returning its
    /// failures as one alert, or nil if there were none. While files are
    /// still waiting or loading, returns nil and leaves the batch alone.
    mutating func finishBatch() -> Report? {
        guard pending.isEmpty, loadingCount == 0 else { return nil }
        defer {
            failures = []
            startedCount = 0
            rejectedCount = 0
        }
        return Self.report(for: failures, fileCount: startedCount + rejectedCount)
    }

    /// Drops every waiting file and ignores drops still loading, returning
    /// the dropped files so their copies can be deleted. The import running
    /// now is the caller's to cancel; failures so far are still reported.
    mutating func cancel() -> [Item] {
        defer { pending = [] }
        loadingCount = 0
        generation += 1
        return pending
    }

    /// One file failing on its own gets that failure's own message. Anything
    /// more counts the failures and names the first few.
    static func report(for failures: [Failure], fileCount: Int) -> Report? {
        guard let first = failures.first else { return nil }
        if failures.count == 1 && fileCount <= 1 {
            return Report(message: first.message)
        }

        let summary = failures.count >= fileCount
            ? "None of the \(failures.count) files could be imported."
            : "\(failures.count) of \(fileCount) files couldn't be imported."
        var lines = failures.prefix(maxListedFailures).map(\.line)
        if failures.count > maxListedFailures {
            lines.append("And \(failures.count - maxListedFailures) more.")
        }
        return Report(
            title: failures.count == 1 ? "Couldn't Import File" : "Couldn't Import Files",
            message: summary + "\n\n" + lines.joined(separator: "\n")
        )
    }
}

extension ImportQueue.Failure {
    /// The alert's message when this is the only file.
    nonisolated var message: String {
        switch self {
        case .unsupported(let fileName?):
            "\"\(fileName)\" isn't a supported file type. Drop a PDF, EPUB, or text file."
        case .unsupported(nil):
            "That file isn't a supported type. Drop a PDF, EPUB, or text file."
        case .unreadable(let fileName?):
            "Couldn't read \"\(fileName)\"."
        case .unreadable(nil):
            "Couldn't read the dropped file."
        case .failed(_, let message):
            message
        }
    }

    /// This failure's line in an alert listing several.
    nonisolated var line: String {
        switch self {
        case .unsupported(let fileName?):
            "\(fileName): not a PDF, EPUB, or text file."
        case .unsupported(nil):
            "One file isn't a PDF, EPUB, or text file."
        case .unreadable(let fileName?):
            "\(fileName): couldn't be read."
        case .unreadable(nil):
            "One file couldn't be read."
        case .failed(let fileName, let message):
            "\(fileName): \(message)"
        }
    }
}
