import Foundation
import Testing
internal import UniformTypeIdentifiers
@testable import Strobe

struct MarkdownImportTests {

    private typealias Block = MarkdownTextExtractor.Block

    // MARK: - Detection

    @Test(arguments: ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "MD", "Markdown"])
    func detectsMarkdownByExtension(_ ext: String) {
        let url = URL(fileURLWithPath: "/tmp/notes.\(ext)")
        #expect(DocumentImportPipeline.resolveSourceType(for: url) == .markdown)
        #expect(DocumentImportPipeline.resolveSourceType(for: url, detectedContentType: .plainText) == .markdown)
        #expect(DocumentImportPipeline.resolveSourceType(
            for: url, detectedContentType: DocumentImportPipeline.markdownType
        ) == .markdown)
    }

    @Test func detectsMarkdownByContentTypeWithoutAnExtension() {
        let readme = URL(fileURLWithPath: "/tmp/README")
        #expect(DocumentImportPipeline.resolveSourceType(
            for: readme, detectedContentType: DocumentImportPipeline.markdownType
        ) == .markdown)
        #expect(DocumentImportPipeline.resolveSourceType(for: readme, detectedContentType: .plainText) == .plainText)
        #expect(DocumentImportPipeline.resolveSourceType(
            for: URL(fileURLWithPath: "/tmp/notes.txt"), detectedContentType: .plainText
        ) == .plainText)
    }

    @Test func pickerAndDropsTakeMarkdownAsText() {
        #expect(DocumentImportPipeline.markdownType.conforms(to: .plainText))
        #expect(DocumentImportPipeline.supportedContentTypes.contains(DocumentImportPipeline.markdownType))
        #expect(Set(DocumentImportPipeline.supportedContentTypes).count == DocumentImportPipeline.supportedContentTypes.count)
    }

    @Test func markdownFileNamesTitleAndMatchLikeTextFiles() {
        #expect(DocumentImportPipeline.resolveTitle(metadataTitle: nil, fileName: "release-notes.mdown") == "Release Notes")
        #expect(DocumentImportPipeline.resolveTitle(metadataTitle: nil, fileName: "guide.MD") == "Guide")
        #expect(LikelyDuplicates.fileNameKey("Notes.mkd") == "notes.mkd")
        #expect(LikelyDuplicates.fileNameKey("Notes.markdown") == "notes.markdown")
    }

    // MARK: - Inline content

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
            Block("Implementation Plan", headingLevel: 4),
            Block("Read bold and nested italic, strong, emphasis, and old text. Visit the guide and reference."),
            Block("First inline code"), Block("Nested item"),
            Block("1. Ordered item"), Block("2. Another item"),
            Block("A quoted paragraph."), Block("Another quote."),
            Block("A descriptive image"),
        ])
    }

    @Test(arguments: 1...6)
    func readsEveryATXHeadingLevel(_ level: Int) throws {
        let marker = String(repeating: "#", count: level)
        let result = try MarkdownTextExtractor.extractWordsAndChapters(from: "\(marker) Implementation Plan \(marker)")
        #expect(result.words == ["Implementation", "Plan"])
        #expect(result.chapters == [Chapter(title: "Implementation Plan", wordIndex: 0)])
        #expect(result.title == (level == 1 ? "Implementation Plan" : nil))
    }

    @Test func readsTaskListsAndAutolinks() throws {
        #expect(try MarkdownTextExtractor.extractBlocks(from: """
        - [x] Finished **task**
        - [ ] Open task

        Contact <reader@example.com> or <https://example.com>.
        """) == [Block("Finished task"), Block("Open task"), Block("Contact reader@example.com or https://example.com.")])
    }

    @Test func readsSetextHeadingsAndLineBreaksAsSpaces() throws {
        #expect(try MarkdownTextExtractor.extractBlocks(from: """
        Setext heading
        ==============

        One soft
        line and a hard\\
        break.

        Second level
        ------------
        Paragraph.
        """) == [
            Block("Setext heading", headingLevel: 1),
            Block("One soft line and a hard break."),
            Block("Second level", headingLevel: 2),
            Block("Paragraph."),
        ])
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
        """) == [Block("Before."), Block("After readable code.")])
    }

    @Test func readsTableCellsOneByOne() throws {
        let source = """
        | **Era** | Count | Note |
        | :--- | ---: | --- |
        | BC | 44 | [guide](https://example.com) |
        | AD | 79 | `code` |
        | a \\| b | 5 | either |
        """
        #expect(try MarkdownTextExtractor.extractBlocks(from: source).map(\.text) == [
            "Era", "Count", "Note", "BC", "44", "guide", "AD", "79", "code", "a | b", "5", "either"
        ])
        // Each cell is tokenized alone, so `BC` and `44` never join.
        let words = try MarkdownTextExtractor.extractWordsAndChapters(from: source).words
        #expect(Array(words.prefix(9)) == ["Era", "Count", "Note", "BC", "44", "guide", "AD", "79", "code"])
    }

    @Test func keepsLiteralAndMalformedMarkdown() throws {
        #expect(try MarkdownTextExtractor.extractBlocks(from: """
        Unmatched *emphasis and [broken](link

        \\# literal hash and \\*literal stars\\* &amp; entities.

        C# and snake_case stay literal.
        """) == [
            Block("Unmatched *emphasis and [broken](link"),
            Block("# literal hash and *literal stars* & entities."),
            Block("C# and snake_case stay literal."),
        ])
    }

    @Test func numbersOrderedListItemsAsTheListRenders() throws {
        #expect(try MarkdownTextExtractor.extractBlocks(from: """
        3. Third
        4. Fourth

        1) One
        2) Two

        1. Outer
           1. Inner

        - Bullets have no label

        7. - Nested bullet
        """).map(\.text) == [
            "3. Third", "4. Fourth", "1) One", "2) Two", "1. Outer", "1. Inner",
            "Bullets have no label", "7. Nested bullet",
        ])
    }

    @Test func onlyDoubleTildesStrikeThrough() throws {
        #expect(try MarkdownTextExtractor.extractBlocks(from: "About ~5 to ~10 minutes, ~~not~~ more.").map(\.text)
            == ["About ~5 to ~10 minutes, not more."])
    }

    @Test func imagesReadAsTheirOwnWords() throws {
        #expect(try MarkdownTextExtractor.extractBlocks(from: """
        [![Build](build.svg)](https://ci.example.com)[![License](license.svg)](LICENSE)

        A logo![Strobe](logo.png)here.
        """).map(\.text) == ["Build License", "A logo Strobe here."])
    }

    // MARK: - HTML

    @Test func readsInlineHTMLAsText() throws {
        // Punctuation after the alt text joins its last word, as anywhere.
        #expect(try MarkdownTextExtractor.extractWordsAndChapters(
            from: "Read <em>this</em> text, one<br>two, and <img src=\"logo.png\" alt=\"the logo\">."
        ).words == ["Read", "this", "text,", "one", "two,", "and", "the", "logo."])
        #expect(try MarkdownTextExtractor.extractBlocks(
            from: "Hidden<!-- an inline comment -->text and <IMG SRC='x.png' ALT='Tom &amp; Jerry'> too."
        ) == [Block("Hiddentext and Tom & Jerry too.")])
    }

    @Test func readsHTMLBlocksAsTheirText() throws {
        let source = """
        <h1 align="center">Strobe</h1>
        <p align="center">A speed reader.</p>

        <!-- hidden comment -->

        <script>hidden script</script>

        <details>
        <summary>More</summary>

        Hidden body.

        </details>

        ---

        End.
        """
        #expect(try MarkdownTextExtractor.extractBlocks(from: source) == [
            Block("Strobe", headingLevel: 1), Block("A speed reader."),
            Block("More"), Block("Hidden body."), Block("End."),
        ])
        let result = try MarkdownTextExtractor.extractWordsAndChapters(from: source)
        #expect(result.title == "Strobe")
        #expect(result.chapters == [Chapter(title: "Strobe", wordIndex: 0)])
    }

    @Test func anHTMLHeadingThatOpensWithAnImageStillHeads() throws {
        let result = try MarkdownTextExtractor.extractWordsAndChapters(from: """
        <h1 align="center">
          <img src="icon.png" width="128"><br>
          Strobe
        </h1>

        A speed reader.
        """)
        #expect(result.words == ["Strobe", "A", "speed", "reader."])
        #expect(result.chapters == [Chapter(title: "Strobe", wordIndex: 0)])
        #expect(result.title == "Strobe")
    }

    // MARK: - Front matter

    @Test func dropsYAMLFrontMatterAndTakesItsTitle() throws {
        let source = """
        ---
        title: "My Post: Part 2"
        date: 2024-05-01
        tags:
          - reading
        - notes
        draft: false # not yet
        ---

        # Heading

        Body text.
        """
        let result = try MarkdownTextExtractor.extractWordsAndChapters(from: source)
        #expect(result.words == ["Heading", "Body", "text."])
        #expect(result.chapters == [Chapter(title: "Heading", wordIndex: 0)])
        #expect(result.title == "My Post: Part 2")
    }

    @Test func dropsTOMLFrontMatterAndTakesItsTitle() throws {
        let result = try MarkdownTextExtractor.extractWordsAndChapters(from: """
        +++
        title = 'Notes'
        summary = \"\"\"
        Spans
        lines\"\"\"
        [params]
        author = "Ann"
        +++
        Body.
        """)
        #expect(result.words == ["Body."])
        #expect(result.title == "Notes")
    }

    @Test(arguments: [
        ("---\ntitle: >\n  A folded\n  title\n---\nText.", "A folded title"),
        ("---\ntitle: 'It''s here'\n---\nText.", "It's here"),
        ("---\ntitle: Plain title # a comment\n---\nText.", "Plain title"),
        ("---\ntitle: \"Escaped \\\"quote\\\"\"\n---\nText.", "Escaped \"quote\""),
        ("---\nauthor: Ann\n...\nText.", nil),
        ("---\ntitle: [a, b]\n---\nText.", nil),
        ("+++\n[params]\ntitle = \"In a table\"\n+++\nText.", nil),
        ("\u{FEFF}---\r\ntitle: Windows\r\n---\r\nText.\r\n", "Windows"),
    ] as [(String, String?)])
    func readsFrontMatterTitles(_ source: String, _ title: String?) throws {
        let result = try MarkdownTextExtractor.extractWordsAndChapters(from: source)
        #expect(result.words == ["Text."])
        #expect(result.title == title)
    }

    @Test func keepsAnOpeningRuleThatIsntFrontMatter() throws {
        #expect(try MarkdownTextExtractor.extractBlocks(from: """
        ---

        An opening paragraph without any keys.

        ---

        More.
        """).map(\.text) == ["An opening paragraph without any keys.", "More."])
        // Never closed.
        #expect(try MarkdownTextExtractor.extractBlocks(from: "---\ntitle: x\n\nText").map(\.text) == ["title: x", "Text"])
        // Front matter only opens a file.
        #expect(try MarkdownTextExtractor.extractBlocks(from: "Intro.\n\n---\ntitle: x\n---\n").map(\.text)
            == ["Intro.", "title: x"])
    }

    // MARK: - Footnotes and wiki links

    @Test func readsFootnotesAtTheEnd() throws {
        #expect(try MarkdownTextExtractor.extractBlocks(from: """
        A claim[^1] and another[^note].

        [^1]: First note.

        [^note]: Second note.

        [^unused]: Never referenced.

        An undefined [^x] stays.
        """).map(\.text) == ["A claim and another.", "An undefined [^x] stays.", "First note.", "Second note."])
    }

    @Test func readsWikiLinksAsTheirText() throws {
        #expect(try MarkdownTextExtractor.extractBlocks(from: """
        See [[Note]], [[Other note|the other one]], and [[Guide#Setup#^block1]]. ![[diagram.png]]

        `[[code stays]]`
        """).map(\.text) == ["See Note, the other one, and Guide Setup.", "[[code stays]]"])
    }

    // MARK: - Chapters and blocks

    @Test func headingsBecomeChaptersAndTheOnlyLevelOneHeadingTitlesTheDocument() throws {
        let result = try MarkdownTextExtractor.extractWordsAndChapters(from: """
        # Field Guide

        Intro.

        ## Birds

        Robins sing.

        ### Songbirds

        More.

        ## Trees

        Oaks.
        """)
        #expect(result.words == ["Field", "Guide", "Intro.", "Birds", "Robins", "sing.", "Songbirds", "More.", "Trees", "Oaks."])
        #expect(result.chapters == [
            Chapter(title: "Field Guide", wordIndex: 0),
            Chapter(title: "Birds", wordIndex: 3),
            Chapter(title: "Songbirds", wordIndex: 6),
            Chapter(title: "Trees", wordIndex: 8),
        ])
        #expect(result.title == "Field Guide")
    }

    @Test func titleNeedsOneLevelOneHeadingFirst() throws {
        let twoTopHeadings = try MarkdownTextExtractor.extractWordsAndChapters(from: "# One\n\nA.\n\n# Two\n\nB.")
        #expect(twoTopHeadings.title == nil)
        #expect(twoTopHeadings.chapters == [Chapter(title: "One", wordIndex: 0), Chapter(title: "Two", wordIndex: 2)])
        #expect(try MarkdownTextExtractor.extractWordsAndChapters(from: "Intro.\n\n# Title\n\nBody.").title == nil)
        // A heading with no words is no chapter.
        let imageHeading = try MarkdownTextExtractor.extractWordsAndChapters(from: "# ![](x.png)\n\nText.")
        #expect(imageHeading.chapters.isEmpty)
        #expect(imageHeading.title == nil)
    }

    @Test func doesNotJoinWordsAcrossBlocks() throws {
        let result = try MarkdownTextExtractor.extractWordsAndChapters(from: """
        ## AD

        79 arrived.

        ## informa-

        tion follows.
        """)
        #expect(result.words == ["AD", "79", "arrived.", "informa-", "tion", "follows."])
        #expect(result.chapters == [Chapter(title: "AD", wordIndex: 0), Chapter(title: "informa-", wordIndex: 3)])
        #expect(try MarkdownTextExtractor.extractWordsAndChapters(from: "In AD 79 and 2000 BCE.").words == [
            "In", "AD 79", "and", "2000 BCE."
        ])
    }

    // MARK: - Robustness

    @Test func deeplyNestedMarkdownReadsWithoutRecursing() throws {
        let depth = 20_000
        let quotes = String(repeating: "> ", count: depth) + "Deep quote."
        #expect(try MarkdownTextExtractor.extractBlocks(from: quotes) == [Block("Deep quote.")])

        let strong = String(repeating: "*", count: depth) + "deep" + String(repeating: "*", count: depth)
        #expect(try MarkdownTextExtractor.extractBlocks(from: strong) == [Block("deep")])

        let lists = (0..<2_000).map { String(repeating: "  ", count: $0) + "- item" }.joined(separator: "\n")
        #expect(try MarkdownTextExtractor.extractBlocks(from: lists).count == 2_000)
    }

    @Test(arguments: [
        String(repeating: " ", count: MarkdownTextExtractor.maximumIndentColumns + 1),
        String(repeating: "\t", count: MarkdownTextExtractor.maximumIndentColumns / 4 + 1),
    ])
    func readsPathologicallyIndentedDocumentsAsPlainText(_ indent: String) throws {
        let source = "# Title\n\n- item\n\(indent)deep"
        #expect(!MarkdownTextExtractor.isSafelyNested(source))
        let result = try MarkdownTextExtractor.extractWordsAndChapters(from: source)
        #expect(result.words == Tokenizer.tokenize(source))
        #expect(result.chapters.isEmpty)
        #expect(MarkdownTextExtractor.isSafelyNested(String(repeating: " ", count: MarkdownTextExtractor.maximumIndentColumns) + "x"))
    }

    @Test func feedsLongDocumentsInChunksWithoutSplittingText() throws {
        // cmark takes 1 MiB at a time. The padding puts that boundary
        // between the two bytes of `Ü`, inside a line.
        let padding = String(repeating: "x", count: (1 << 20) - 1)
        let source = "\(padding)Ü more text.\n\nSecond paragraph."
        #expect(try MarkdownTextExtractor.extractBlocks(from: source).map(\.text) == [
            "\(padding)Ü more text.", "Second paragraph."
        ])
    }

    @Test func cancellationStopsExtraction() async {
        let task = Task<Void, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try MarkdownTextExtractor.extractWordsAndChapters(from: "Some text.")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: - Import pipeline

    @Test(arguments: [TextCleaningLevel.none, .standard])
    func markdownImportGivesWordsChaptersAndTitle(_ level: TextCleaningLevel) throws {
        let result = try importFile("""
        ---
        title: Plan
        ---
        #### Implementation **Plan**

        Read [the guide](https://example.com).
        """, ext: "md", level: level)
        #expect(result.sourceType == .markdown)
        #expect(result.words == ["Implementation", "Plan", "Read", "the", "guide."])
        #expect(result.chapters == [Chapter(title: "Implementation Plan", wordIndex: 0)])
        #expect(result.title == "Plan")
        #expect(result.complexityScores.count == result.words.count)
        let script = SpeechScript(words: result.words, range: result.words.indices)
        #expect(script.words == result.words)
    }

    @Test(arguments: [TextCleaningLevel.none, .standard])
    func plainTextKeepsItsExistingBehavior(_ level: TextCleaningLevel) throws {
        let source = "#### Implementation **Plan**\n\n[the guide](https://example.com)\n\n42\nNext"
        let result = try importFile(source, ext: "txt", level: level)
        #expect(result.sourceType == .plainText)
        #expect(result.words == Tokenizer.tokenize(TextCleaner.cleanText(source, level: level)))
        #expect(result.words.contains("**Plan**"))
        #expect(result.chapters.isEmpty)
    }

    @Test func markdownImportKeepsNumbersAndNavigationWordsTheCleanerWouldDrop() throws {
        let result = try importFile("# Next\n\n42\n\n| A | B | C |\n| --- | --- | --- |\n| 1 | 2 | 3 |", ext: "markdown")
        #expect(result.words == ["Next", "42", "A", "B", "C", "1", "2", "3"])
    }

    @Test(arguments: ["", "```swift\nlet hidden = true\n```", "---\n\n![](image.png)", "---\ntitle: Only metadata\n---\n"])
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
