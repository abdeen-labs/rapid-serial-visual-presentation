import Foundation

/// Tokenizes plain text a paragraph at a time, recording where each
/// paragraph ends.
///
/// A paragraph ends at a blank line (or a Unicode paragraph separator). A
/// single line break is usually a hard wrap, not a block, so it doesn't
/// count. The words are the ones ``Tokenizer/tokenize(_:)`` gives for the
/// whole text, except that a number unit never joins across a paragraph
/// (`2000` ending one and `BCE` opening the next), as across an EPUB block.
/// A hyphenated fragment still carries across. A paragraph ending on one
/// records its end only if the fragment doesn't merge with the next word.
nonisolated enum PlainTextParagraphs {

    static func tokenize(_ text: String) -> (words: [String], blockEnds: BlockEnds) {
        var words: [String] = []
        var blockEnds = BlockEnds()
        var carry: String?
        var paragraph = ""
        var isFirst = true

        func endParagraph() {
            guard paragraph.contains(where: { !$0.isWhitespace }) else {
                paragraph.removeAll(keepingCapacity: true)
                return
            }
            let before = words.count
            let pending = carry
            Tokenizer.appendTokenizedText(paragraph, into: &words, carry: &carry, startsBlock: !isFirst)
            isFirst = false
            paragraph.removeAll(keepingCapacity: true)
            // A fragment the last paragraph ended on that didn't merge came
            // out as a word of its own: it ended that paragraph.
            if let pending, words.count > before, words[before] == pending {
                blockEnds.mark(before, as: .block)
            }
            if carry == nil, words.count > before { blockEnds.mark(words.count - 1, as: .block) }
        }

        let normalized = normalizingLineEnds(text)
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.allSatisfy(\.isWhitespace) {
                endParagraph()
            } else {
                paragraph += line
                paragraph += "\n"
            }
        }
        endParagraph()
        if let carry, !carry.isEmpty {
            words.append(carry)
            blockEnds.mark(words.count - 1, as: .block)
        }
        return (words, blockEnds)
    }

    /// `text` with `\r\n`, a lone `\r`, and U+2028 as `\n`, and U+2029 (a
    /// paragraph separator) as a blank line.
    static func normalizingLineEnds(_ text: String) -> String {
        guard text.contains(where: { $0 == "\r\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" }) else {
            return text
        }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n\n")
    }
}
