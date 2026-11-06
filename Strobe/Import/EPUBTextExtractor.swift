import Foundation

/// The result of extracting text from an EPUB file.
struct EPUBExtractionResult {
    let words: [String]
    let chapters: [Chapter]
    let title: String?
    /// Where blocks end: block elements and the end of each spine document.
    var blockEnds: BlockEnds = .none
}

/// Extracts tokenized words and chapter structure from EPUB files.
///
/// Supports both EPUB 2 (NCX table of contents) and EPUB 3 (nav document).
/// The extraction pipeline: unzip → parse OPF manifest → read spine-ordered
/// XHTML files → strip HTML → clean text → tokenize.
enum EPUBTextExtractor {

    /// Extracts words and chapters from an EPUB file.
    /// - Parameters:
    ///   - url: The file URL of the EPUB archive.
    ///   - cleaningLevel: How aggressively to remove boilerplate text.
    /// - Returns: Tokenized words, chapter list, and metadata title.
    /// - Throws: ``DocumentImportError/epubExtractionFailed`` if the archive is invalid.
    nonisolated static func extractWordsAndChapters(
        from url: URL,
        cleaningLevel: TextCleaningLevel = .standard
    ) throws -> EPUBExtractionResult {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try ZIPExtractor.extract(zipAt: url, to: tempDir)

        let opfRelativePath = try findOPFPath(in: tempDir)
        let opfURL = tempDir.appendingPathComponent(opfRelativePath)
        let opfDir = opfURL.deletingLastPathComponent()

        let opf = try parseOPF(at: opfURL)

        try ensureSpineNotEncrypted(
            epubRoot: tempDir,
            opfRelativePath: opfRelativePath,
            opf: opf
        )

        // Phase 1: Collect raw text from spine-ordered XHTML files
        var sectionTexts: [(path: String, content: EPUBContent)] = []
        sectionTexts.reserveCapacity(opf.spineItems.count)

        for (i, itemID) in opf.spineItems.enumerated() {
            // Keep a cancelled import (user tapped Cancel) responsive.
            if i % 16 == 0 { try Task.checkCancellation() }
            guard let href = opf.manifest[itemID] else { continue }
            let fileURL = opfDir.appendingPathComponent(href).standardizedFileURL

            autoreleasepool {
                guard let data = try? Data(contentsOf: fileURL) else { return }
                sectionTexts.append((path: fileURL.path, content: EPUBContent.parse(data)))
            }
        }

        // Phase 2: Clean text
        let cleanedTexts = TextCleaner.cleanPages(
            sectionTexts.map { $0.content.text },
            level: cleaningLevel, preserveOffsets: true
        )

        // Phase 3: Tokenize cleaned sections
        var words: [String] = []
        words.reserveCapacity(sectionTexts.count * 500)
        var spineWordOffsets: [String: Int] = [:]
        var anchorWordOffsets: [String: [String: Int]] = [:]
        var headingChapters: [Chapter] = []
        var blockEnds = BlockEnds()
        var carry: String?

        for (i, pair) in sectionTexts.enumerated() {
            if i % 16 == 0 { try Task.checkCancellation() }
            // Each spine document starts a block.
            if carry == nil, !words.isEmpty { blockEnds.mark(words.count - 1, as: .block) }
            let positions = pair.content.appendWords(
                cleanedText: cleanedTexts[i], into: &words, carry: &carry, blockEnds: &blockEnds
            )
            spineWordOffsets[pair.path] = positions[0]
            anchorWordOffsets[pair.path] = pair.content.anchors.compactMapValues { positions[$0] }
            headingChapters += pair.content.headings.compactMap { heading in
                positions[heading.offset].map { Chapter(title: heading.title, wordIndex: $0) }
            }
        }

        if let carry, !carry.isEmpty {
            words.append(carry)
        }
        if !words.isEmpty { blockEnds.mark(words.count - 1, as: .block) }

        // Extract chapters from NCX or NAV
        let chapters = extractChapters(
            opf: opf,
            opfDir: opfDir,
            spineWordOffsets: spineWordOffsets,
            anchorWordOffsets: anchorWordOffsets
        )
        // Explicit TOC labels take precedence over headings at the same word.
        let allChapters = deduplicateChapters(chapters + headingChapters)
            .filter { words.indices.contains($0.wordIndex) }

        return EPUBExtractionResult(words: words, chapters: allChapters, title: opf.title, blockEnds: blockEnds)
    }

