#if os(iOS)
import AVFAudio
#endif
import Foundation
import os

/// The audio session while reading aloud: spoken audio that plays with the
/// silent switch on, pauses other spoken audio such as podcasts, and mixes
/// with music.
///
/// Reports what playback has to answer: an interruption (a call, another
/// app), its end, headphones going away, and the media services resetting.
/// Callbacks run on the main actor. On macOS there's no audio session, so
/// every method does nothing and no callback is ever called.
///
/// The app has one audio session, however many of these there are (each
/// reader has one, and so does the Settings sample), so each is a claim on
/// it (``Claims``): the session is active while any of them has activated
/// it and not deactivated it since. One deactivating while another plays
/// leaves the session active, as deactivating it under running audio would
/// stop that audio.
final class ReadAloudAudioSession {
    /// Something else took the audio, and the system has already stopped
    /// playback. Pause.
    var onInterruptionBegan: (() -> Void)?
    /// The interruption is over. `shouldResume` is the system's hint that
    /// playback may go on; ``activate()`` before playing again.
    var onInterruptionEnded: ((_ shouldResume: Bool) -> Void)?
    /// The output in use went away, as when headphones are unplugged. Pause
    /// rather than go on through the speaker.
    var onOutputLost: (() -> Void)?
    /// The media services restarted, and every audio object made before is
    /// dead: make a new ``SpeechPlayer`` and renderer, and ``activate()``
    /// again before playing.
    var onMediaServicesReset: (() -> Void)?

    #if os(iOS)
    /// Whether this one claims the session, as it does from the moment
    /// ``activate()`` is called, so a ``deactivate()`` right after it still
    /// goes through. A failed activation, an interruption, or the media
    /// services resetting give the claim up.
    var isActive: Bool { Self.claims.clients.contains(client) }

    /// Which client of the session this is.
    private let client: Int
    private var observers: [NSObjectProtocol] = []

    /// The claims of every one of these on the app's audio session.
    private static var claims = Claims()
    private static var clientCount = 0

    /// Activating and deactivating wait on the audio server, which can hold
    /// the main thread up for a noticeable moment, so both run here, in the
    /// order they're asked for.
    nonisolated private static let queue = DispatchQueue(label: "com.abdeen.strobe.read-aloud-session")

    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.abdeen.strobe",
        category: "ReadAloud"
    )

    init() {
        Self.clientCount += 1
        client = Self.clientCount
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo
            let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(
                rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            )
            MainActor.assumeIsolated { self?.interrupted(type, options: options) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            guard reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.onOutputLost?() }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.mediaServicesWereReset() }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        // One dropped without deactivating gives up its claim, so the
        // session isn't left active for good.
        let client = client
        Task { @MainActor in
            if ReadAloudAudioSession.claims.deactivate(client) {
                ReadAloudAudioSession.deactivateSession()
            }
        }
    }

    /// Claims the session, then sets the category and activates it, off the
    /// main thread. Throws when the system won't let reading aloud start, as
    /// during a phone call, and then holds no claim.
    ///
    /// Every call activates the session, even while another client holds
    /// it: activating an active session changes nothing, and the system can
    /// have deactivated it without saying so.
    func activate() async throws {
        let request = Self.claims.activate(client)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                Self.queue.async {
                    do {
                        let session = AVAudioSession.sharedInstance()
                        try session.setCategory(.playback, mode: .spokenAudio, options: [.interruptSpokenAudioAndMixWithOthers])
                        try session.setActive(true)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            if Self.claims.activationFailed(request, client: client) {
                Self.deactivateSession()
            }
            throw error
        }
        Self.claims.activationSucceeded(request, client: client)
    }

    /// Gives up this one's claim, and deactivates the session if no other
    /// client claims it. Stop or pause the player first: deactivating the
    /// session stops audio that's still running, though the system then
    /// reports that it failed.
    func deactivate() {
        if Self.claims.deactivate(client) {
            Self.deactivateSession()
        }
    }

    /// Deactivates the session, off the main thread, and lets paused audio
    /// elsewhere resume.
    private static func deactivateSession() {
        queue.async {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                Self.logger.error("Couldn't deactivate the read-aloud audio session: \(error)")
            }
        }
    }

    private func interrupted(_ type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            // The system deactivated the session, for every client.
            Self.claims.sessionWasDeactivated()
            onInterruptionBegan?()
        case .ended:
            onInterruptionEnded?(options.contains(.shouldResume))
        default:
            break
        }
    }

    private func mediaServicesWereReset() {
        Self.logger.info("Media services were reset")
        // The session went with them, for every client.
        Self.claims.sessionWasDeactivated()
        onMediaServicesReset?()
    }
    #else
    let isActive = false

    init() {}

    func activate() async throws {}

    func deactivate() {}
    #endif

    /// Which clients claim the app's one audio session, and so when it's
    /// deactivated: the bookkeeping, apart from the session. Each client is
    /// a number, never reused.
    ///
    /// Each activation is a request, and only a client's latest one changes
    /// its claim when it finishes: activating takes a moment, in which the
    /// client can deactivate and activate again.
    nonisolated struct Claims: Sendable {
        /// The clients claiming the session.
        private(set) var clients: Set<Int> = []
        /// Each client's latest activation, until it deactivates.
        private var latestRequests: [Int: Int] = [:]
        private var requestCount = 0

        /// `client` claims the session, and goes on to activate it.
        /// - Returns: The request, to report how activating went.
        mutating func activate(_ client: Int) -> Int {
            requestCount += 1
            latestRequests[client] = requestCount
            clients.insert(client)
            return requestCount
        }

        /// `client` activated the session. If nothing it asked for since
        /// replaced the request, it claims the session again, which the
        /// system can have deactivated meanwhile (``sessionWasDeactivated()``).
        mutating func activationSucceeded(_ request: Int, client: Int) {
            guard latestRequests[client] == request else { return }
            clients.insert(client)
        }

        /// `client` couldn't activate the session. If nothing it asked for
        /// since replaced the request, it gives up its claim.
        /// - Returns: Whether to deactivate the session: no client claims
        ///   it now, though it can still be active for one that let go
        ///   while this claim held it.
        mutating func activationFailed(_ request: Int, client: Int) -> Bool {
            guard latestRequests[client] == request else { return false }
            return deactivate(client)
        }

        /// `client` gives up its claim, if it has one.
        /// - Returns: Whether to deactivate the session: it was the last
        ///   client claiming it.
        mutating func deactivate(_ client: Int) -> Bool {
            latestRequests[client] = nil
            return clients.remove(client) != nil && clients.isEmpty
        }

        /// The system deactivated the session, as for an interruption, so
        /// no client claims it.
        mutating func sessionWasDeactivated() {
            clients.removeAll()
        }
    }
}
