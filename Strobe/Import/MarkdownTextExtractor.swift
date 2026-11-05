import Foundation
internal import Markdown

/// Converts Markdown's syntax tree to readable blocks before tokenization.
/// No source syntax is stripped heuristically: unmatched delimiters remain
/// literal text according to CommonMark. Code blocks and raw HTML blocks
/// are omitted; images contribute their alt text, never their destination.
nonisolated enum MarkdownTextExtractor {
    static func extractBlocks(from text: String) throws -> [String] {
        try Task.checkCancellation()
        let document = Markdown.Document(parsing: text, options: [.disableSmartOpts])
        try Task.checkCancellation()
        var walker = ReadableBlocks()
        walker.visit(document)
        try Task.checkCancellation()
        return walker.blocks
    }

    static func extractWords(from text: String) throws -> [String] {
        var words: [String] = []
        for block in try extractBlocks(from: text) {
            try Task.checkCancellation()
            // Tokenize blocks independently: neither a trailing hyphen nor
            // a number unit may join words across a paragraph or heading.
            words.append(contentsOf: Tokenizer.tokenize(block))
        }
        return words
    }

    private struct ReadableBlocks: MarkupWalker {
        var blocks: [String] = []

        mutating func visitParagraph(_ paragraph: Paragraph) { append(paragraph) }
        mutating func visitHeading(_ heading: Heading) { append(heading) }
        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {}
        mutating func visitHTMLBlock(_ html: HTMLBlock) {}

        mutating func visitTableHead(_ tableHead: Table.Head) { appendRow(tableHead) }
        mutating func visitTableRow(_ tableRow: Table.Row) { appendRow(tableRow) }

        private mutating func append(_ markup: any Markup) {
            var reader = ReadableInline()
            let text = reader.visit(markup).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(text) }
        }

        private mutating func appendRow(_ markup: any Markup) {
            // Cells are separate blocks so adjacent numbers and era labels
            // cannot accidentally become one RSVP token across a cell edge.
            for cell in markup.children { append(cell) }
        }
    }

    private struct ReadableInline: MarkupVisitor {
        mutating func defaultVisit(_ markup: any Markup) -> String {
            markup.children.map { visit($0) }.joined()
        }

        mutating func visitText(_ text: Markdown.Text) -> String { text.string }
        mutating func visitInlineCode(_ inlineCode: InlineCode) -> String { inlineCode.code }
        mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String { " " }
        mutating func visitLineBreak(_ lineBreak: LineBreak) -> String { "\n" }
        mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String { "" }
    }
}
