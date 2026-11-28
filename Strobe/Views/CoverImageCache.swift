import CoreGraphics
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// Book covers decoded for drawing, by document, shared by every view that
/// shows one.
///
/// A cover decodes off the main actor the first time a view asks for it,
/// and stays decoded until the cache runs past ``costLimit``. Each cover has
/// its own observable entry, so a cover arriving redraws only the views
/// showing it, not the whole grid. A cover only changes through
/// ``Document/setCover(_:)``, which drops its entry here.
final class CoverImageCache {
    static let shared = CoverImageCache()

    /// What a view draws for a document.
    struct Cover {
        /// The decoded cover, or nil while it decodes or when there's none.
        var image: CGImage?
        /// True while the cover decodes, when the generated one leaves its
        /// title off rather than flash it.
        var isPending: Bool
    }

    @Observable
    final class Entry {
        var image: CGImage?
        var isPending = true
        @ObservationIgnored fileprivate var task: Task<DecodedCover?, Never>?
        /// When a view last asked for it, by ``CoverImageCache/useCount``.
        @ObservationIgnored var lastUse = 0
        /// The decoded image's bytes.
        @ObservationIgnored var cost = 0
    }

    /// About 45 covers at the stored size: more than any screen shows.
    static let costLimit = 96 << 20

    private var entries: [UUID: Entry] = [:]
    private var useCount = 0
    private var totalCost = 0
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        #if os(iOS)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeDecodedCovers() }
        }
        #endif
    }

    /// The document's cover as it stands. Read from a view's body, it
    /// redraws the view when the cover arrives; the first read starts
    /// decoding it.
    func cover(for document: Document) -> Cover {
        guard let entry = entry(for: document) else { return Cover(image: nil, isPending: false) }
        return Cover(image: entry.image, isPending: entry.isPending)
    }

    /// The document's decoded cover, once it's decoded. Nil when it has
    /// none or it doesn't decode.
    func load(_ document: Document) async -> CGImage? {
        guard let entry = entry(for: document) else { return nil }
        if let image = entry.image { return image }
        return await entry.task?.value?.image
    }

    private func entry(for document: Document) -> Entry? {
        useCount += 1
        if let entry = entries[document.id] {
            entry.lastUse = useCount
            return entry
        }
        // A document without a cover reads a nil attribute: nothing loads.
        guard let data = document.coverImageData, !data.isEmpty else { return nil }
        let entry = Entry()
        entry.lastUse = useCount
        entries[document.id] = entry
        let id = document.id
        entry.task = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) {
                CoverImage.decode(data).map(DecodedCover.init)
            }.value
            entry.image = decoded?.image
            entry.isPending = false
            entry.task = nil
            self?.didDecode(entry, id: id)
            return decoded
        }
        return entry
    }

    /// Forgets a document's decoded cover once its cover changed or went
    /// (``Document/setCover(_:)``). The views showing it follow the entry,
    /// not the document, so the entry is emptied to redraw them; they then
    /// ask again and get the new cover, or the generated one.
    func coverDidChange(for documentID: UUID) {
        guard let entry = entries.removeValue(forKey: documentID) else { return }
        totalCost -= entry.cost
        entry.cost = 0
        entry.image = nil
        entry.isPending = false
    }

    /// Counts a decoded cover and, past the limit, forgets the covers least
    /// recently asked for. A view still showing one keeps its image; it
    /// decodes again only if it's drawn anew.
    private func didDecode(_ entry: Entry, id: UUID) {
        guard entries[id] === entry, let image = entry.image else { return }
        entry.cost = image.bytesPerRow * image.height
        totalCost += entry.cost
        while totalCost > Self.costLimit,
              let oldest = entries.filter({ !$0.value.isPending && $0.key != id }).min(by: { $0.value.lastUse < $1.value.lastUse }) {
            totalCost -= oldest.value.cost
            entries[oldest.key] = nil
        }
    }

    /// Lets go of every decoded cover, as when memory runs low.
    private func removeDecodedCovers() {
        entries = entries.filter { $0.value.isPending }
        totalCost = 0
    }
}

extension Document {
    /// Sets or removes the document's cover: at import, when sync brings
    /// the book or a changed cover, and from Edit Cover. Keeps the
    /// fingerprint in step and redraws what shows the cover. Doesn't save.
    func setCover(_ data: Data?) {
        let cover = data.flatMap { $0.isEmpty ? nil : $0 }
        coverImageData = cover
        coverFingerprint = cover.map { ContentFingerprint.of($0) }
        CoverImageCache.shared.coverDidChange(for: id)
    }
}

/// A decoded cover handed from the decoding task to the main actor. A
/// `CGImage` is immutable, so it's safe to share.
fileprivate nonisolated struct DecodedCover: @unchecked Sendable {
    let image: CGImage
}