    // MARK: - DRM detection

    /// Throws ``DocumentImportError/epubDRMProtected`` if any spine content
    /// document is listed in `META-INF/encryption.xml`.
    ///
    /// `encryption.xml` alone doesn't imply DRM — its common benign use is
    /// font obfuscation, which leaves content documents unencrypted. Only
    /// encrypted *spine* entries make the book unreadable; without this check
    /// they would decode as binary garbage and import as mojibake "words".
    nonisolated private static func ensureSpineNotEncrypted(
        epubRoot: URL,
        opfRelativePath: String,
        opf: OPFResult
    ) throws {
        let encryptionURL = epubRoot
            .appendingPathComponent("META-INF", isDirectory: true)
            .appendingPathComponent("encryption.xml")
        guard let data = try? Data(contentsOf: encryptionURL) else { return }

        let parser = SimpleXMLParser()
        parser.parse(data: data)

        // <enc:CipherReference URI="..."/> paths are relative to the archive root.
        var encryptedPaths = Set<String>()
        for element in parser.elements where element.name == "CipherReference" {
            if let uri = element.attributes["URI"] {
                let decoded = uri.removingPercentEncoding ?? uri
                encryptedPaths.insert(normalizedArchivePath(decoded))
            }
        }
        guard !encryptedPaths.isEmpty else { return }

        // Spine hrefs are relative to the OPF's directory — translate to
        // archive-root-relative paths before comparing.
        let opfDirPrefix: String
        if let lastSlash = opfRelativePath.lastIndex(of: "/") {
            opfDirPrefix = String(opfRelativePath[...lastSlash])
        } else {
            opfDirPrefix = ""
        }

        for itemID in opf.spineItems {
            guard let href = opf.manifest[itemID] else { continue }
            let rootRelative = normalizedArchivePath(opfDirPrefix + href)
            if encryptedPaths.contains(rootRelative) {
                throw DocumentImportError.epubDRMProtected
            }
        }
    }

