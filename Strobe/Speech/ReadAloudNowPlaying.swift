import Foundation
import MediaPlayer
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The app's entry in the system's Now Playing while a voice reads: what
/// the lock screen, Control Center, and the Mac's menu bar show, and where
/// the play and pause of headphones, a car, a watch, or the keyboard's media
/// keys go.
///
/// One reader has it at a time, the last to start reading aloud
/// (``show(_:isPlaying:for:)``). It shows the document's title and cover,
/// playing or paused, until that reader lets go (``release(_:)``), as when
/// it closes or stops reading aloud; the controls are then turned off.
///
/// On iOS the system takes whether the app plays from its audio session,
/// so only an app whose audio doesn't mix with others' can have the entry
/// (``ReadAloudAudioSession``). On macOS it goes by ``playbackState``.
final class ReadAloudNowPlaying {
    static let shared = ReadAloudNowPlaying()

    /// What a reader shows there.
    struct Item {
        /// The document's.
        var id: UUID
        var title: String
        var cover: DocumentCover
    }

    /// The reader that has the entry.
    private weak var owner: ReadAloudController?
    private var hasTargets = false
    /// The last cover drawn, by document and title, so pausing and playing
    /// don't draw it again.
    private var artwork: (key: String, artwork: MPMediaItemArtwork)?

    /// The size covers are drawn at, in points, at 2:3 like the library's.
    private static let artworkSize = CGSize(width: 300, height: 450)

    /// Shows `item` for `reader`, which takes the entry from any other.
    func show(_ item: Item, isPlaying: Bool, for reader: ReadAloudController) {
        owner = reader
        addTargetsIfNeeded()
        setCommandsEnabled(true)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artwork = artwork(for: item) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = isPlaying ? .playing : .paused
        #endif
    }

    /// Shows whether `reader`'s voice plays, if it has the entry.
    func update(isPlaying: Bool, for reader: ReadAloudController) {
        guard owner === reader else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        #if os(macOS)
        center.playbackState = isPlaying ? .playing : .paused
        #endif
    }

    /// Takes the entry away, if `reader` has it.
    func release(_ reader: ReadAloudController) {
        guard owner === reader else { return }
        owner = nil
        setCommandsEnabled(false)
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        #if os(macOS)
        center.playbackState = .stopped
        #endif
    }

    // MARK: - Commands

    private func addTargetsIfNeeded() {
        guard !hasTargets else { return }
        hasTargets = true
        let commands = MPRemoteCommandCenter.shared()
        // The system calls these on the main thread.
        commands.playCommand.addTarget { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.play() ?? .noActionableNowPlayingItem }
        }
        commands.pauseCommand.addTarget { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.pause() ?? .noActionableNowPlayingItem }
        }
        commands.togglePlayPauseCommand.addTarget { @Sendable [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let owner = self.owner else { return .noActionableNowPlayingItem }
                return owner.isPlaying ? self.pause() : self.play()
            }
        }
    }

    private func setCommandsEnabled(_ isEnabled: Bool) {
        let commands = MPRemoteCommandCenter.shared()
        for command in [commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand] {
            command.isEnabled = isEnabled
        }
    }

    private func play() -> MPRemoteCommandHandlerStatus {
        guard let owner else { return .noActionableNowPlayingItem }
        return owner.playFromSystem() ? .success : .commandFailed
    }

    private func pause() -> MPRemoteCommandHandlerStatus {
        guard let owner else { return .noActionableNowPlayingItem }
        owner.pauseFromSystem()
        return .success
    }

    // MARK: - Artwork

    /// The document's cover, drawn once for each document and title.
    private func artwork(for item: Item) -> MPMediaItemArtwork? {
        let key = "\(item.id.uuidString) \(item.title)"
        if let artwork, artwork.key == key { return artwork.artwork }
        let renderer = ImageRenderer(content: item.cover.frame(width: Self.artworkSize.width, height: Self.artworkSize.height))
        #if os(iOS)
        renderer.scale = 3
        #else
        renderer.scale = 2
        #endif
        guard let image = renderer.cgImage else { return nil }
        let size = Self.artworkSize
        let artwork = MPMediaItemArtwork(boundsSize: size) { @Sendable _ in
            #if os(iOS)
            UIImage(cgImage: image)
            #else
            NSImage(cgImage: image, size: size)
            #endif
        }
        self.artwork = (key, artwork)
        return artwork
    }
}
