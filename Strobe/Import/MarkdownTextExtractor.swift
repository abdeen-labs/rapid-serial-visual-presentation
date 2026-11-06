import Foundation
internal import cmark_gfm
internal import cmark_gfm_extensions

/// The words, chapters, and title read from a Markdown document.
nonisolated struct MarkdownExtractionResult {
    let words: [String]
    let chapters: [Chapter]
    let title: String?
    /// The last word of each block, a table cell's as a cell.
    var blockEnds: BlockEnds = .none
}

/// Reads a Markdown document as the prose it renders to.
///
/// cmark-gfm parses the document (CommonMark with GitHub's tables,
/// strikethrough, task lists, and footnotes), and the reader walks the tree
/// with cmark's own iterator, never recursing, so no nesting depth can run
/// the stack out. Each paragraph, heading, list item, and table cell is
/// tokenized on its own, so neither a hyphen fragment nor a number unit joins
/// words across a block. Every heading is a chapter, as an EPUB's are.
///
/// What's read:
/// - Emphasis, strong, strikethrough (`~~`), and links read as their text;
///   images and inline `<img>` tags as their alt text; inline code as its
///   code.
/// - An ordered list item keeps its number as the list renders it: the
///   list's start plus the item's place, with its delimiter (`3.`, `2)`).
/// - Footnote references drop out of the sentence, and the notes they point
///   to read at the end, in order, as cmark places them.
/// - Obsidian wiki links read as their alias or their target
///   (`[[Note|alias]]`, `[[Note#Section]]`); embeds (`![[file]]`) drop out.
/// - An HTML block reads as the text it shows, through ``EPUBContent``, with
///   its headings as headings; comments, scripts, styles, tables, and
///   images drop out.
/// - Front matter (``MarkdownFrontMatter``) is taken off before parsing and
///   gives the title.
///
/// What's skipped: fenced and indented code blocks, thematic breaks, task
/// list checkboxes, link destinations, and link reference definitions.
/// Unmatched or escaped markers stay literal, as CommonMark has them, except
/// escaped wiki-link brackets (`\[\[Note\]\]`): CommonMark resolves the
/// escapes first, so they read as a link.
///
/// A document indented past ``maximumIndentColumns`` on some line reads as
/// plain text instead (see ``isSafelyNested(_:)``).
nonisolated enum MarkdownTextExtractor {

    /// A run of text read on its own: a paragraph, heading, table cell, or a
    /// block of an HTML block, on one line with its whitespace collapsed.
    nonisolated struct Block: Equatable, Sendable {
        var text: String
        /// The heading's level, 1 to 6; nil for a block that isn't a heading.
        var headingLevel: Int?
        /// Whether the block is a table cell, which pauses like a clause
        /// mark rather than a sentence end.
        var isTableCell = false
        /// Whether the block is the first cell of a table with text.
        var startsTable = false

        init(_ text: String, headingLevel: Int? = nil, isTableCell: Bool = false, startsTable: Bool = false) {
            self.text = text
            self.headingLevel = headingLevel
            self.isTableCell = isTableCell
            self.startsTable = startsTable
        }
    }

    /// How many bytes cmark takes between cancellation checks.
    private static let feedChunkSize = 1 << 20

    /// How many tree events the reader handles between cancellation checks.
    private static let eventsPerCancellationCheck = 4096

    /// The document's words, a chapter at each heading that has words, and
    /// its title: the front matter's, or else the document's only level-1
    /// heading when it comes first.
    static func extractWordsAndChapters(from text: String) throws -> MarkdownExtractionResult {
        let source = MarkdownFrontMatter.split(text)
        guard isSafelyNested(source.body) else {
            try Task.checkCancellation()
            let plain = PlainTextParagraphs.tokenize(source.body)
            return MarkdownExtractionResult(
                words: plain.words, chapters: [], title: source.title, blockEnds: plain.blockEnds
            )
        }
        var words: [String] = []
        var chapters: [Chapter] = []
        var blockEnds = BlockEnds()
        var firstBlock: Block?
        var levelOneHeadings = 0
        // A table's last cell ends a block, not just a cell: it's known once
        // something other than that table's cells follows.
        var lastCellEnd: Int?

        try forEachBlock(in: source.body) { block in
            let start = words.count
            words.append(contentsOf: Tokenizer.tokenize(block.text))
            guard words.count > start else { return }
            if let cell = lastCellEnd, !block.isTableCell || block.startsTable {
                blockEnds.mark(cell, as: .block)
            }
            lastCellEnd = block.isTableCell ? words.count - 1 : nil
            blockEnds.mark(words.count - 1, as: block.isTableCell ? .cell : .block)
            if firstBlock == nil { firstBlock = block }
            guard let level = block.headingLevel else { return }
            if level == 1 { levelOneHeadings += 1 }
            chapters.append(Chapter(title: collapsingWhitespace(block.text), wordIndex: start))
        }

        if let cell = lastCellEnd { blockEnds.mark(cell, as: .block) }

        let headingTitle = firstBlock.flatMap { block in
            block.headingLevel == 1 && levelOneHeadings == 1 ? collapsingWhitespace(block.text) : nil
        }
        return MarkdownExtractionResult(
            words: words, chapters: chapters, title: source.title ?? headingTitle, blockEnds: blockEnds
        )
    }

    /// The document's blocks, in reading order, without its front matter.
    static func extractBlocks(from text: String) throws -> [Block] {
        let body = MarkdownFrontMatter.split(text).body
        guard isSafelyNested(body) else { return [Block(collapsingWhitespace(body))] }
        var blocks: [Block] = []
        try forEachBlock(in: body) { blocks.append($0) }
        return blocks
    }

    /// The deepest leading indentation, in columns (a tab reaches the next
    /// multiple of 4), that a document read as Markdown may have.
    static let maximumIndentColumns = 4_000

    /// Whether no line's leading indentation passes ``maximumIndentColumns``.
    ///
    /// The reader never recurses, but cmark has one recursive function: it
    /// checks whether a list ends in a blank line by descending through each
    /// nested list's last item. Each list level nested past the first line
    /// needs about two more columns of indentation, and cmark opens at most
    /// 100 levels on one line, so this bound keeps that descent near 2,100
    /// calls, safe on any thread's stack even in an unoptimized build. Real
    /// documents never come near it; one that does was made to.
    static func isSafelyNested(_ text: String) -> Bool {
        var column = 0
        var atLineStart = true
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                column = 0
                atLineStart = true
            case UInt8(ascii: " ") where atLineStart:
                column += 1
            case UInt8(ascii: "\t") where atLineStart:
                column += 4 - column % 4
            default:
                atLineStart = false
            }
            if column > maximumIndentColumns { return false }
        }
        return true
    }

    /// `text` on one line, its runs of whitespace as single spaces.
    static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Parsing

    /// Parses `markdown` and hands `body` each block that has text, in order.
    ///
    /// The document goes to cmark a chunk at a time (cmark carries a line
    /// split between chunks), with a cancellation check between chunks and
    /// every few thousand tree events. Finishing the parse, which runs the
    /// inline pass over the whole document, is the one step that can't stop
    /// partway; it takes time in proportion to the document's length.
    private static func forEachBlock(in markdown: String, _ body: (Block) throws -> Void) throws {
        try Task.checkCancellation()
        cmark_gfm_core_extensions_ensure_registered()
        // Strikethrough takes `~~` only, so a lone tilde (`~5 to ~10`)
        // stays in the text, where the voice reads it as "about".
        let parser = cmark_parser_new(CMARK_OPT_FOOTNOTES | CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE)
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist"] {
            if let syntax = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, syntax)
            }
        }

        var source = markdown
        try source.withUTF8 { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let length = min(feedChunkSize, bytes.count - offset)
                (base + offset).withMemoryRebound(to: CChar.self, capacity: length) { chunk in
                    cmark_parser_feed(parser, chunk, length)
                }
                offset += length
            }
        }
        try Task.checkCancellation()

        // Finishing also joins adjacent text nodes, so the brackets of a wiki
        // link that matched nothing arrive as one string.
        guard let document = cmark_parser_finish(parser) else { return }
        defer { cmark_node_free(document) }
        try Task.checkCancellation()

        guard let iterator = cmark_iter_new(document) else { return }
        defer { cmark_iter_free(iterator) }
        var reader = BlockReader()
        var events = 0
        while true {
            let event = cmark_iter_next(iterator)
            guard event != CMARK_EVENT_DONE else { break }
            events += 1
            if events % eventsPerCancellationCheck == 0 { try Task.checkCancellation() }
            guard let node = cmark_iter_get_node(iterator) else { continue }
            try reader.read(node, entering: event == CMARK_EVENT_ENTER, emit: body)
        }
    }

    /// Turns cmark's enter and exit events into blocks.
    ///
    /// Paragraphs, headings, and table cells hold all of a document's inline
    /// content, and none of them nests inside another, so one open block at
    /// a time is enough.
    nonisolated private struct BlockReader {
        /// The text of the open paragraph, heading, or table cell; nil
        /// between them.
        private var text: String?
        private var headingLevel: Int?
        private var isTableCell = false
        /// Whether the next table cell with text is its table's first.
        private var tableStartPending = false
        private var startsTable = false
        /// The list labels the open block starts with.
        private var label = ""
        /// The lists the reader is inside, innermost last: an ordered list's
        /// next item number and delimiter, or nil for a bullet list.
        private var lists: [(next: Int, delimiter: String)?] = []
        /// Labels of ordered list items (`1.`, `2)`) waiting for their item's
        /// first block. An item that opens with a nested ordered list labels
        /// that first block with both numbers.
        private var pendingLabels: [String] = []

        mutating func read(
            _ node: UnsafeMutablePointer<cmark_node>,
            entering: Bool,
            emit: (Block) throws -> Void
        ) throws {
            switch cmark_node_get_type(node) {
            case CMARK_NODE_PARAGRAPH:
                if entering { open() } else { try close(emit) }
            case CMARK_NODE_HEADING:
                if entering { open(headingLevel: Int(cmark_node_get_heading_level(node))) } else { try close(emit) }
            case CMARK_NODE_LIST:
                if entering {
                    let ordered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
                    let delimiter = cmark_node_get_list_delim(node) == CMARK_PAREN_DELIM ? ")" : "."
                    lists.append(ordered ? (next: Int(cmark_node_get_list_start(node)), delimiter: delimiter) : nil)
                } else if !lists.isEmpty {
                    lists.removeLast()
                }
            case CMARK_NODE_ITEM:
                if entering {
                    if let last = lists.indices.last, let ordered = lists[last] {
                        pendingLabels.append("\(ordered.next)\(ordered.delimiter)")
                        lists[last] = (next: ordered.next + 1, delimiter: ordered.delimiter)
                    }
                } else {
                    // An item with no text drops its label.
                    pendingLabels.removeAll()
                }
            case CMARK_NODE_HTML_BLOCK:
                for block in MarkdownHTML.blocks(in: Self.literal(of: node)) {
                    try emit(Block(takeLabel() + block.text, headingLevel: block.headingLevel))
                }
            case CMARK_NODE_TEXT:
                append(MarkdownWikiLinks.replacing(in: Self.literal(of: node)))
            case CMARK_NODE_CODE:
                append(Self.literal(of: node))
            case CMARK_NODE_SOFTBREAK, CMARK_NODE_LINEBREAK:
                append(" ")
            case CMARK_NODE_HTML_INLINE:
                append(MarkdownHTML.inlineText(Self.literal(of: node)))
            case CMARK_NODE_IMAGE:
                // Alt text is its own words, even between two adjacent images
                // (a row of badges) or straight after a word.
                append(" ")
            case CMARK_NODE_DOCUMENT, CMARK_NODE_BLOCK_QUOTE, CMARK_NODE_CODE_BLOCK,
                 CMARK_NODE_THEMATIC_BREAK, CMARK_NODE_FOOTNOTE_DEFINITION,
                 CMARK_NODE_FOOTNOTE_REFERENCE, CMARK_NODE_EMPH, CMARK_NODE_STRONG,
                 CMARK_NODE_LINK, CMARK_NODE_ATTRIBUTE:
                // Containers whose children are read, or leaves that aren't.
                break
            default:
                // Extension nodes have types cmark numbers at run time, so
                // they're told apart by name. Of them only table cells hold
                // text of their own; strikethrough's children are read
                // through it, and tables and rows just contain cells.
                let typeName = cmark_node_get_type_string(node)
                if strcmp(typeName, "table_cell") == 0 {
                    if entering { open(isTableCell: true) } else { try close(emit) }
                } else if entering, strcmp(typeName, "table") == 0 {
                    tableStartPending = true
                }
            }
        }

        private mutating func open(headingLevel: Int? = nil, isTableCell: Bool = false) {
            label = takeLabel()
            text = ""
            self.headingLevel = headingLevel
            self.isTableCell = isTableCell
            startsTable = isTableCell && tableStartPending
        }

        private mutating func close(_ emit: (Block) throws -> Void) throws {
            defer {
                text = nil
                headingLevel = nil
                isTableCell = false
                startsTable = false
                label = ""
            }
            guard let text else { return }
            let collapsed = MarkdownTextExtractor.collapsingWhitespace(text)
            guard !collapsed.isEmpty else { return }
            if startsTable { tableStartPending = false }
            try emit(Block(label + collapsed, headingLevel: headingLevel, isTableCell: isTableCell, startsTable: startsTable))
        }

        private mutating func append(_ string: String) {
            text?.append(string)
        }

        /// The waiting list labels as a prefix, `1. ` or `2. 1. `, or empty.
        private mutating func takeLabel() -> String {
            guard !pendingLabels.isEmpty else { return "" }
            defer { pendingLabels.removeAll() }
            return pendingLabels.joined(separator: " ") + " "
        }

        private static func literal(of node: UnsafeMutablePointer<cmark_node>) -> String {
            guard let literal = cmark_node_get_literal(node) else { return "" }
            return String(cString: literal)
        }
    }
}