    /// Resolves `.` / `..` segments and leading slashes so paths from
    /// encryption.xml and the OPF manifest compare consistently.
    nonisolated private static func normalizedArchivePath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: "/" + path).standardized.path
        return String(standardized.dropFirst())
    }

    // MARK: - container.xml → OPF path

    /// Reads `META-INF/container.xml` to find the path to the OPF package file.
    nonisolated private static func findOPFPath(in epubDir: URL) throws -> String {
        let containerURL = epubDir
            .appendingPathComponent("META-INF", isDirectory: true)
            .appendingPathComponent("container.xml")
        // A missing container.xml is a malformed EPUB — map to the import
        // error instead of surfacing a raw CocoaError with a temp-dir path.
        guard let data = try? Data(contentsOf: containerURL) else {
            throw DocumentImportError.epubExtractionFailed
        }
        let parser = SimpleXMLParser()
        parser.parse(data: data)

        // Look for <rootfile full-path="..."/>
        for element in parser.elements where element.name == "rootfile" {
            if let fullPath = element.attributes["full-path"], !fullPath.isEmpty {
                return fullPath
            }
        }
        throw DocumentImportError.epubExtractionFailed
    }

    // MARK: - OPF parsing

    /// Parsed contents of the OPF (Open Packaging Format) manifest file.
    private struct OPFResult {
        let manifest: [String: String]   // id → href
        let spineItems: [String]          // ordered item IDs
        let tocID: String?                // NCX manifest ID
        let navHref: String?              // EPUB3 nav document href
        let title: String?                // <dc:title>
    }

    /// Parses the OPF package file to extract manifest items, reading order, and metadata.
    nonisolated private static func parseOPF(at url: URL) throws -> OPFResult {
        guard let data = try? Data(contentsOf: url) else {
            throw DocumentImportError.epubExtractionFailed
        }
        let parser = SimpleXMLParser()
        parser.parse(data: data)

        var manifest: [String: String] = [:]
        var spineItems: [String] = []
        var tocID: String?
        var navHref: String?
        var title: String?

        for element in parser.elements {
            switch element.name {
            case "title":
                // <dc:title> — take the first non-empty one
                if title == nil,
                   let text = element.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    title = text
                }
            case "item":
                if let id = element.attributes["id"],
                   let href = element.attributes["href"] {
                    let decodedHref = href.removingPercentEncoding ?? href
                    manifest[id] = decodedHref
                    // EPUB3 nav detection
                    if let properties = element.attributes["properties"],
                       properties.contains("nav") {
                        navHref = decodedHref
                    }
                }
            case "itemref":
                if let idref = element.attributes["idref"] {
                    spineItems.append(idref)
                }
            case "spine":
                tocID = element.attributes["toc"]
            default:
                break
            }
        }

        return OPFResult(
            manifest: manifest,
            spineItems: spineItems,
            tocID: tocID,
            navHref: navHref,
            title: title
        )
    }

    // MARK: - Chapter extraction

    /// Extracts chapters by trying EPUB 3 nav document first, then falling back to EPUB 2 NCX.
    nonisolated private static func extractChapters(
        opf: OPFResult,
        opfDir: URL,
        spineWordOffsets: [String: Int],
        anchorWordOffsets: [String: [String: Int]]
    ) -> [Chapter] {
        // Try EPUB3 nav first, then NCX
        if let navHref = opf.navHref {
            let navURL = opfDir.appendingPathComponent(navHref)
            if let chapters = parseNavDocument(
                at: navURL,
                spineWordOffsets: spineWordOffsets, anchorWordOffsets: anchorWordOffsets
            ), !chapters.isEmpty {
                return chapters
            }
        }

        if let tocID = opf.tocID,
           let tocHref = opf.manifest[tocID] {
            let ncxURL = opfDir.appendingPathComponent(tocHref)
            if let chapters = parseNCX(
                at: ncxURL,
                spineWordOffsets: spineWordOffsets, anchorWordOffsets: anchorWordOffsets
            ), !chapters.isEmpty {
                return chapters
            }
        }

        return []
    }

    // MARK: - EPUB3 Nav parsing

    /// Parses an EPUB 3 navigation document (`<nav>`) for chapter titles and hrefs.
    nonisolated private static func parseNavDocument(
        at url: URL,
        spineWordOffsets: [String: Int],
        anchorWordOffsets: [String: [String: Int]]
    ) -> [Chapter]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let parser = SimpleXMLParser()
        parser.parse(data: data)

        var chapters: [Chapter] = []

        // Nav documents use <a href="...">Title</a> inside <li> elements
        for element in parser.elements where element.name == "a" && element.isInTOC {
            guard let href = element.attributes["href"],
                  let rawTitle = element.text else { continue }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            if let wordIndex = resolveWordIndex(
                href: href, referenceURL: url,
                spineWordOffsets: spineWordOffsets, anchorWordOffsets: anchorWordOffsets
            ) {
                chapters.append(Chapter(title: title, wordIndex: wordIndex))
            }
        }

        return deduplicateChapters(chapters)
    }

    // MARK: - NCX parsing

    /// Parses an EPUB 2 NCX file for chapter titles and content sources.
    nonisolated private static func parseNCX(
        at url: URL,
        spineWordOffsets: [String: Int],
        anchorWordOffsets: [String: [String: Int]]
    ) -> [Chapter]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let parser = NCXParser()
        parser.parse(data: data)

        var chapters: [Chapter] = []

        // All nested navPoints, in document order
        for navPoint in parser.navPoints {
            guard let title = navPoint.title, !title.isEmpty,
                  let src = navPoint.src else { continue }

            if let wordIndex = resolveWordIndex(
                href: src, referenceURL: url,
                spineWordOffsets: spineWordOffsets, anchorWordOffsets: anchorWordOffsets
            ) {
                chapters.append(Chapter(title: title, wordIndex: wordIndex))
            }
        }

        return deduplicateChapters(chapters)
    }

    // MARK: - Href resolution

    /// Resolve relative paths and fragment identifiers separately, decoding
    /// exactly once so escaped filenames and case-sensitive IDs stay intact.
    nonisolated private static func resolveWordIndex(
        href: String,
        referenceURL: URL,
        spineWordOffsets: [String: Int],
        anchorWordOffsets: [String: [String: Int]]
    ) -> Int? {
        guard let resolved = URL(string: href, relativeTo: referenceURL)?.absoluteURL,
              resolved.isFileURL else { return nil }
        let path = resolved.standardizedFileURL.path
        if let fragment = resolved.fragment, !fragment.isEmpty {
            let id = fragment.removingPercentEncoding ?? fragment
            // A missing fragment must not silently point at the file's start.
            return anchorWordOffsets[path]?[id]
        }
        return spineWordOffsets[path]
    }

    /// Keep the first label for each unique position, then put it in reading order.
    nonisolated private static func deduplicateChapters(_ chapters: [Chapter]) -> [Chapter] {
        var seen = Set<Int>()
        return chapters.filter { seen.insert($0.wordIndex).inserted }
            .sorted { $0.wordIndex < $1.wordIndex }
    }

    // MARK: - HTML entity resolution

    /// Named entity bodies (the text between `&` and `;`) and their replacements.
    nonisolated private static let htmlEntityMap: [String: String] = [
        "nbsp": " ",
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "quot": "\"",
        "apos": "'",
        "mdash": "\u{2014}",
        "ndash": "\u{2013}",
        "hellip": "\u{2026}",
        "lsquo": "\u{2018}",
        "rsquo": "\u{2019}",
        "ldquo": "\u{201C}",
        "rdquo": "\u{201D}",
        "trade": "\u{2122}",
        "reg": "\u{00AE}",
        "copy": "\u{00A9}",
        "bull": "\u{2022}",
        "deg": "\u{00B0}",
        "times": "\u{00D7}",
        "divide": "\u{00F7}",
        "laquo": "\u{00AB}",
        "raquo": "\u{00BB}",
        "frac12": "\u{00BD}",
        "frac14": "\u{00BC}",
        "frac34": "\u{00BE}",
    ]

    /// Longest entity body worth scanning for: `&#x10FFFF;` (8) with slack.
    nonisolated private static let maxEntityBodyLength = 16

    /// Resolves named and numeric (`&#NNN;` / `&#xHHH;`) HTML entities in a
    /// single left-to-right pass.
    ///
    /// A single pass makes double-encoded input decode correctly and
    /// deterministically: each resolved entity is emitted as plain text and
    /// never rescanned, so `&amp;lt;` → `&lt;` and `&amp;#65;` → `&#65;`
    /// (the multi-pass predecessor decoded those a second time, and its
    /// dictionary-ordered named pass made the result order-dependent).
    nonisolated static func resolveHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var i = text.startIndex

        while i < text.endIndex {
            let char = text[i]
            guard char == "&" else {
                result.append(char)
                i = text.index(after: i)
                continue
            }

            // Find the terminating ';' within a bounded window.
            var j = text.index(after: i)
            var semicolon: String.Index?
            var steps = 0
            while j < text.endIndex, steps < maxEntityBodyLength {
                if text[j] == ";" { semicolon = j; break }
                if text[j] == "&" { break } // a new '&' can't be inside an entity
                j = text.index(after: j)
                steps += 1
            }

            if let semicolon,
               let replacement = entityReplacement(String(text[text.index(after: i)..<semicolon])) {
                result.append(replacement)
                i = text.index(after: semicolon)
            } else {
                // Not a valid entity — emit the '&' literally and continue.
                result.append(char)
                i = text.index(after: i)
            }
        }

        return result
    }

    /// Replacement for an entity body (`amp`, `#65`, `#x41`, …), or nil if invalid.
    nonisolated private static func entityReplacement(_ body: String) -> String? {
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            guard let codePoint = UInt32(body.dropFirst(2), radix: 16),
                  let scalar = Unicode.Scalar(codePoint) else { return nil }
            return String(Character(scalar))
        }
        if body.hasPrefix("#") {
            guard let codePoint = UInt32(body.dropFirst(1)),
                  let scalar = Unicode.Scalar(codePoint) else { return nil }
            return String(Character(scalar))
        }
        return htmlEntityMap[body]
    }
}

