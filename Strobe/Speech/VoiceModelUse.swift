import Foundation
import SwiftUI

/// Keeps the voice model (``KokoroVoiceModel``) loaded while something
/// reads with it, and frees its memory once nothing does.
///
/// Each reader reading aloud holds it while it shows, and so does its
/// passage view, which covers it on iOS, and the Read Aloud settings page
/// (``SwiftUI/View/keepsVoiceModelLoaded(_:)``). Once the last one lets go,
/// the model unloads after ``unloadDelay``, so a reader handing over to its
/// passage view, or one window to another, doesn't unload it only to load
/// it again.
enum VoiceModelUse {
    static let unloadDelay: Duration = .seconds(2)

    private static var holders: Set<UUID> = []
    private static var pendingUnload: Task<Void, Never>?

    static func hold(_ holder: UUID) {
        holders.insert(holder)
        pendingUnload?.cancel()
        pendingUnload = nil
    }

    static func release(_ holder: UUID) {
        guard holders.remove(holder) != nil else { return }
        unloadIfUnused()
    }

    /// Downloads the model if it isn't on disk and loads it, as Download
    /// Voice and Try Again do, then unloads it if nothing reads with it by
    /// then: the first load compiles the model for the device, which later
    /// loads keep.
    static func install() {
        guard KokoroVoiceModel.isSupported else { return }
        Task {
            await KokoroVoiceModel.shared.install()
            unloadIfUnused()
        }
    }

    private static func unloadIfUnused() {
        guard holders.isEmpty, KokoroVoiceModel.isSupported else { return }
        pendingUnload?.cancel()
        pendingUnload = Task {
            try? await Task.sleep(for: unloadDelay)
            // A load under way finishes first, since the model doesn't
            // unload while it loads; the first one compiles the model for
            // the device, which later loads keep. A download goes on, and
            // `install()` looks again once it's done.
            while !Task.isCancelled, KokoroVoiceModel.shared.state == .preparing {
                try? await Task.sleep(for: unloadDelay)
            }
            guard !Task.isCancelled, holders.isEmpty else { return }
            await KokoroVoiceModel.shared.unload()
        }
    }
}

extension View {
    /// Keeps the voice model loaded while this view shows and `isOn` (see
    /// ``VoiceModelUse``).
    func keepsVoiceModelLoaded(_ isOn: Bool = true) -> some View {
        modifier(VoiceModelHold(isOn: isOn))
    }
}

private struct VoiceModelHold: ViewModifier {
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
            VoiceModelUse.hold(id)
        } else {
            VoiceModelUse.release(id)
        }
    }
}
