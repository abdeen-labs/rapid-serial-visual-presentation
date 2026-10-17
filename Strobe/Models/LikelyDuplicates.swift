import Foundation

/// Finds books likely in the library more than once, so the library can
/// offer to merge them: the same EPUB, PDF, or web article imported on two
/// devices at different times (the tokenizer changed in between) or at
/// different text-cleaning levels. Their words differ, so iCloud sync can't
/// merge them on its own the way it merges identical copies (see
/// `CloudSyncLedger.duplicateRemovals`). The user picks the copy to keep.
///
/// Copies match on the same title, ignoring case, accents, and surrounding
/// space; the same file name, ignoring case; and word counts within a fifth
/// of the larger. Left alone:
/// - Text added without a file (New Text, shared text, shortcuts), which
///   stores its title as its file name.
/// - Copies leaving the library, or with their deletion on its way.
/// - Groups of identical copies: sync merges those imported on different
///   devices, and the rest were made on purpose.
/// - Groups imported on this device, every copy: made on purpose too.
/// - Groups the user chose to keep on this device (`KeptLikelyDuplicates`).
nonisolated enum LikelyDuplicates {
    /// A document as matching sees it.
    struct Candidate: Equatable {
        var id: UUID
        var title: String
        var fileName: String
        var wordCount: Int
        /// Where iCloud sync says it came from; nil when sync doesn't know.
        var origin: CloudSyncLedger.Entry.Origin?
        /// On its way out of the library, or deleted with the deletion not
        /// yet confirmed.
        var isLeaving = false
    }

    /// The groups of copies likely to be one book, each in the order of
    /// `candidates`, and ordered by their first copy there.
    ///
    /// `haveSameWords` says whether two copies of equal length have the
    /// same words. It's only asked when every copy in a group has the same
    /// word count, so words are rarely read.
    static func groups(
        among candidates: [Candidate],
        kept: KeptLikelyDuplicates,
        haveSameWords: (Candidate, Candidate) -> Bool
    ) -> [[UUID]] {
        var keys: [[String]] = []
        var buckets: [[String]: [(offset: Int, candidate: Candidate)]] = [:]
        for (offset, candidate) in candidates.enumerated() where !candidate.isLeaving {
            guard let title = titleKey(candidate.title),
                  let fileName = fileNameKey(candidate.fileName) else { continue }
            let key = [title, fileName]
            if buckets[key] == nil { keys.append(key) }
            buckets[key, default: []].append((offset: offset, candidate: candidate))
        }

        var found: [(offset: Int, ids: [UUID])] = []
        for key in keys {
            for cluster in lengthClusters(buckets[key] ?? []) where cluster.count > 1 {
                let copies = cluster.map { $0.candidate }
                // Every copy imported here: duplicated on purpose.
                guard copies.contains(where: { $0.origin != .importedHere }) else { continue }
                if let first = copies.first,
                   copies.allSatisfy({ $0.wordCount == first.wordCount }),
                   copies.dropFirst().allSatisfy({ haveSameWords(first, $0) }) {
                    continue
                }
                let ids = copies.map { $0.id }
                guard !kept.contains(ids) else { continue }
                found.append((offset: cluster[0].offset, ids: ids))
            }
        }
        return found.sorted { $0.offset < $1.offset }.map { $0.ids }
    }

    /// Whether two word counts are within a fifth of the larger: room for a
    /// tokenizer change or a different cleaning level, not for an abridged
    /// edition or another volume.
    static func haveSimilarLengths(_ a: Int, _ b: Int) -> Bool {
        let larger = max(a, b)
        guard larger > 0 else { return false }
        return (larger - min(a, b)) * 5 <= larger
    }

    /// Splits copies into runs of similar length, each measured from its
    /// longest copy, so every copy in a run is within a fifth of every
    /// other. Each run keeps the copies' order.
    private static func lengthClusters(
        _ copies: [(offset: Int, candidate: Candidate)]
    ) -> [[(offset: Int, candidate: Candidate)]] {
        let longestFirst = copies.sorted {
            $0.candidate.wordCount != $1.candidate.wordCount
                ? $0.candidate.wordCount > $1.candidate.wordCount
                : $0.offset < $1.offset
        }
        var clusters: [[(offset: Int, candidate: Candidate)]] = []
        var longest = 0
        for copy in longestFirst {
            if !clusters.isEmpty, haveSimilarLengths(longest, copy.candidate.wordCount) {
                clusters[clusters.count - 1].append(copy)
            } else {
                clusters.append([copy])
                longest = copy.candidate.wordCount
            }
        }
        return clusters.map { $0.sorted { $0.offset < $1.offset } }
    }

    /// A title as matching compares it: trimmed, ignoring case and accents.
    /// Nil when nothing is left.
    static func titleKey(_ title: String) -> String? {
        let key = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return key.isEmpty ? nil : key
    }

    /// A file name as matching compares it, ignoring case. A web article's
    /// is its address, which matches the same way. Nil for text added
    /// without a file, which stores its title here: a text document only
    /// has a file name when it ends like a text file.
    static func fileNameKey(_ fileName: String) -> String? {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if DocumentKind(fileName: trimmed) == .text,
           !textFileExtensions.contains((trimmed as NSString).pathExtension.lowercased()) {
            return nil
        }
        return trimmed.lowercased()
    }

    /// The extensions of the plain-text files Strobe imports, as
    /// `DocumentImportPipeline` reads them.
    private static let textFileExtensions: Set<String> = ["txt", "text", "md", "markdown"]

    // MARK: - Merging

    /// A copy's length and reading, as merging sees it.
    struct Reading: Equatable {
        var wordCount: Int
        var position: ReadingPosition
    }

    /// The reading the kept copy takes when the other copies go. Their
    /// words differ, so indices carry over in proportion to the copies'
    /// lengths (`mappedIndex`). The resume point and speed come from the
    /// copy read most recently, the kept one on a tie or when none was
    /// read. The furthest point is the furthest of any copy, as the library
    /// counts progress, so it never goes back. The last-read date is the
    /// latest.
    static func mergedReading(keeping kept: Reading, others: [Reading]) -> ReadingPosition {
        var latest = kept
        for other in others {
            guard let date = other.position.lastReadDate else { continue }
            if latest.position.lastReadDate.map({ date > $0 }) ?? true {
                latest = other
            }
        }
        let copies = [kept] + others
        let furthest = copies.map { copy in
            mappedIndex(
                max(copy.position.furthestWordIndex, copy.position.currentWordIndex),
                from: copy.wordCount,
                to: kept.wordCount
            )
        }.max() ?? 0
        return ReadingPosition(
            currentWordIndex: mappedIndex(latest.position.currentWordIndex, from: latest.wordCount, to: kept.wordCount),
            furthestWordIndex: furthest,
            wordsPerMinute: latest.position.wordsPerMinute,
            lastReadDate: copies.compactMap { $0.position.lastReadDate }.max()
        )
    }

    /// A word index in a copy of `sourceCount` words, carried to the same
    /// place in one of `targetCount`: `index × targetCount / sourceCount`,
    /// rounded to the nearest word (half up) and kept inside the target's
    /// words. The index is kept inside the source's words first, which also
    /// keeps the product far from overflowing.
    static func mappedIndex(_ index: Int, from sourceCount: Int, to targetCount: Int) -> Int {
        guard sourceCount > 0, targetCount > 0 else { return 0 }
        let index = min(max(0, index), sourceCount - 1)
        let mapped = (2 * index * targetCount + sourceCount) / (2 * sourceCount)
        return min(mapped, targetCount - 1)
    }
}