// MARK: - Simple XML Parser (flat element collection)

/// Lightweight XML parser that collects all elements into a flat array.
/// Used for parsing container.xml, OPF manifests, and EPUB 3 nav documents.
///
/// Character data is attributed to every currently-open element, so an
/// element's `text` includes its descendants' text — nav-document titles
/// wrapped in child elements (`<a><span>Chapter 1</span></a>`) resolve to
/// the `<a>` element instead of being dropped.
///
/// `@unchecked Sendable` is safe here: instances are created, used, and discarded
/// within a single synchronous scope and are never shared across threads.
private final class SimpleXMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    struct Element {
        let name: String
        let attributes: [String: String]
        var text: String?
        var isInTOC: Bool = false
    }

    /// Text is attributed to at most this many enclosing ancestors. Real
    /// package/nav documents nest titles a handful of levels deep; without a
    /// cap, a crafted document with thousands of open elements makes every
    /// character-data callback O(depth) and stores O(depth × text) copies —
    /// a memory-amplification DoS on import.
    nonisolated private static let maxAttributedAncestors = 32
    /// Cumulative cap on attributed text across the whole document. The
    /// documents this parser reads (container.xml, OPF, nav) are metadata —
    /// a few hundred KB of titles is far beyond any legitimate book.
    nonisolated private static let maxTotalAttributedBytes = 8 << 20

    nonisolated(unsafe) private(set) var elements: [Element] = []
    nonisolated(unsafe) private var openElementIndices: [Int] = []
    nonisolated(unsafe) private var totalAttributedBytes = 0

    nonisolated override init() { super.init() }

    nonisolated func parse(data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
    }

    nonisolated func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        let parentIsTOC = openElementIndices.last.map { elements[$0].isInTOC } ?? false
        let types = (attributes["epub:type"] ?? "").split(whereSeparator: \.isWhitespace)
        let isTOC = localName == "nav" && (types.contains("toc") || attributes["role"] == "doc-toc")
        elements.append(Element(name: localName, attributes: attributes, isInTOC: parentIsTOC || isTOC))
        openElementIndices.append(elements.count - 1)
    }

    nonisolated func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard totalAttributedBytes < Self.maxTotalAttributedBytes else { return }
        let ancestors = openElementIndices.suffix(Self.maxAttributedAncestors)
        totalAttributedBytes += string.utf8.count * ancestors.count
        for index in ancestors {
            // In-place append: `(text ?? "") + string` copies each long-lived
            // ancestor's entire accumulated text on every callback, which is
            // quadratic for large nav/TOC documents.
            if elements[index].text == nil {
                elements[index].text = string
            } else {
                elements[index].text?.append(string)
            }
        }
    }

    nonisolated func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        if !openElementIndices.isEmpty {
            openElementIndices.removeLast()
        }
    }
}

// MARK: - NCX Parser (navPoint extraction)

/// Reads navPoints at every depth without mixing parent and child labels.
/// Instances are confined to a single synchronous parse.
private final class NCXParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    struct NavPoint {
        var title: String?
        var src: String?
    }

    nonisolated(unsafe) private(set) var navPoints: [NavPoint] = []
    nonisolated(unsafe) private var stack: [Int] = []
    nonisolated(unsafe) private var inText = false

    nonisolated override init() { super.init() }

    nonisolated func parse(data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    nonisolated func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?, attributes: [String: String]
    ) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        switch name {
        case "navPoint":
            navPoints.append(NavPoint(title: nil, src: nil))
            stack.append(navPoints.count - 1)
        case "text":
            inText = !stack.isEmpty
        case "content":
            if let index = stack.last { navPoints[index].src = attributes["src"] }
        default: break
        }
    }

    nonisolated func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText, let index = stack.last {
            if navPoints[index].title == nil { navPoints[index].title = "" }
            navPoints[index].title?.append(string)
        }
    }

    nonisolated func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName: String?
    ) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        if name == "text" { inText = false }
        if name == "navPoint", let index = stack.popLast() {
            navPoints[index].title = navPoints[index].title?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
