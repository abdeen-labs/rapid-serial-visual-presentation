import Foundation
import SwiftUI

/// Keeps the voice model (``KokoroVoiceModel``) loaded while something
/// reads with it, and frees its memory once nothing does.
///
/// Each reader reading aloud holds it while it shows, and so does its
/// passage view, which covers it on iOS
/// (``SwiftUI/View/keepsVoiceModelLoaded(_:)``). A voice sample in Settings
/// holds it while it plays and for a while after, so trying one voice after
/// another doesn't load it each time (``release(_:after:)``). Holding never
/// loads the model; reading or a sample does. Once the last one lets go,
/// the model unloads after ``unloadDelay``, so a reader handing over to its
/// passage view, or one window to another, doesn't unload it only to load
/// it again.
enum VoiceModelUse {
    static let unloadDelay: Duration = .seconds(2)

    private static var holders: Set<UUID> = []
    /// Holders letting go once a delay is up, by holder.
    private static var pendingReleases: [UUID: Task<Void, Never>] = [:]
    private static var pendingUnload: Task<Void, Never>?

    static func hold(_ holder: UUID) {
        pendingReleases.removeValue(forKey: holder)?.cancel()
        holders.insert(holder)
        pendingUnload?.cancel()
        pendingUnload = nil
    }

    static func release(_ holder: UUID) {
        pendingReleases.removeValue(forKey: holder)?.cancel()
        guard holders.remove(holder) != nil else { return }
        unloadIfUnused()
    }

    /// Lets go of `holder` once `delay` is up, unless it holds again first.
    static func release(_ holder: UUID, after delay: Duration) {
        guard holders.contains(holder) else { return }
        pendingReleases[holder]?.cancel()
        pendingReleases[holder] = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            pendingReleases[holder] = nil
            release(holder)
        }
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
            // A download, load, or voice under way finishes first, since the
            // model doesn't unload while one runs; the first load compiles
            // the model for the device, which later loads keep.
            while !Task.isCancelled, KokoroVoiceModel.shared.isBusy {
                try? await Task.sleep(for: unloadDelay)
            }
            guard !Task.isCancelled, holders.isEmpty else { return }
            KokoroVoiceModel.shared.unload()
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
