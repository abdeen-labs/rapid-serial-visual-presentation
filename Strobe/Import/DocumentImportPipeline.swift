import Foundation
internal import UniformTypeIdentifiers

/// The detected file format of an imported document.
enum DocumentSourceType: String, Equatable {
    case pdf
    case epub
    case plainText
    case markdown
    case unknown
}

/// The result of a document import operation.
struct ImportResult {
    let words: [String]
    let complexityScores: [Float]
    let chapters: [Chapter]
    let sourceType: DocumentSourceType
    let title: String?
}

/// Routes document files to the appropriate extractor based on file type.
///
/// Serves as the entry point for the import pipeline: detects the source type,
/// delegates to format-specific extractors, and resolves
/// the display title from metadata or the filename.
enum DocumentImportPipeline {
    /// The content types the app can import via the file picker.
    nonisolated static let supportedContentTypes: [UTType] = [.pdf, .epub, .plainText]
        + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }

    /// Upper bound on plain-text file size — beyond any real book; bounds
    /// memory against a pathological multi-gigabyte file.
    nonisolated static let maxPlainTextBytes = 64 << 20

    /// Determines the document format from the system-detected content type
    /// or, as a fallback, from the file extension.
    nonisolated static func resolveSourceType(for url: URL, detectedContentType: UTType? = nil) -> DocumentSourceType {
        if let detectedContentType {
            if detectedContentType.conforms(to: .pdf) { return .pdf }
            if detectedContentType.conforms(to: .epub) { return .epub }
            if isMarkdown(url) { return .markdown }
            if detectedContentType.conforms(to: .plainText) { return .plainText }
        }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return .pdf
        case "epub":
            return .epub
        case "md", "markdown":
            return .markdown
        case "txt", "text":
            return .plainText
        default:
            return .unknown
        }
    }

    nonisolated private static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    /// Returns the document's metadata title if available, otherwise cleans up the filename.
    nonisolated static func resolveTitle(metadataTitle: String?, fileName: String) -> String {
        if let metadataTitle {
            let trimmed = metadataTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return cleanFileName(fileName)
    }

    /// Turns `_OCEanpdf_Labor_from_blah.pdf` into `OCEanpdf Labor From Blah`.
    nonisolated private static func cleanFileName(_ fileName: String) -> String {
        // Strip extension
        var name = fileName
        if let dotRange = name.range(of: ".", options: .backwards) {
            let ext = String(name[dotRange.upperBound...]).lowercased()
            if ["pdf", "epub", "txt", "text", "md", "markdown"].contains(ext) {
                name = String(name[..<dotRange.lowerBound])
            }
        }

        // Replace underscores, hyphens, and dots used as separators with spaces
        var cleaned = name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")

        // Collapse multiple spaces and trim
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return fileName }

        // Title-case each word (capitalize first letter, keep the rest)
        return cleaned.split(separator: " ").map { word in
            guard let first = word.first else { return String(word) }
            return String(first).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    /// Extracts words and chapters from a document file.
    /// - Parameters:
    ///   - url: The file URL to import.
    ///   - detectedContentType: The system-detected UTType, if available.
    ///   - cleaningLevel: How aggressively to remove boilerplate text.
    /// - Returns: The extracted words, chapters, source type, and title.
    /// - Throws: ``DocumentImportError/unsupportedFileType`` for unrecognized formats.
    nonisolated static func extractWordsAndChapters(
        from url: URL,
        detectedContentType: UTType? = nil,
        cleaningLevel: TextCleaningLevel = .standard
    ) throws -> ImportResult {
        let type = resolveSourceType(for: url, detectedContentType: detectedContentType)
        switch type {
        case .pdf:
            let result = try PDFTextExtractor.extractWordsAndChapters(from: url, cleaningLevel: cleaningLevel)
            try Task.checkCancellation()
            let complexity = WordComplexityAnalyzer.analyzeComplexity(result.words)
            try Task.checkCancellation()
            return ImportResult(words: result.words, complexityScores: complexity, chapters: result.chapters, sourceType: .pdf, title: result.title)
        case .epub:
            let result = try EPUBTextExtractor.extractWordsAndChapters(from: url, cleaningLevel: cleaningLevel)
            try Task.checkCancellation()
            let complexity = WordComplexityAnalyzer.analyzeComplexity(result.words)
            try Task.checkCancellation()
            return ImportResult(words: result.words, complexityScores: complexity, chapters: result.chapters, sourceType: .epub, title: result.title)
        case .plainText:
            let text = try readPlainText(from: url)
            let cleaned = TextCleaner.cleanText(text, level: cleaningLevel)
            try Task.checkCancellation()
            let words = Tokenizer.tokenize(cleaned)
            try Task.checkCancellation()
            let complexity = WordComplexityAnalyzer.analyzeComplexity(words)
            try Task.checkCancellation()
            return ImportResult(words: words, complexityScores: complexity, chapters: [], sourceType: .plainText, title: nil)
        case .markdown:
            // Structural Markdown parsing is independent of boilerplate cleaning.
            // TextCleaner's page-number/table rules would discard valid content.
            let text = try readPlainText(from: url)
            let words = try MarkdownTextExtractor.extractWords(from: text)
            try Task.checkCancellation()
            let complexity = WordComplexityAnalyzer.analyzeComplexity(words)
            try Task.checkCancellation()
            return ImportResult(words: words, complexityScores: complexity, chapters: [], sourceType: .markdown, title: nil)
        case .unknown:
            throw DocumentImportError.unsupportedFileType
        }
    }

    /// Reads a plain-text file as UTF-8 (lossy for other encodings' invalid
    /// sequences), bounded by ``maxPlainTextBytes``.
    nonisolated private static func readPlainText(from url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            throw DocumentImportError.noReadableText
        }
        guard data.count <= maxPlainTextBytes else {
            throw DocumentImportError.noReadableText
        }
        return String(decoding: data, as: UTF8.self)
    }
}
