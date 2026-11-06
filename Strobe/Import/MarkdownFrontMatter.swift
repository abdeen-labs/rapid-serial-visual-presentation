import Foundation

/// The metadata block a Markdown file can open with: YAML between `---`
/// lines (Jekyll, Hugo, Obsidian, and GitHub's renderer) or TOML between
/// `+++` lines (Hugo).
///
/// CommonMark has no front matter, so a parser reads YAML's opening fence as
/// a thematic break and its keys, up to the closing fence, as a heading.
/// ``MarkdownTextExtractor`` takes the block off before parsing and keeps
/// only its title.
///
/// A block counts only when it opens the file (after any byte order mark),
/// closes, and reads as metadata line by line, so a document that opens with
/// a thematic break and a paragraph keeps them.
nonisolated enum MarkdownFrontMatter {

    /// `text` without a byte order mark or front matter, and the front
    /// matter's title, if it has one.
    static func split(_ text: String) -> (title: String?, body: String) {
        var scalars = Substring(text).unicodeScalars
        if scalars.first == "\u{FEFF}" { scalars = scalars.dropFirst() }
        let whole = String(Substring(scalars))

        var lines = Lines(scalars)
        guard let opening = lines.next() else { return (nil, whole) }
        let syntax: Syntax
        switch trimmingTrailingWhitespace(opening) {
        case "---": syntax = .yaml
        case "+++": syntax = .toml
        default: return (nil, whole)
        }

        var block: [String] = []
        var validator = Validator(syntax: syntax)
        while let line = lines.next() {
            let trimmed = trimmingTrailingWhitespace(line)
            if trimmed == syntax.fence || (syntax == .yaml && trimmed == "...") {
                guard validator.sawEntry else { return (nil, whole) }
                return (title(in: block, syntax: syntax), lines.rest)
            }
            guard validator.accepts(line) else { return (nil, whole) }
            block.append(line)
        }
        // Never closed: not front matter.
        return (nil, whole)
    }

    // MARK: - Syntax

    nonisolated private enum Syntax {
        case yaml, toml

        var fence: String { self == .yaml ? "---" : "+++" }
    }

    nonisolated private static let yamlKey = try! NSRegularExpression(
        pattern: #"^(?:"[^"]*"|'[^']*'|[^\s"'#:\[\]{}\-][^:]{0,63}?)\s*:(?:\s|$)"#
    )
    nonisolated private static let tomlKey = try! NSRegularExpression(
        pattern: #"^(?:"[^"]*"|'[^']*'|[A-Za-z0-9_-]+)(?:\s*\.\s*(?:"[^"]*"|'[^']*'|[A-Za-z0-9_-]+))*\s*="#
    )

    /// Decides line by line whether a block reads as metadata.
    nonisolated private struct Validator {
        let syntax: Syntax
        /// Whether a key (or a TOML table) has been seen; a block of only
        /// blank lines and comments isn't front matter.
        private(set) var sawEntry = false
        /// Whether the line is inside a TOML multi-line string.
        private var inMultilineString = false

        init(syntax: Syntax) {
            self.syntax = syntax
        }

        mutating func accepts(_ line: String) -> Bool {
            if syntax == .toml, inMultilineString {
                inMultilineString = !Self.togglesMultilineString(line)
                return true
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Blank lines, comments, and indented lines (nested values,
            // continuations, block scalars) belong to whatever came before.
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return true }
            if line.first?.isWhitespace == true { return true }
            switch syntax {
            case .yaml:
                // A sequence item at the top level (`tags:` then `- a`).
                if line == "-" || line.hasPrefix("- ") { return true }
                guard MarkdownFrontMatter.matches(MarkdownFrontMatter.yamlKey, line) else { return false }
            case .toml:
                if line.hasPrefix("[") {
                    sawEntry = true
                    return true
                }
                // The end of a multi-line array.
                if trimmed.hasPrefix("]") { return true }
                guard MarkdownFrontMatter.matches(MarkdownFrontMatter.tomlKey, line) else { return false }
                inMultilineString = Self.togglesMultilineString(line)
            }
            sawEntry = true
            return true
        }

        /// Whether `line` holds an odd number of `"""` and `'''`, opening or
        /// closing a multi-line string.
        private static func togglesMultilineString(_ line: String) -> Bool {
            (line.components(separatedBy: "\"\"\"").count + line.components(separatedBy: "'''").count) % 2 == 1
        }
    }

    private static func matches(_ pattern: NSRegularExpression, _ line: String) -> Bool {
        pattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    // MARK: - Title

    nonisolated private static let yamlTitle = try! NSRegularExpression(
        pattern: #"^(?:title|"title"|'title')\s*:(.*)$"#, options: [.caseInsensitive]
    )
    nonisolated private static let tomlTitle = try! NSRegularExpression(
        pattern: #"^(?:title|"title"|'title')\s*=(.*)$"#, options: [.caseInsensitive]
    )

    /// The value of the top-level `title` key, on one line; nil when there's
    /// none, it's empty, or it isn't a string.
    private static func title(in lines: [String], syntax: Syntax) -> String? {
        let pattern = syntax == .yaml ? yamlTitle : tomlTitle
        for (index, line) in lines.enumerated() {
            // TOML keys after a `[table]` header belong to that table.
            if syntax == .toml, line.hasPrefix("[") { return nil }
            let source = line as NSString
            guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) else {
                continue
            }
            let value = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            // Indented lines after the key continue its value.
            let continuation = lines[(index + 1)...]
                .prefix { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.first?.isWhitespace == true }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let title = syntax == .yaml
                ? yamlString(value, continuation: Array(continuation))
                : tomlString(value)
            guard let title else { return nil }
            let collapsed = MarkdownTextExtractor.collapsingWhitespace(title)
            return collapsed.isEmpty ? nil : collapsed
        }
        return nil
    }

    /// A YAML scalar: plain, single- or double-quoted, or a block scalar
    /// (`|` or `>`, folded onto one line). Nil for a sequence, mapping,
    /// alias, or anything else that isn't a string.
    private static func yamlString(_ value: String, continuation: [String]) -> String? {
        let more = continuation.filter { !$0.isEmpty }
        guard let first = value.first else {
            // `title:` with the value on the indented lines below.
            return more.isEmpty ? nil : more.joined(separator: " ")
        }
        switch first {
        case "|", ">":
            return more.joined(separator: " ")
        case "\"":
            return doubleQuoted(([value] + more).joined(separator: " "))
        case "'":
            return singleQuoted(([value] + more).joined(separator: " "))
        case "[", "{", "&", "*", "!":
            return nil
        default:
            // A comment starts at ` #`.
            let plain = value.range(of: " #").map { String(value[..<$0.lowerBound]) } ?? value
            return ([plain] + more).joined(separator: " ")
        }
    }

    /// A TOML basic (`"…"`) or literal (`'…'`) string on one line.
    private static func tomlString(_ value: String) -> String? {
        if value.hasPrefix("\"\"\"") || value.hasPrefix("'''") { return nil }
        if value.hasPrefix("\"") { return doubleQuoted(value) }
        if value.hasPrefix("'") { return singleQuoted(value, doubledQuoteEscapes: false) }
        return nil
    }

    /// The text of a double-quoted string that opens `value`, with its
    /// common escapes resolved; nil if it never closes.
    private static func doubleQuoted(_ value: String) -> String? {
        var result = ""
        var escaped = false
        for character in value.dropFirst() {
            if escaped {
                switch character {
                case "n", "t", "r": result.append(" ")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return result
            } else {
                result.append(character)
            }
        }
        return nil
    }

    /// The text of a single-quoted string that opens `value`. YAML writes a
    /// quote inside one as `''`; TOML's literal strings can't hold one.
    private static func singleQuoted(_ value: String, doubledQuoteEscapes: Bool = true) -> String? {
        var result = ""
        var characters = value.dropFirst()[...]
        while let character = characters.popFirst() {
            guard character == "'" else {
                result.append(character)
                continue
            }
            if doubledQuoteEscapes, characters.first == "'" {
                characters.removeFirst()
                result.append("'")
            } else {
                return result
            }
        }
        return nil
    }

    // MARK: - Lines

    private static func trimmingTrailingWhitespace(_ line: String) -> String {
        var line = Substring(line)
        while line.last?.isWhitespace == true { line.removeLast() }
        return String(line)
    }

    /// The lines of a text, split at `\n` and without a trailing `\r`, read
    /// by Unicode scalar so a `\r\n` pair splits like any line end.
    nonisolated private struct Lines {
        private let scalars: Substring.UnicodeScalarView
        private var position: Substring.UnicodeScalarView.Index

        init(_ scalars: Substring.UnicodeScalarView) {
            self.scalars = scalars
            self.position = scalars.startIndex
        }

        /// What follows the lines read so far.
        var rest: String { String(Substring(scalars[position...])) }

        mutating func next() -> String? {
            guard position < scalars.endIndex else { return nil }
            let end = scalars[position...].firstIndex(of: "\n") ?? scalars.endIndex
            var line = scalars[position..<end]
            if line.last == "\r" { line = line.dropLast() }
            position = end < scalars.endIndex ? scalars.index(after: end) : end
            return String(Substring(line))
        }
    }
}
