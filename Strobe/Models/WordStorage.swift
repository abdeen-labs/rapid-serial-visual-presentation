import Foundation

/// Encodes and decodes word arrays as newline-delimited UTF-8 data
/// for compact external storage in SwiftData.
enum WordStorage {
    nonisolated private static let separator = "\n"

    /// Encodes a word array into newline-delimited UTF-8 data.
    nonisolated static func encode(_ words: [String]) -> Data {
        words.joined(separator: separator).data(using: .utf8) ?? Data()
    }

    /// Decodes newline-delimited UTF-8 data back into a word array.
    nonisolated static func decode(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
    }

    /// The words at `range` of the data, as ``decode(_:)`` would give them,
    /// without building the rest: the words before the range are only
    /// counted by their newlines. Words past the end are left out.
    nonisolated static func decode(_ data: Data, range: Range<Int>) -> [String] {
        let range = max(0, range.lowerBound)..<max(0, range.upperBound)
        guard !data.isEmpty, !range.isEmpty else { return [] }
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [String] in
            guard let base = buffer.baseAddress else { return [] }
            var words: [String] = []
            words.reserveCapacity(min(range.count, 1024))
            var position = 0
            var index = 0
            while index < range.upperBound {
                let newline: UnsafeMutableRawPointer? = position < buffer.count
                    ? memchr(base + position, 0x0A, buffer.count - position)
                    : nil
                let end = newline.map { base.distance(to: UnsafeRawPointer($0)) } ?? buffer.count
                if index >= range.lowerBound {
                    words.append(String(decoding: UnsafeRawBufferPointer(rebasing: buffer[position..<end]), as: UTF8.self))
                }
                guard newline != nil else { break }
                position = end + 1
                index += 1
            }
            return words
        }
    }
}
