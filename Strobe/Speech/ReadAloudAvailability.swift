import Foundation

/// What the reader's Read Aloud button shows and what tapping it does, from
/// the setting, the document's language, the voice model's state, and
/// whether a voice reads yet.
///
/// The voice is a download (``KokoroVoiceModel``), so turning reading aloud
/// on can mean asking to download it first, and the button shows the
/// download and the first load while they run. Until a voice reads, the
/// words go on without one.
nonisolated struct ReadAloudAvailability: Equatable {
    /// The voice model's state (``KokoroVoiceModel/State``), as far as the
    /// reader goes by it.
    nonisolated enum ModelState: Equatable {
        case notInstalled
        case downloading(fraction: Double?)
        case installed
        case preparing
        case ready
        case failed(message: String)

        /// Whether the model is on disk, so a reader can ask it for a
        /// voice. One that failed to load waits for Try Again.
        var isOnDisk: Bool {
            switch self {
            case .installed, .preparing, .ready: true
            case .notInstalled, .downloading, .failed: false
            }
        }
    }

    /// What the button shows.
    nonisolated enum Status: Equatable {
        /// Reading aloud is off.
        case off
        /// The document isn't in English, which the voices don't read yet.
        case englishOnly
        /// Reading aloud is on, but the voice isn't downloaded.
        case needsDownload
        /// The voice is downloading: the fraction done, when known.
        case downloading(fraction: Double?)
        /// The voice is loading, which takes a while the first time.
        case preparing
        /// A voice reads the words.
        case reading
        /// The voice couldn't download or load.
        case failed(message: String)
    }

    /// What tapping the button does.
    nonisolated enum Tap: Equatable {
        case turnOn
        case turnOff
        /// Ask before downloading the voice; downloading turns reading
        /// aloud on.
        case offerDownload
        /// Turn reading aloud on and try the voice's download or load again.
        case retry
        /// Say that only English documents are read aloud for now.
        case explainEnglishOnly
        /// Say why the voice isn't ready, offering to try again.
        case explainFailure(message: String)
    }

    var isEnabled: Bool
    /// Whether the voices read the document
    /// (``KokoroVoices/canRead(documentLanguage:)``).
    var canReadDocument: Bool
    var model: ModelState
    /// Whether a voice reads the reader's words.
    var isReadingAloud: Bool
    /// Why the reader couldn't get its voice, when the model's state
    /// doesn't say.
    var readerFailure: String? = nil

    var status: Status {
        // Whatever the setting, so tapping explains rather than turning on
        // something that won't read.
        guard canReadDocument else { return .englishOnly }
        guard isEnabled else { return .off }
        if isReadingAloud { return .reading }
        if let readerFailure { return .failed(message: readerFailure) }
        switch model {
        case .notInstalled:
            return .needsDownload
        case .downloading(let fraction):
            return .downloading(fraction: fraction)
        case .installed, .preparing, .ready:
            // Until the reader has its voice, which can take the model's
            // load and a moment after it.
            return .preparing
        case .failed(let message):
            return .failed(message: message)
        }
    }

    var tap: Tap {
        switch status {
        case .off:
            switch model {
            case .notInstalled: .offerDownload
            // The download was agreed to before, so it goes on unasked.
            case .failed: .retry
            case .downloading, .installed, .preparing, .ready: .turnOn
            }
        case .englishOnly:
            .explainEnglishOnly
        case .needsDownload:
            .offerDownload
        case .downloading, .preparing, .reading:
            // A download under way goes on, for next time.
            .turnOff
        case .failed(let message):
            .explainFailure(message: message)
        }
    }
}
