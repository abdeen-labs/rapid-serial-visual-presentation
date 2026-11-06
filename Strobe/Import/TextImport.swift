import Foundation

/// Turns plain text into a library ``Document``. New Text, text shared from
/// other apps, and shortcuts all add text this way.
enum TextImport {
    /// Text tokenized, scored for complexity, and encoded for storage.
    nonisolated struct Prepared {
        let wordCount: Int
        let wordsBlob: Data
        let complexityBlob: Data?
        /// Where the text's paragraphs end (``BlockEndStorage``).
        var blockEndsBlob: Data? = nil
    }

    /// Tokenizes, scores, and encodes `text`. All three are slow on a long
    /// text, so call this off the main actor. Nil when the text has no
    /// readable words.
    nonisolated static func prepare(_ text: String) -> Prepared? {
        let (words, blockEnds) = PlainTextParagraphs.tokenize(text)
        guard !words.isEmpty else { return nil }
        let scores = WordComplexityAnalyzer.analyzeComplexity(words)
        return Prepared(
            wordCount: words.count,
            wordsBlob: WordStorage.encode(words),
            complexityBlob: scores.isEmpty ? nil : ComplexityStorage.encode(scores),
            blockEndsBlob: BlockEndStorage.encode(blockEnds)
        )
    }

    /// A document for prepared text, titled by the time it was added when
    /// `title` is blank. Text stores its title as the file name unless
    /// `fileName` gives something else, such as a web page's address.
    static func makeDocument(
        from prepared: Prepared,
        title: String,
        fileName: String? = nil,
        dateAdded: Date = Date(),
        wordsPerMinute: Int
    ) -> Document {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmedTitle.isEmpty ? untitledTitle(addedAt: dateAdded) : trimmedTitle
        let document = Document(
            title: resolvedTitle,
            fileName: fileName ?? resolvedTitle,
            bookmarkData: Data(),
            wordsBlob: prepared.wordsBlob,
            wordCount: prepared.wordCount,
            complexityBlob: prepared.complexityBlob,
            wordsPerMinute: wordsPerMinute
        )
        document.dateAdded = dateAdded
        document.blockEndsBlob = prepared.blockEndsBlob
        return document
    }

    /// The title for text added without one, such as
    /// "Text — Sep 24, 2026 at 3:12 PM".
    nonisolated static func untitledTitle(addedAt date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Text \u{2014} \(formatter.string(from: date))"
    }
}