/// The groups of likely duplicates the user chose to keep on this device,
/// stored under `ReaderSettings.Keys.keptLikelyDuplicates`. A kept group is
/// stored as every pair of copies in it, so a group is offered again once a
/// copy that wasn't in it joins, and stays kept when one of its copies
/// leaves.
nonisolated struct KeptLikelyDuplicates: RawRepresentable, Equatable, Sendable {
    /// Pairs of document IDs, as `pairKey` writes them.
    private(set) var pairs: Set<String>

    init() {
        pairs = []
    }

    /// One pair per line.
    init(rawValue: String) {
        pairs = Set(rawValue.split(separator: "\n").map(String.init))
    }

    var rawValue: String {
        pairs.sorted().joined(separator: "\n")
    }

    /// Whether every pair of these copies was kept, so the group they form
    /// isn't offered again.
    func contains(_ ids: [UUID]) -> Bool {
        let keys = Self.pairKeys(of: ids)
        return !keys.isEmpty && keys.allSatisfy { pairs.contains($0) }
    }

    /// Keeps a group. Pairs with a copy no longer in `library` go, so the
    /// list doesn't grow with books long gone.
    mutating func keep(_ ids: [UUID], library: Set<UUID>) {
        pairs = pairs.filter { pair in
            pair.split(separator: " ").allSatisfy { part in
                UUID(uuidString: String(part)).map { library.contains($0) } ?? false
            }
        }
        pairs.formUnion(Self.pairKeys(of: ids))
    }

    /// The same for either order.
    static func pairKey(_ a: UUID, _ b: UUID) -> String {
        let (first, second) = a.uuidString < b.uuidString ? (a, b) : (b, a)
        return "\(first.uuidString) \(second.uuidString)"
    }

    private static func pairKeys(of ids: [UUID]) -> [String] {
        ids.indices.flatMap { i in
            ids[(i + 1)...].map { pairKey(ids[i], $0) }
        }
    }
}
