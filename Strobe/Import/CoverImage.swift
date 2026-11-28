import CoreGraphics
import Foundation
import ImageIO

/// A document's cover as stored: a JPEG that fits within ``maxSize``, so a
/// book's cover costs about 100 KB on disk and in iCloud.
///
/// Plain ImageIO and Core Graphics, the same on iOS and macOS and safe off
/// the main actor, where imports and decoding run.
nonisolated enum CoverImage {
    /// The largest cover stored, in pixels: 2:3 like the library's covers,
    /// and sharp at the size the book page and Now Playing draw it.
    static let maxSize = CGSize(width: 600, height: 900)

    /// The widget's thumbnail, in pixels: its largest cover is 80 points
    /// wide.
    static let widgetThumbnailSize = CGSize(width: 240, height: 360)

    static let jpegQuality = 0.8

    /// Image files larger than this aren't read as a cover.
    static let maxSourceBytes = 40 << 20
    /// Images with more pixels than this aren't decoded: a crafted image
    /// with huge dimensions would take the import's memory.
    static let maxSourcePixels = 40_000_000
    /// A synced cover larger than this isn't one Strobe wrote.
    static let maxStoredBytes = 2 << 20

    /// The size an image of `size` takes to fit within `bounds`, keeping its
    /// shape, in whole pixels. Only a vector source (a PDF page) is
    /// `enlarging`. Nil for a size too small or not finite.
    static func fittingSize(_ size: CGSize, within bounds: CGSize, enlarging: Bool = false) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else { return nil }
        var scale = min(bounds.width / size.width, bounds.height / size.height)
        if !enlarging { scale = min(scale, 1) }
        return CGSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )
    }

    /// An image file's data, in any format ImageIO reads, as a stored cover.
    /// Nil when it isn't an image, or is too large to read.
    static func encode(imageData data: Data) -> Data? {
        guard let image = downsampledImage(from: data, maxPixelSize: maxSize) else { return nil }
        return encode(image)
    }

    /// Draws `image` to fit within `bounds` on an opaque canvas, where a
    /// transparent cover's clear parts turn white, and encodes it as JPEG.
    static func encode(_ image: CGImage, within bounds: CGSize = maxSize) -> Data? {
        guard let size = fittingSize(CGSize(width: image.width, height: image.height), within: bounds),
              let context = makeContext(size: size) else { return nil }
        let rect = CGRect(origin: .zero, size: size)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let drawn = context.makeImage() else { return nil }
        return jpegData(drawn)
    }

    /// A stored cover decoded for drawing. Nil when the data isn't an image.
    static func decode(_ data: Data) -> CGImage? {
        downsampledImage(from: data, maxPixelSize: maxSize)
    }

    /// A stored cover made smaller, for the widget.
    static func thumbnail(of data: Data, within bounds: CGSize = widgetThumbnailSize) -> Data? {
        guard let image = downsampledImage(from: data, maxPixelSize: bounds) else { return nil }
        return encode(image, within: bounds)
    }

    /// Whether synced data can be kept as a cover: small enough to be one
    /// Strobe wrote, and an image ImageIO reads.
    static func isStorable(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maxStoredBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0 && CGImageSourceGetType(source) != nil
    }

    // MARK: - A page as a cover

    /// The most words a page taken for a cover has: a title, an author, a
    /// line or two. A page of text has many times that.
    static let maxCoverWords = 40
    /// The most of a cover that can look like paper. A page of text is
    /// nearly all paper, and so is a title page; cover art is not.
    static let maxPaperFraction = 0.5

    /// Whether a PDF's first page, drawn as `image`, looks like a cover
    /// rather than a page of text: few words, and mostly art, not paper.
    /// A PDF declares no cover, so this is a judgment by looks. It errs
    /// toward the generated cover: a plain white cover is passed over,
    /// which shows the generated one, and a full-page picture is taken.
    static func looksLikeCover(_ image: CGImage, wordCount: Int) -> Bool {
        guard wordCount <= maxCoverWords, let paper = paperFraction(of: image) else { return false }
        return paper <= maxPaperFraction
    }

    /// The share of an image that looks like paper: light and without
    /// color. Measured on a small copy, where lines of text blur into the
    /// page as light gray and count as paper too.
    static func paperFraction(of image: CGImage) -> Double? {
        guard let context = makeContext(size: CGSize(width: 60, height: 90)), let pixels = context.data else {
            return nil
        }
        let width = context.width
        let height = context.height
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Averaged, so thin lines of text blur rather than land on a pixel or miss it.
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = pixels.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        var paper = 0
        for y in 0..<height {
            let row = y * context.bytesPerRow
            for x in 0..<width {
                let red = Int(bytes[row + x * 4])
                let green = Int(bytes[row + x * 4 + 1])
                let blue = Int(bytes[row + x * 4 + 2])
                let lightest = max(red, green, blue)
                let darkest = min(red, green, blue)
                if darkest >= 185, lightest - darkest <= 30 { paper += 1 }
            }
        }
        return Double(paper) / Double(width * height)
    }

    /// An opaque sRGB bitmap of `size` pixels.
    static func makeContext(size: CGSize) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    }

    /// `image` as JPEG data.
    static func jpegData(_ image: CGImage, quality: Double = jpegQuality) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The image in `data`, decoded no larger than `maxPixelSize`'s longer
    /// side and turned upright. ImageIO reads only as much of a large JPEG
    /// as that size needs.
    private static func downsampledImage(from data: Data, maxPixelSize: CGSize) -> CGImage? {
        guard !data.isEmpty, data.count <= maxSourceBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxSourcePixels else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(maxPixelSize.width, maxPixelSize.height)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
