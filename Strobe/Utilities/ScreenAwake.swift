import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Keeps the screen from dimming and locking while words play.
///
/// Reading that no finger holds (hands-free, Tap to Read, a voice, the
/// keyboard) gives the system no touches, so Auto-Lock would cut it off:
/// after 30 seconds in Low Power Mode. Each reader holds the screen awake
/// while its words play in an active scene and Keep Screen Awake is on
/// (``SwiftUI/View/keepsScreenAwake(_:)``); paused, the screen dims and
/// locks as usual. On iOS that turns off the app's idle timer, and on macOS
/// an activity holds off display sleep.
enum ScreenAwake {
    private static var holders: Set<UUID> = []
    #if os(macOS)
    private static var activity: (any NSObjectProtocol)?
    #endif

    static func hold(_ holder: UUID) {
        guard holders.insert(holder).inserted else { return }
        apply()
    }

    static func release(_ holder: UUID) {
        guard holders.remove(holder) != nil else { return }
        apply()
    }

    private static func apply() {
        let isHeld = !holders.isEmpty
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = isHeld
        #elseif os(macOS)
        if isHeld, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .idleDisplaySleepDisabled,
                reason: "Reading"
            )
        } else if !isHeld, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
        #endif
    }
}

extension View {
    /// Keeps the screen awake while this view shows and `isOn` (see
    /// ``ScreenAwake``).
    func keepsScreenAwake(_ isOn: Bool) -> some View {
        modifier(ScreenAwakeHold(isOn: isOn))
    }
}

private struct ScreenAwakeHold: ViewModifier {
    let isOn: Bool
    @State private var id = UUID()
    @State private var isShowing = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                isShowing = true
                update()
            }
            .onDisappear {
                isShowing = false
                update()
            }
            .onChange(of: isOn) {
                update()
            }
    }

    private func update() {
        if isShowing && isOn {
            ScreenAwake.hold(id)
        } else {
            ScreenAwake.release(id)
        }
    }
}
