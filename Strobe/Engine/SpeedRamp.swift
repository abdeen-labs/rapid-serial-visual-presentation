import Foundation

/// Starting a reading session below the speed and working up to it (opt-in,
/// `speedRampEnabled`).
///
/// Words start at ``startFraction`` of the speed and gain evenly, until
/// after ``duration`` of playing they run at the speed itself. The time is
/// the engine's (``RSVPEngine/rampElapsed``): the time words have played,
/// pauses left out, which starts over with each reader and after a pause
/// longer than ``sessionPause``. A voice reading aloud reads at the speed
/// itself.
nonisolated struct SpeedRamp: Hashable, Sendable {
    var isEnabled = false
    /// The share of the speed a session starts at.
    var startFraction = ReaderSettings.Defaults.speedRampStart
    /// The playing time, in seconds, until words run at the speed.
    var duration: TimeInterval = ReaderSettings.Defaults.speedRampMinutes * 60

    /// The starting shares Settings offers.
    static let startRange: ClosedRange<Double> = 0.5...0.95
    /// The lengths Settings offers, in minutes.
    static let minutesRange: ClosedRange<Double> = 1...10
    /// The longest pause a session carries on after, as for reading
    /// statistics; reading after a longer one ramps up again.
    static let sessionPause = ReadingSessionTracker.maximumPause

    /// The share of the speed words run at once they have played for
    /// `elapsed` seconds: from ``startFraction`` up to 1, and always 1
    /// while the ramp is off.
    func speedFraction(after elapsed: TimeInterval) -> Double {
        guard isEnabled, duration > 0, elapsed < duration else { return 1 }
        // Never from a standstill, whatever was stored.
        let start = min(1, max(0.1, startFraction))
        return start + (1 - start) * max(0, elapsed) / duration
    }
}
