#if os(iOS)
import UIKit
#endif

/// Asks iOS for time to finish something should the app leave the
/// foreground meanwhile, as an app with nothing playing is suspended within
/// seconds. iOS gives about half a minute, then ends the request. On macOS,
/// where apps aren't suspended, it does nothing.
///
/// Begin in the foreground or the background; ``end()`` as soon as the work
/// is done, or once something else keeps the app running, as audio playing
/// does. One let go of without ending lasts until iOS's time is up.
final class BackgroundTime {
    #if os(iOS)
    private var task: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// Asks for the time. `name` shows in the system's logs.
    init(_ name: String) {
        #if os(iOS)
        // Holds on to this until the request ends, so one let go of without
        // ending still ends when time's up, rather than iOS ending the app
        // for it. The work goes on if the app does.
        task = UIApplication.shared.beginBackgroundTask(withName: name) {
            self.end()
        }
        #endif
    }

    /// Lets the system suspend the app again. Ending twice changes nothing.
    func end() {
        #if os(iOS)
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
        #endif
    }
}
