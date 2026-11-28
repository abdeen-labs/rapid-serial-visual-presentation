import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import Strobe

struct BookCoverTests {

    // MARK: - Helpers

    private static func image(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CoverImage.makeContext(size: CGSize(width: width, height: height)))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private static func pixelSize(of data: Data) throws -> CGSize {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return CGSize(width: image.width, height: image.height)
    }

    private static func opf(manifest: String, metadata: String = "", guide: String = "") -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Book</dc:title>
            \(metadata)
          </metadata>
          <manifest>
            <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            \(manifest)
          </manifest>
          <spine><itemref idref="chapter1"/></spine>
          \(guide)
        </package>
        """.utf8)
    }

    // MARK: - Finding an EPUB's cover

    @Test func epub3CoverImageProperty() {
        let data = Self.opf(manifest: """
        <item id="art" href="images/front.jpg" media-type="image/jpeg" properties="svg cover-image"/>
        <item id="cover" href="images/other-cover.jpg" media-type="image/jpeg"/>
        """, metadata: #"<meta name="cover" content="cover"/>"#)
        #expect(EPUBTextExtractor.coverHref(inOPF: data) == "images/front.jpg")
    }

    @Test func epub2CoverMetaNamesAnItem() {
        let data = Self.opf(
            manifest: #"<item id="cover-img" href="Images/Cover%20Art.png" media-type="image/png"/>"#,
            metadata: #"<meta name="cover" content="cover-img"/>"#
        )
        #expect(EPUBTextExtractor.coverHref(inOPF: data) == "Images/Cover Art.png")
    }

    @Test func epub2CoverMetaWrittenAsAPath() {
        let data = Self.opf(
            manifest: #"<item id="i1" href="images/jacket.jpg" media-type="image/jpeg"/>"#,
            metadata: #"<meta name="cover" content="images/jacket.jpg"/>"#
        )
        #expect(EPUBTextExtractor.coverHref(inOPF: data) == "images/jacket.jpg")
    }

    @Test func guideCoverPage() {
        let data = Self.opf(
            manifest: #"<item id="titlepage" href="titlepage.xhtml" media-type="application/xhtml+xml"/>"#,
            guide: #"<guide><reference type="cover" title="Cover" href="titlepage.xhtml#start"/></guide>"#
        )
        #expect(EPUBTextExtractor.coverHref(inOPF: data) == "titlepage.xhtml")
    }

    @Test func imageNamedCoverIsTheLastResort() {
        let data = Self.opf(manifest: """
        <item id="map" href="images/map.png" media-type="image/png"/>
        <item id="img2" href="images/Cover.jpeg" media-type="image/jpeg"/>
        """)
        #expect(EPUBTextExtractor.coverHref(inOPF: data) == "images/Cover.jpeg")
    }

    @Test func bookWithoutACover() {
        let data = Self.opf(manifest: #"<item id="map" href="images/map.png" media-type="image/png"/>"#)
        #expect(EPUBTextExtractor.coverHref(inOPF: data) == nil)
    }

    @Test func coverPageImage() {
        let html = Data(#"<html><body><div><img src="../Images/cover%201.jpg#x" alt="Cover"/></div></body></html>"#.utf8)
        #expect(EPUBTextExtractor.coverImageSource(inPage: html) == "../Images/cover 1.jpg")

        let svg = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 600 900">
        <image width="600" height="900" xlink:href="cover.jpeg"/>
        </svg></body></html>
        """.utf8)
        #expect(EPUBTextExtractor.coverImageSource(inPage: svg) == "cover.jpeg")

        #expect(EPUBTextExtractor.coverImageSource(inPage: Data("<html><body><p>No art.</p></body></html>".utf8)) == nil)
    }

    // MARK: - Importing an EPUB's cover

    private static func epub(opf: Data, files: [(String, Data)]) throws -> URL {
        let container = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0"><rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
        </rootfiles></container>
        """.utf8)
        let chapter = Data("<html><body><p>Hello cover reader.</p></body></html>".utf8)
        let entries = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", container),
            ("OEBPS/content.opf", opf),
            ("OEBPS/chapter1.xhtml", chapter),
        ] + files
        let url = FileManager.default.temporaryDirectory.appending(path: "cover-\(UUID().uuidString).epub")
        try storedZIP(entries).write(to: url)
        return url
    }

    @Test func epubImportKeepsItsCover() throws {
        let art = try #require(CoverImage.jpegData(try Self.image(width: 1200, height: 1800)))
        let url = try Self.epub(
            opf: Self.opf(manifest: #"<item id="c" href="images/c.jpg" media-type="image/jpeg" properties="cover-image"/>"#),
            files: [("OEBPS/images/c.jpg", art)]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try DocumentImportPipeline.extractWordsAndChapters(from: url)
        #expect(result.words.contains("Hello"))
        let cover = try #require(result.coverImage)
        #expect(try Self.pixelSize(of: cover) == CGSize(width: 600, height: 900))
    }

    @Test func epubImportReadsTheCoverPage() throws {
        let art = try #require(CoverImage.jpegData(try Self.image(width: 300, height: 450)))
        let page = Data(#"<html><body><img src="../images/front.jpg"/></body></html>"#.utf8)
        let url = try Self.epub(
            opf: Self.opf(
                manifest: #"<item id="p" href="text/cover.xhtml" media-type="application/xhtml+xml"/>"#,
                guide: #"<guide><reference type="cover" href="text/cover.xhtml"/></guide>"#
            ),
            files: [("OEBPS/text/cover.xhtml", page), ("OEBPS/images/front.jpg", art)]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let cover = try #require(try DocumentImportPipeline.extractWordsAndChapters(from: url).coverImage)
        // Never enlarged.
        #expect(try Self.pixelSize(of: cover) == CGSize(width: 300, height: 450))
    }

    @Test func epubWithAnUnreadableCoverStillImports() throws {
        let url = try Self.epub(
            opf: Self.opf(manifest: #"<item id="c" href="images/c.jpg" media-type="image/jpeg" properties="cover-image"/>"#),
            files: [("OEBPS/images/c.jpg", Data("not an image".utf8))]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try DocumentImportPipeline.extractWordsAndChapters(from: url)
        #expect(result.words.contains("Hello"))
        #expect(result.coverImage == nil)
    }

    @Test func epubCoverOutsideTheBookIsIgnored() throws {
        let url = try Self.epub(
            opf: Self.opf(manifest: #"<item id="c" href="../../../../etc/c.jpg" media-type="image/jpeg" properties="cover-image"/>"#),
            files: []
        )
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try DocumentImportPipeline.extractWordsAndChapters(from: url).coverImage == nil)
    }

    /// A ZIP of stored entries, which `ZIPExtractor` reads without
    /// checking CRCs.
    private static func storedZIP(_ entries: [(String, Data)]) -> Data {
        func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
        func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
        var zip = Data()
        var central = Data()
        for (name, content) in entries {
            let nameData = Data(name.utf8)
            let offset = zip.count
            zip += le32(0x04034b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            zip += le32(content.count) + le32(content.count) + le16(nameData.count) + le16(0) + nameData + content
            central += le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            central += le32(content.count) + le32(content.count) + le16(nameData.count) + le16(0) + le16(0)
            central += le16(0) + le16(0) + le32(0) + le32(offset) + nameData
        }
        let centralOffset = zip.count
        zip += central
        zip += le32(0x06054b50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
        zip += le32(central.count) + le32(centralOffset) + le16(0)
        return zip
    }

    // MARK: - Size and encoding

    @Test func fittingKeepsTheShapeWithinTheBounds() {
        let bounds = CoverImage.maxSize
        #expect(CoverImage.fittingSize(CGSize(width: 2000, height: 3000), within: bounds) == CGSize(width: 600, height: 900))
        #expect(CoverImage.fittingSize(CGSize(width: 1600, height: 900), within: bounds) == CGSize(width: 600, height: 338))
        #expect(CoverImage.fittingSize(CGSize(width: 1000, height: 4000), within: bounds) == CGSize(width: 225, height: 900))
        // Small images stay their size; a drawn page is enlarged.
        #expect(CoverImage.fittingSize(CGSize(width: 200, height: 300), within: bounds) == CGSize(width: 200, height: 300))
        #expect(CoverImage.fittingSize(CGSize(width: 200, height: 300), within: bounds, enlarging: true) == CGSize(width: 600, height: 900))
        #expect(CoverImage.fittingSize(.zero, within: bounds) == nil)
        #expect(CoverImage.fittingSize(CGSize(width: CGFloat.infinity, height: 10), within: bounds) == nil)
    }

    @Test func encodedCoversAreSmallJPEGs() throws {
        let source = try #require(CoverImage.jpegData(try Self.image(width: 2400, height: 3600), quality: 1))
        let cover = try #require(CoverImage.encode(imageData: source))
        #expect(try Self.pixelSize(of: cover) == CGSize(width: 600, height: 900))
        #expect(cover.count < 300_000)
        let coverSource = try #require(CGImageSourceCreateWithData(cover as CFData, nil))
        let type = try #require(CGImageSourceGetType(coverSource))
        #expect(type as String == "public.jpeg")
        #expect(CoverImage.isStorable(cover))
    }

    @Test func notAnImageIsNoCover() {
        #expect(CoverImage.encode(imageData: Data("<svg/>".utf8)) == nil)
        #expect(CoverImage.encode(imageData: Data()) == nil)
        #expect(CoverImage.decode(Data([0, 1, 2, 3])) == nil)
        #expect(!CoverImage.isStorable(Data("text".utf8)))
        #expect(!CoverImage.isStorable(Data(count: CoverImage.maxStoredBytes + 1)))
    }

    @Test func widgetThumbnailFitsTheWidget() throws {
        let cover = try #require(CoverImage.jpegData(try Self.image(width: 600, height: 900)))
        let thumbnail = try #require(CoverImage.thumbnail(of: cover))
        #expect(try Self.pixelSize(of: thumbnail) == CGSize(width: 240, height: 360))
    }

    // MARK: - PDF

    /// A one-page PDF: white paper with `art`, a share of its height from
    /// the top, filled with color, and optionally gray lines like text.
    private static func pdfPage(
        width: CGFloat = 612,
        height: CGFloat = 792,
        art: CGFloat,
        textLines: Bool = false
    ) throws -> PDFPage {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(red: 0.1, green: 0.45, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: height * (1 - art), width: width, height: height * art))
        if textLines {
            // Thin dark lines an eighth of the line height, as text inks a page.
            context.setFillColor(gray: 0, alpha: 1)
            for line in stride(from: 60, to: height * (1 - art) - 60, by: 16) {
                context.fill(CGRect(x: 60, y: line, width: width - 120, height: 2))
            }
        }
        context.endPDFPage()
        context.closePDF()
        let document = try #require(PDFDocument(data: data as Data))
        return try #require(document.page(at: 0))
    }

    @Test func aPageOfArtIsTakenAsTheCover() throws {
        let letter = try #require(PDFTextExtractor.coverImage(of: try Self.pdfPage(art: 1), wordCount: 6))
        #expect(try Self.pixelSize(of: letter) == CGSize(width: 600, height: 776))

        // A drawn page is enlarged to the stored size.
        let small = try #require(PDFTextExtractor.coverImage(
            of: try Self.pdfPage(width: 200, height: 300, art: 1), wordCount: 0
        ))
        #expect(try Self.pixelSize(of: small) == CGSize(width: 600, height: 900))

        let landscape = try #require(PDFTextExtractor.coverImage(
            of: try Self.pdfPage(width: 792, height: 612, art: 1), wordCount: 0
        ))
        #expect(try Self.pixelSize(of: landscape) == CGSize(width: 600, height: 464))

        // Art over most of the page, with a white band for the title.
        #expect(PDFTextExtractor.coverImage(of: try Self.pdfPage(art: 0.7), wordCount: 8) != nil)
    }

    @Test func aPageOfPaperKeepsTheGeneratedCover() throws {
        // A blank page, a title page, and a page of text.
        #expect(PDFTextExtractor.coverImage(of: try Self.pdfPage(art: 0), wordCount: 0) == nil)
        #expect(PDFTextExtractor.coverImage(of: try Self.pdfPage(art: 0.2), wordCount: 12) == nil)
        #expect(PDFTextExtractor.coverImage(of: try Self.pdfPage(art: 0, textLines: true), wordCount: 0) == nil)
    }

    @Test func aPageWithManyWordsIsNeverACover() throws {
        let page = try Self.pdfPage(art: 1)
        #expect(PDFTextExtractor.coverImage(of: page, wordCount: CoverImage.maxCoverWords) != nil)
        #expect(PDFTextExtractor.coverImage(of: page, wordCount: CoverImage.maxCoverWords + 1) == nil)
        #expect(PDFTextExtractor.coverImage(of: page, wordCount: 400) == nil)
    }

    @Test func paperIsLightAndWithoutColor() throws {
        func fraction(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Double {
            let context = try #require(CoverImage.makeContext(size: CGSize(width: 120, height: 180)))
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 180))
            let image = try #require(context.makeImage())
            return try #require(CoverImage.paperFraction(of: image))
        }
        #expect(try fraction(red: 1, green: 1, blue: 1) == 1)
        // Text blurred into the page.
        #expect(try fraction(red: 0.85, green: 0.85, blue: 0.85) == 1)
        // Dark, mid-gray, and colored pages are art, light or not.
        #expect(try fraction(red: 0, green: 0, blue: 0) == 0)
        #expect(try fraction(red: 0.5, green: 0.5, blue: 0.5) == 0)
        #expect(try fraction(red: 1, green: 0.9, blue: 0.6) == 0)
        #expect(try fraction(red: 0.1, green: 0.45, blue: 0.5) == 0)
    }

    // MARK: - Sync

    @Test func theBookRecordDeclaresItsCover() {
        #expect(CloudSyncSchema.BookField.all.contains(CloudSyncSchema.BookField.coverImage))
    }

    @Test func uploadsCarryTheCoverAndCountIt() throws {
        let words = WordStorage.encode(["One", "two."])
        let cover = try #require(CoverImage.jpegData(try Self.image(width: 60, height: 90)))
        let id = UUID()
        let without = try BookUpload.prepare(documentID: id, words: words, complexity: nil, chapters: [])
        let with = try BookUpload.prepare(documentID: id, words: words, complexity: nil, coverImage: cover, chapters: [])
        defer {
            for url in [with.wordsURL, with.coverImageURL].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        #expect(without.coverImageURL == nil)
        let url = try #require(with.coverImageURL)
        #expect(try Data(contentsOf: url) == cover)
        #expect(with.byteCount == without.byteCount + cover.count)
    }

    @Test func downloadedCoverRoundTrips() throws {
        let words = WordStorage.encode(["One", "two."])
        let fields = BookRecordFields(
            title: "T", fileName: "t.epub", dateAdded: .now, wordCount: 2, chapters: [],
            contentHash: ContentFingerprint.of(words)
        )
        let cover = try #require(CoverImage.jpegData(try Self.image(width: 60, height: 90)))
        let directory = FileManager.default.temporaryDirectory.appending(path: "covers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wordsURL = directory.appending(path: "words")
        try words.write(to: wordsURL)
        let coverURL = directory.appending(path: "cover")
        try cover.write(to: coverURL)
        let garbageURL = directory.appending(path: "garbage")
        try Data("not an image".utf8).write(to: garbageURL)

        let content = BookContent.load(wordsURL: wordsURL, complexityURL: nil, coverImageURL: coverURL, fields: fields)
        #expect(content?.coverImage == cover)
        #expect(BookContent.load(wordsURL: wordsURL, complexityURL: nil, coverImageURL: garbageURL, fields: fields)?.coverImage == nil)
        #expect(BookContent.load(wordsURL: wordsURL, complexityURL: nil, fields: fields)?.coverImage == nil)
    }

    // MARK: - Widget snapshot

    private static func item(cover: String?) -> ContinueReadingSnapshot.Item {
        ContinueReadingSnapshot.Item(
            id: UUID(uuidString: "5A1F1D00-0000-4000-8000-000000000012")!,
            title: "Book",
            fileName: "Book.epub",
            progress: 0.5,
            chapterTitle: nil,
            remainingMinutes: 30,
            coverFileName: cover
        )
    }

    @Test func snapshotCarriesTheCoverFile() throws {
        let suiteName = "BookCoverTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let id = Self.item(cover: nil).id
        #expect(ContinueReadingSnapshot.Item.coverFileName(for: id, fingerprint: nil)
            == "5A1F1D00-0000-4000-8000-000000000012.jpg")
        // Named for the cover too, so a changed cover is a new file.
        let name = ContinueReadingSnapshot.Item.coverFileName(for: id, fingerprint: "0123456789abcdef0123")
        #expect(name == "5A1F1D00-0000-4000-8000-000000000012-0123456789ab.jpg")
        #expect(name != ContinueReadingSnapshot.Item.coverFileName(for: id, fingerprint: "ffff456789abcdef0123"))
        let snapshot = ContinueReadingSnapshot(item: Self.item(cover: name), libraryIsEmpty: false)
        snapshot.save(to: defaults)
        #expect(ContinueReadingSnapshot.load(from: defaults) == snapshot)
        // A new thumbnail is a change, which reloads the widget.
        #expect(snapshot != ContinueReadingSnapshot(item: Self.item(cover: nil), libraryIsEmpty: false))
    }

    @Test func snapshotSavedBeforeCoversLoads() throws {
        let json = Data("""
        {"libraryIsEmpty":false,"item":{"id":"5A1F1D00-0000-4000-8000-000000000012","title":"Book",
        "fileName":"Book.epub","progress":0.5,"remainingMinutes":30}}
        """.utf8)
        let snapshot = try JSONDecoder().decode(ContinueReadingSnapshot.self, from: json)
        #expect(snapshot.item?.coverFileName == nil)
        #expect(snapshot.item?.loadCover() == nil)
    }

    // MARK: - Decoding for display

    @MainActor
    @Test func coversDecodeForDrawing() async throws {
        let cover = try #require(CoverImage.jpegData(try Self.image(width: 60, height: 90)))
        let document = Document(title: "Covered", fileName: "c.epub", bookmarkData: Data(), words: ["One"])
        document.coverImageData = cover
        let image = try #require(await CoverImageCache.shared.load(document))
        #expect(image.width == 60 && image.height == 90)
        let shown = CoverImageCache.shared.cover(for: document)
        #expect(shown.image != nil)
        #expect(!shown.isPending)

        let plain = Document(title: "Plain", fileName: "p.txt", bookmarkData: Data(), words: ["One"])
        #expect(await CoverImageCache.shared.load(plain) == nil)
        #expect(CoverImageCache.shared.cover(for: plain).image == nil)
        #expect(!CoverImageCache.shared.cover(for: plain).isPending)
    }
}
