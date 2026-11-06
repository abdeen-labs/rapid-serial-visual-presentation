import Foundation

/// Where a document's paragraphs, headings, list items, and table cells end,
/// by the index of each one's last word.
///
/// The word list is flat, so without these a heading or list item with no
/// closing punctuation runs straight into what follows. Importers record
/// them, `Document.blockEndsBlob` keeps them (``BlockEndStorage``), and the
/// engine's timing, ``ReadingPace``, and the voice read them: a block's end
/// pauses like a sentence end (and gets a sentence break), a table cell's
/// like a clause mark. A document imported before they existed has none and
/// reads as it always did.
nonisolated struct BlockEnds: Equatable, Sendable {

    /// What ended at a word.
    enum Kind: UInt8, Sendable {
        /// A paragraph, heading, list item, or other block: a sentence end.
        case block = 0
        /// A table cell: a clause mark.
        case cell = 1

        /// The punctuation pause this end stands for.
        var marks: PunctuationMarks {
            switch self {
            case .block: .sentenceEnd
            case .cell: .clause
            }
        }
    }

    private var kinds: [Int: Kind]

    /// No block ends: a document imported before they were recorded, or
    /// one whose format has none (PDF).
    static let none = BlockEnds()

    init() {
        kinds = [:]
    }

    init(_ kinds: [Int: Kind]) {
        self.kinds = kinds.filter { $0.key >= 0 }
    }

    var isEmpty: Bool { kinds.isEmpty }
    var count: Int { kinds.count }

    /// The ends in word order.
    var entries: [(index: Int, kind: Kind)] {
        kinds.sorted { $0.key < $1.key }.map { (index: $0.key, kind: $0.value) }
    }

    /// Records that a block or cell ends with the word at `index`. A block
    /// ending at the same word as a cell (a table's last cell) stays a block.
    mutating func mark(_ index: Int, as kind: Kind) {
        guard index >= 0 else { return }
        if kinds[index] == .block { return }
        kinds[index] = kind
    }

    /// The index of the last end, if any.
    var lastIndex: Int? { kinds.keys.max() }

    /// These ends without the ones right before a chapter start: the
    /// chapter's announcement is the pause there.
    func droppingEnds(beforeChapterStarts starts: some Sequence<Int>) -> BlockEnds {
        var copy = self
        for start in starts { copy.kinds[start - 1] = nil }
        return copy
    }

    /// What ended with the word at `index`, as recorded.
    func kind(at index: Int) -> Kind? {
        kinds[index]
    }

    /// The end that pauses reading after the word at `index`, if any.
    ///
    /// A block's end doesn't pause when the next word starts with a
    /// lowercase letter, looking past opening quotes and brackets: that's
    /// one sentence carrying on across a block, as when an EPUB splits a
    /// paragraph where a printed page broke. Scripts without case always
    /// pause, and so does a table cell, whatever follows it.
    func pause(after index: Int, in words: [String]) -> Kind? {
        guard let kind = kinds[index] else { return nil }
        if kind == .block, words.indices.contains(index + 1), Self.startsLowercase(words[index + 1]) {
            return nil
        }
        return kind
    }

    private static func startsLowercase(_ word: String) -> Bool {
        guard let first = word.first(where: { $0.isLetter || $0.isNumber }) else { return false }
        return first.isLowercase
    }
}

/// Encodes ``BlockEnds`` compactly for `Document.blockEndsBlob` and sync.
///
/// Each end is one unsigned LEB128 varint of its index's distance from the
/// previous end's (the first from -1), shifted left one bit, with the kind
/// in the low bit. A book of 5,000 paragraphs takes about 10 KB.
nonisolated enum BlockEndStorage {

    /// The encoded ends; nil when there are none.
    static func encode(_ ends: BlockEnds) -> Data? {
        guard !ends.isEmpty else { return nil }
        var data = Data()
        data.reserveCapacity(ends.count * 2)
        var previous = -1
        for entry in ends.entries {
            var value = UInt64(entry.index - previous) << 1 | UInt64(entry.kind.rawValue)
            previous = entry.index
            repeat {
                var byte = UInt8(value & 0x7F)
                value >>= 7
                if value != 0 { byte |= 0x80 }
                data.append(byte)
            } while value != 0
        }
        return data
    }

    /// The ends `data` holds. Stops at the first malformed value, keeping
    /// what came before it; nil or empty data holds none.
    static func decode(_ data: Data?) -> BlockEnds {
        guard let data, !data.isEmpty else { return .none }
        var kinds: [Int: BlockEnds.Kind] = [:]
        var previous = -1
        var value: UInt64 = 0
        var shift: UInt64 = 0
        for byte in data {
            guard shift < 63 else { break }
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 != 0 {
                shift += 7
                continue
            }
            let distance = value >> 1
            guard distance > 0, distance <= UInt64(Int.max) - UInt64(previous + 1) else { break }
            let index = previous + Int(distance)
            kinds[index] = value & 1 == 0 ? .block : .cell
            previous = index
            value = 0
            shift = 0
        }
        return BlockEnds(kinds)
    }
}
