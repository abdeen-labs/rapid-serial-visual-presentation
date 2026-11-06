import Foundation

/// Plain text plus positions captured before markup and boilerplate disappear.
/// Positions are UTF-16 offsets, matching Foundation's text ranges.
struct EPUBContent {
    var text = ""
    var anchors: [String: Int] = [:]
    /// Each heading's text, where it starts, and its level (1 for `<h1>`).
    var headings: [(title: String, offset: Int, level: Int)] = []
    /// Where block elements (paragraphs, headings, list items) open or close,
    /// ascending. Words on either side of one never join as a number unit.
    var blockBreaks: [Int] = []

    nonisolated init() {}

    nonisolated private static let tagPattern = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->|<(?:"[^"]*"|'[^']*'|[^'">])*>"#
    )
    nonisolated private static let attributePattern = try! NSRegularExpression(
        pattern: #"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#
    )
    nonisolated private static let tokenPattern = try! NSRegularExpression(pattern: #"\S+"#)
    nonisolated private static let blockTags: Set<String> = [
        "p", "div", "br", "h1", "h2", "h3", "h4", "h5", "h6",
        "li", "blockquote", "section", "article"
    ]
    nonisolated private static let skippedTags: Set<String> = ["head", "script", "style", "table", "nav"]

    /// Tolerates the imperfect XHTML accepted by the existing importer, while
    /// handling quoted `>` characters, comments, entities, and inline titles.
    nonisolated static func parse(_ data: Data) -> EPUBContent {
        let html = String(decoding: data, as: UTF8.self) as NSString
        var result = EPUBContent()
        var length = 0
        var cursor = 0
        var skipped: [String] = []
        var heading: (tag: String, offset: Int)?

        func append(_ text: String) {
            result.text.append(text)
            length += text.utf16.count
        }
        func appendText(until end: Int) {
            if skipped.isEmpty, end > cursor {
                append(EPUBTextExtractor.resolveHTMLEntities(
                    html.substring(with: NSRange(location: cursor, length: end - cursor))
                ))
            }
        }

        tagPattern.enumerateMatches(in: html as String, range: NSRange(location: 0, length: html.length)) { match, _, _ in
            guard let match else { return }
            appendText(until: match.range.location)
            cursor = NSMaxRange(match.range)
            let raw = html.substring(with: match.range)
            guard !raw.hasPrefix("<!"), !raw.hasPrefix("<?") else { return }
            let body = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            let closing = body.hasPrefix("/")
            let name = body.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .split(whereSeparator: { $0.isWhitespace || $0 == "/" }).first.map(String.init)?.lowercased() ?? ""

            if !skipped.isEmpty {
                if closing, skipped.last == name { skipped.removeLast() }
                else if !closing, skippedTags.contains(name), !body.hasSuffix("/") { skipped.append(name) }
                return
            }
            if !closing, skippedTags.contains(name) {
                if !body.hasSuffix("/") { skipped.append(name) }
                return
            }
            if closing, let active = heading, active.tag == name {
                let title = (result.text as NSString).substring(from: active.offset)
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !title.isEmpty {
                    result.headings.append((title, active.offset, Int(active.tag.dropFirst()) ?? 1))
                }
                heading = nil
            }
            if blockTags.contains(name) {
                result.blockBreaks.append(length)
                append(" ")
            }
            guard !closing else { return }

            let attributes = body as NSString
            attributePattern.enumerateMatches(in: body, range: NSRange(location: 0, length: attributes.length)) { attribute, _, _ in
                guard let attribute else { return }
                let key = attributes.substring(with: attribute.range(at: 1)).lowercased()
                guard key == "id" || key == "xml:id" || (name == "a" && key == "name") else { return }
                let range = attribute.range(at: attribute.range(at: 2).location == NSNotFound ? 3 : 2)
                let value = EPUBTextExtractor.resolveHTMLEntities(attributes.substring(with: range))
                if !value.isEmpty, result.anchors[value] == nil { result.anchors[value] = length }
            }
            if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(name) {
                heading = (name, length)
            }
        }
        appendText(until: html.length)
        return result
    }

    /// Maps markers as the actual cleaned text is tokenized. Splitting only
    /// at whitespace preserves inline words, CJK segmentation, punctuation,
    /// and the tokenizer's cross-chunk hyphen carry.
    nonisolated func appendWords(
        cleanedText: String, into words: inout [String], carry: inout String?
    ) -> [Int: Int] {
        let offsets = Set([0] + Array(anchors.values) + headings.map(\.offset)).sorted()
        var marker = 0
        var blockBreak = 0
        var positions: [Int: Int] = [:]
        let text = cleanedText as NSString
        Self.tokenPattern.enumerateMatches(in: cleanedText, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let match else { return }
            let before = words.count
            let pending = carry
            let token = text.substring(with: match.range)
            var startsBlock = false
            while blockBreak < blockBreaks.count, blockBreaks[blockBreak] < match.range.location {
                startsBlock = true
                blockBreak += 1
            }
            Tokenizer.appendTokenizedText(token, into: &words, carry: &carry, startsBlock: startsBlock)
            guard token.unicodeScalars.contains(where: {
                $0.properties.isAlphabetic || $0.properties.numericType != nil
            }) else { return }
            // A token that neither added a word nor became the carry was
            // joined onto the previous word as the second half of a number
            // unit (`2000` + `BCE`); its markers belong to that word.
            let joinedPrevious = carry == nil && words.count == before
            // An unmerged carry belongs to the previous chunk, not this one.
            let start = joinedPrevious
                ? before - 1
                : before + (pending != nil && words.count > before && words[before] == pending ? 1 : 0)
            while marker < offsets.count, offsets[marker] < NSMaxRange(match.range) {
                positions[offsets[marker]] = start
                marker += 1
            }
        }
        // Markers after the last readable token (or in an empty spine file)
        // have no destination; do not attach them to the next file's words.
        return positions
    }
}
