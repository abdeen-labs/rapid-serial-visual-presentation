import PDFKit
import os

/// The result of extracting text from a PDF file.
struct PDFExtractionResult {
    let words: [String]
    let chapters: [Chapter]
    let title: String?
    /// The first page as a ``CoverImage``, when it looks like a cover.
    var coverImage: Data? = nil
}

/// Extracts tokenized words and chapter structure from PDF files using PDFKit.
///
/// The extraction pipeline: read pages → clean text (cross-page header/footer
/// detection + per-page boilerplate removal) → tokenize → extract chapters
/// from the PDF outline.
enum PDFTextExtractor {

    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.abdeen.strobe",
        category: "PDFTextExtractor"
    )

    /// Upper bound on pages processed per import. Far beyond any real book —
    /// this exists so a crafted PDF declaring an enormous page count can't
    /// pin the import task's CPU and memory indefinitely.
    nonisolated static let maxProcessedPages = 20_000

    /// Extracts words and chapters from a PDF file.
    /// - Parameters:
    ///   - url: The file URL of the PDF document.
    ///   - cleaningLevel: How aggressively to remove boilerplate text.
    /// - Returns: Tokenized words, chapter list, and metadata title.
    ///   Throws ``DocumentImportError/pdfLoadFailed`` if the PDF cannot be opened.
    nonisolated static func extractWordsAndChapters(
        from url: URL,
        cleaningLevel: TextCleaningLevel = .standard
    ) throws -> PDFExtractionResult {
        guard let document = PDFDocument(url: url) else {
            throw DocumentImportError.pdfLoadFailed
        }

        // A locked document opens fine but yields no page text — without this
        // check it would fall through to the misleading "image-only" error.
        guard !document.isLocked else {
            throw DocumentImportError.pdfPasswordProtected
        }

        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }

        let pageCount = min(document.pageCount, maxProcessedPages)
        if document.pageCount > maxProcessedPages {
            logger.warning("PDF declares \(document.pageCount) pages; processing the first \(maxProcessedPages).")
        }

        // Phase 1: Collect raw text from each page
        var pageTexts: [String] = []
        pageTexts.reserveCapacity(pageCount)

        for i in 0..<pageCount {
            // Keep a cancelled import (user tapped Cancel) from grinding
            // through the rest of a large document.
            if i % 64 == 0 { try Task.checkCancellation() }
            autoreleasepool {
                if let page = document.page(at: i), let text = page.string {
                    pageTexts.append(text)
                } else {
                    pageTexts.append("")
                }
            }
        }

        // Phase 2: Clean text (cross-page analysis + per-page rules)
        let cleanedPages = TextCleaner.cleanPages(pageTexts, level: cleaningLevel)

        // Phase 3: Tokenize cleaned pages
        var result: [String] = []
        result.reserveCapacity(pageCount * 250)

        var pageWordOffsets: [Int] = []
        pageWordOffsets.reserveCapacity(pageCount)

        var carry: String?
        for text in cleanedPages {
            pageWordOffsets.append(result.count)
            Tokenizer.appendTokenizedText(text, into: &result, carry: &carry)
        }

        if let carry, !carry.isEmpty {
            result.append(carry)
        }

        let chapters = extractChapters(from: document, pageWordOffsets: pageWordOffsets)
            .filter { result.indices.contains($0.wordIndex) }
        try Task.checkCancellation()
        let firstPageWords = pageTexts.first.map { $0.split(whereSeparator: \.isWhitespace).count } ?? 0
        let cover = document.page(at: 0).flatMap { page in
            autoreleasepool { coverImage(of: page, wordCount: firstPageWords) }
        }
        return PDFExtractionResult(words: result, chapters: chapters, title: title, coverImage: cover)
    }

    // MARK: - Cover

    /// The page as a ``CoverImage`` when it looks like a cover
    /// (``CoverImage/looksLikeCover(_:wordCount:)``). A PDF declares no
    /// cover, and most first pages are text, which keep the generated
    /// cover. Nil for those, and for a page with no size.
    nonisolated static func coverImage(of page: PDFPage, wordCount: Int) -> Data? {
        // A page of text needs no drawing to be passed over.
        guard wordCount <= CoverImage.maxCoverWords, let image = drawing(of: page),
              CoverImage.looksLikeCover(image, wordCount: wordCount) else { return nil }
        return CoverImage.jpegData(image)
    }

    /// The page drawn on white, as large as a cover is stored, turned as
    /// the page says.
    nonisolated static func drawing(of page: PDFPage) -> CGImage? {
        guard let pageRef = page.pageRef else { return nil }
        let box = pageRef.getBoxRect(.cropBox)
        let isTurned = abs(Int(pageRef.rotationAngle)) % 180 == 90
        let pageSize = isTurned ? CGSize(width: box.height, height: box.width) : box.size
        // A page is drawn, not scaled, so a small one is enlarged too.
        guard let size = CoverImage.fittingSize(pageSize, within: CoverImage.maxSize, enlarging: true),
              let context = CoverImage.makeContext(size: size) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        context.scaleBy(x: size.width / pageSize.width, y: size.height / pageSize.height)
        context.concatenate(pageRef.getDrawingTransform(
            .cropBox, rect: CGRect(origin: .zero, size: pageSize), rotate: 0, preserveAspectRatio: true
        ))
        context.drawPDFPage(pageRef)
        return context.makeImage()
    }

    // MARK: - Chapter extraction

    /// Walks the full PDF outline, including parts, chapters, and subsections.
    /// Destinations retain the importer's page-level positioning.
    nonisolated static func extractChapters(
        from document: PDFDocument,
        pageWordOffsets: [Int]
    ) -> [Chapter] {
        guard let outlineRoot = document.outlineRoot else { return [] }

        var chapters: [Chapter] = []

        func addOutlineItem(_ item: PDFOutline) {
            guard let label = item.label, !label.isEmpty else { return }
            guard let destination = item.destination ?? (item.action as? PDFActionGoTo)?.destination,
                  let page = destination.page else { return }
            let pageIndex = document.index(for: page)
            guard pageWordOffsets.indices.contains(pageIndex) else { return }
            let wordIndex = pageWordOffsets[pageIndex]
            chapters.append(Chapter(title: label, wordIndex: wordIndex))
        }

        // Iterative depth-first traversal avoids call-stack growth for deeply
        // nested outlines. Bound traversal and reject cycles in malformed PDFs.
        var stack = [outlineRoot]
        var visited = Set<ObjectIdentifier>()
        while let item = stack.popLast(), visited.count < 100_000 {
            guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
            if item !== outlineRoot { addOutlineItem(item) }
            for index in (0..<min(item.numberOfChildren, 100_000 - visited.count)).reversed() {
                if let child = item.child(at: index) { stack.append(child) }
            }
        }

        chapters.sort { $0.wordIndex < $1.wordIndex }

        var seen = Set<Int>()
        chapters = chapters.filter { seen.insert($0.wordIndex).inserted }

        return chapters
    }
}