// MARK: - Wiki links

/// Obsidian's `[[links]]`, which CommonMark leaves as literal brackets.
nonisolated enum MarkdownWikiLinks {

    nonisolated private static let pattern = try! NSRegularExpression(
        pattern: #"(!?)\[\[([^\[\]\n]+)\]\]"#
    )

    /// `text` with each wiki link as the words it shows: its alias
    /// (`[[Note|the note]]`), or else its target with any heading
    /// (`[[Note#Setup]]` reads `Note Setup`) and without a block reference
    /// (`#^abc123`). An embed (`![[diagram.png]]`) drops out.
    static func replacing(in text: String) -> String {
        guard text.contains("[[") else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = NSMaxRange(match.range)
            guard match.range(at: 1).length == 0 else { continue }
            result += shownText(source.substring(with: match.range(at: 2)))
        }
        result += source.substring(from: cursor)
        return result
    }

    private static func shownText(_ link: String) -> String {
        let parts = link.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let alias = parts[1].trimmingCharacters(in: .whitespaces)
            if !alias.isEmpty { return alias }
        }
        return parts[0].split(separator: "#")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("^") }
            .joined(separator: " ")
    }
}

// MARK: - HTML

/// The text that raw HTML in a Markdown document shows.
nonisolated enum MarkdownHTML {

    /// Tags that end a line of text wherever they stand.
    nonisolated private static let breakingTags: Set<String> = [
        "br", "hr", "p", "div", "li", "tr", "td", "th", "blockquote", "section", "article",
        "h1", "h2", "h3", "h4", "h5", "h6"
    ]
    nonisolated private static let altPattern = try! NSRegularExpression(
        pattern: #"(?:^|\s)alt\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#,
        options: [.caseInsensitive]
    )

    /// An HTML block's blocks of text: one for each paragraph, heading, list
    /// item, or other block element, with headings marked by level. Read by
    /// ``EPUBContent``, so comments, scripts, styles, tables, navigation, and
    /// images (alt text included) drop out, as they do in an EPUB.
    static func blocks(in html: String) -> [MarkdownTextExtractor.Block] {
        let content = EPUBContent.parse(Data(html.utf8))
        let text = content.text as NSString
        let bounds = Set([0, text.length] + content.blockBreaks.filter { $0 <= text.length }).sorted()
        // A heading counts only when it has text, so its level goes to the
        // first segment with text from where it starts: an `<h1>` that opens
        // with an image and a `<br>` still heads the name after them.
        var headings = content.headings.sorted { $0.offset < $1.offset }[...]
        var blocks: [MarkdownTextExtractor.Block] = []
        for (start, end) in zip(bounds, bounds.dropFirst()) {
            let segment = MarkdownTextExtractor.collapsingWhitespace(
                text.substring(with: NSRange(location: start, length: end - start))
            )
            guard !segment.isEmpty else { continue }
            var level: Int?
            while let heading = headings.first, heading.offset < end {
                level = level ?? heading.level
                headings.removeFirst()
            }
            blocks.append(.init(segment, headingLevel: level))
        }
        return blocks
    }

    /// What one inline HTML tag adds to a sentence: an `<img>`'s alt text as
    /// words of its own, a space for a tag that breaks the line (`<br>`), and
    /// nothing for any other tag, comment, or declaration.
    static func inlineText(_ tag: String) -> String {
        guard tag.hasPrefix("<") else { return "" }
        let body = tag.dropFirst()
        guard let first = body.first, first != "!", first != "?" else { return "" }
        let name = body.drop { $0 == "/" }
            .prefix { $0.isASCII && ($0.isLetter || $0.isNumber) }
            .lowercased()
        if name == "img" {
            guard let alt = attribute(in: tag) else { return " " }
            return " " + EPUBTextExtractor.resolveHTMLEntities(alt) + " "
        }
        return breakingTags.contains(name) ? " " : ""
    }

    private static func attribute(in tag: String) -> String? {
        let source = tag as NSString
        guard let match = altPattern.firstMatch(in: tag, range: NSRange(location: 0, length: source.length)) else {
            return nil
        }
        for group in 1...3 where match.range(at: group).location != NSNotFound {
            return source.substring(with: match.range(at: group))
        }
        return nil
    }
}
