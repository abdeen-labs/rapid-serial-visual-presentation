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
    /// Whether the session is active, or about to be: set as soon as
    /// ``activate()`` is called, so a ``deactivate()`` right after it still
    /// goes through.
    private(set) var isActive = false
    private var observers: [NSObjectProtocol] = []

    /// Activating and deactivating wait on the audio server, which can hold
    /// the main thread up for a noticeable moment, so both run here, in the
    /// order they're asked for.
    nonisolated private static let queue = DispatchQueue(label: "com.abdeen.strobe.read-aloud-session")

    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.abdeen.strobe",
        category: "ReadAloud"
    )

    init() {
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
    }

    /// Sets the category and activates the session, off the main thread.
    /// Throws when the system won't let reading aloud start, as during a
    /// phone call.
    func activate() async throws {
        isActive = true
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
            isActive = false
            throw error
        }
    }

    /// Deactivates the session, off the main thread, and lets paused audio
    /// elsewhere resume. Stop or pause the player first: the session won't
    /// deactivate while audio is running.
    func deactivate() {
        guard isActive else { return }
        isActive = false
        Self.queue.async {
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
            // The system deactivated the session.
            isActive = false
            onInterruptionBegan?()
        case .ended:
            onInterruptionEnded?(options.contains(.shouldResume))
        default:
            break
        }
    }

    private func mediaServicesWereReset() {
        Self.logger.info("Media services were reset")
        isActive = false
        onMediaServicesReset?()
    }
    #else
    let isActive = false

    init() {}

    func activate() async throws {}

    func deactivate() {}
    #endif
}
