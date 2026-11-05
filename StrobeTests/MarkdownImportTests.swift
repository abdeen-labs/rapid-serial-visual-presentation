import Foundation
import Testing
internal import UniformTypeIdentifiers
@testable import Strobe

struct MarkdownImportTests {
    @Test(arguments: ["md", "markdown", "MD", "MARKDOWN"])
    func detectsMarkdownBeforeGenericPlainText(_ ext: String) {
        let url = URL(fileURLWithPath: "/tmp/notes.\(ext)")
        #expect(DocumentImportPipeline.resolveSourceType(for: url) == .markdown)
        #expect(DocumentImportPipeline.resolveSourceType(for: url, detectedContentType: .plainText) == .markdown)
        #expect(DocumentImportPipeline.resolveSourceType(for: url, detectedContentType: UTType(filenameExtension: ext)) == .markdown)
    }

    @Test func extractsNestedReadableContent() throws {
        let source = """
        #### Implementation **Plan**

        Read **bold and *nested italic***, __strong__, _emphasis_, and ~~old~~ text.
        Visit [the **guide**](https://example.com "Title") and [reference][ref].

        - First `inline code`
          - Nested item
        1. Ordered item
        2. Another item

        > A **quoted** paragraph.
        >
        > Another quote.

        ![A descriptive image](figure.png) ![](decorative.png)

        [ref]: https://example.org
        """
        #expect(try MarkdownTextExtractor.extractBlocks(from: source) == [
            "Implementation Plan",
            "Read bold and nested italic, strong, emphasis, and old text. Visit the guide and reference.",
            "First inline code", "Nested item", "Ordered item", "Another item",
            "A quoted paragraph.", "Another quote.", "A descriptive image"
        ])
    }

    @Test(arguments: 1...6)
    func stripsAllATXHeadingLevels(_ level: Int) throws {
        let marker = String(repeating: "#", count: level)
        #expect(try MarkdownTextExtractor.extractWords(from: "\(marker) Implementation Plan \(marker)") == [
            "Implementation", "Plan"
        ])
    }

    @Test func retainsTaskContentAndAutolinks() throws {
        #expect(try MarkdownTextExtractor.extractBlocks(from: """
        - [x] Finished **task**
        - [ ] Open task

        Contact <reader@example.com> or <https://example.com>.
        """) == ["Finished task", "Open task", "Contact reader@example.com or https://example.com."])
    }

    @Test func preservesHeadingParagraphAndLineBreaks() throws {
        #expect(try MarkdownTextExtractor.extractBlocks(from: """
        Setext heading
        ==============

        One soft
        line and a hard\\
        break.

        ## Next
        Paragraph.
        """) == ["Setext heading", "One soft line and a hard\nbreak.", "Next", "Paragraph."])
    }

    @Test func skipsFencedIndentedAndUnclosedCodeBlocks() throws {
        #expect(try MarkdownTextExtractor.extractBlocks(from: """
        Before.

        ```swift
        print("do not narrate")
        ```

        ~~~
        hidden too
        ~~~

            indented code

        After `readable code`.

        ```
        unclosed code to end of file
        """) == ["Before.", "After readable code."])
    }

    @Test func extractsTableCellsWithoutSeparatorsOrLostNumbers() throws {
        let source = """
        | **Era** | Count | Note |
        | :--- | ---: | --- |
        | BC | 44 | [guide](https://example.com) |
        | AD | 79 | `code` |
        """
        #expect(try MarkdownTextExtractor.extractBlocks(from: source) == [
            "Era", "Count", "Note", "BC", "44", "guide", "AD", "79", "code"
        ])
        #expect(try MarkdownTextExtractor.extractWords(from: source) == [
            "Era", "Count", "Note", "BC", "44", "guide", "AD", "79", "code"
        ])
    }

    @Test func preservesLiteralAndMalformedMarkdown() throws {
        #expect(try MarkdownTextExtractor.extractBlocks(from: """
        Unmatched *emphasis and [broken](link

        \\# literal hash and \\*literal stars\\* &amp; entities.

        C# and snake_case stay literal.
        """) == [
            "Unmatched *emphasis and [broken](link",
            "# literal hash and *literal stars* & entities.",
            "C# and snake_case stay literal."
        ])
    }

    @Test func omitsHTMLAndThematicBreaks() throws {
        #expect(try MarkdownTextExtractor.extractBlocks(from: """
        Read <em>this</em> text.

        <!-- hidden comment -->

        <script>hidden script</script>

        ---

        End.
        """) == ["Read this text.", "End."])
    }

    @Test func doesNotJoinWordsAcrossBlocks() throws {
        #expect(try MarkdownTextExtractor.extractWords(from: """
        ## AD

        79 arrived.

        ## informa-

        tion follows.
        """) == ["AD", "79", "arrived.", "informa-", "tion", "follows."])
        #expect(try MarkdownTextExtractor.extractWords(from: "In AD 79 and 2000 BCE.") == [
            "In", "AD 79", "and", "2000 BCE."
        ])
    }

    @Test(arguments: [TextCleaningLevel.none, .standard])
    func markdownImportFeedsDisplayAndSpeechTheSameWords(_ level: TextCleaningLevel) throws {
        let result = try importFile("#### Implementation **Plan**\n\nRead [the guide](https://example.com).", ext: "md", level: level)
        #expect(result.sourceType == .markdown)
        #expect(result.words == ["Implementation", "Plan", "Read", "the", "guide."])
        #expect(result.complexityScores.count == result.words.count)
        #expect(result.chapters.isEmpty)
        #expect(result.title == nil)
        let stored = WordStorage.encode(result.words)
        #expect(WordStorage.decode(stored) == result.words)
        let script = SpeechScript(words: result.words, range: result.words.indices)
        #expect(script.words == result.words)
        #expect(script.text == "Implementation Plan Read the guide.")
    }

    @Test(arguments: [TextCleaningLevel.none, .standard])
    func plainTextKeepsItsExistingBehavior(_ level: TextCleaningLevel) throws {
        let source = "#### Implementation **Plan**\n\n[the guide](https://example.com)\n\n42\nNext"
        let result = try importFile(source, ext: "txt", level: level)
        #expect(result.sourceType == .plainText)
        #expect(result.words == Tokenizer.tokenize(TextCleaner.cleanText(source, level: level)))
        #expect(result.words.contains("**Plan**"))
        #expect(result.words.contains("guide](https://example.com)"))
    }

    @Test func standardMarkdownImportKeepsNumericAndNavigationContent() throws {
        let result = try importFile("# Next\n\n42\n\n| A | B | C |\n| --- | --- | --- |\n| 1 | 2 | 3 |", ext: "markdown")
        #expect(result.words == ["Next", "42", "A", "B", "C", "1", "2", "3"])
    }

    @Test(arguments: ["", "```swift\nlet hidden = true\n```", "---\n\n![](image.png)"])
    func nonReadableMarkdownProducesNoWords(_ source: String) throws {
        #expect(try importFile(source, ext: "md").words.isEmpty)
    }

    private func importFile(_ text: String, ext: String, level: TextCleaningLevel = .standard) throws -> ImportResult {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("strobe_\(UUID().uuidString).\(ext)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DocumentImportPipeline.extractWordsAndChapters(from: url, detectedContentType: .plainText, cleaningLevel: level)
    }
}
