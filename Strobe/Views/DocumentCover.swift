import SwiftUI

/// A book cover: the book's own when it has one (`artwork`), cropped to
/// fill, or else a generated one: the document's title set in Fraunces on a
/// deep tone chosen from its ID, a spine along the leading edge, and the
/// file kind at the foot. Sized by the width it's given, at a 2:3 ratio.
///
/// The widget extension compiles this file too, so it takes plain values;
/// the app's `init(document:)` is in LibraryTiles.swift.
struct DocumentCover: View {
    let title: String
    let kind: DocumentKind
    let tone: CoverTone
    /// False for a thumbnail shown beside the title: the tone and spine only.
    var showsText = true
    /// The book's own cover, drawn in place of the generated one.
    let artwork: CGImage?

    init(title: String, kind: DocumentKind, tone: CoverTone, showsText: Bool = true, artwork: CGImage? = nil) {
        self.title = title
        self.kind = kind
        self.tone = tone
        self.showsText = showsText
        self.artwork = artwork
    }

    private static let cornerRadius: CGFloat = 4

    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    if let artwork {
                        Image(decorative: artwork, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    } else {
                        face(width: geo.size.width)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }

    private func face(width: CGFloat) -> some View {
        let spine = max(3, width * 0.045)
        let inset = width * 0.09
        // Thumbnails keep only the title; the rule and label would be specks.
        let isThumbnail = width < 90

        return ZStack(alignment: .topLeading) {
            tone.background

            LinearGradient(
                colors: [.white.opacity(0.07), .clear, .black.opacity(0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(spacing: 0) {
                Rectangle()
                    .fill(.black.opacity(0.28))
                    .frame(width: spine)
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 1)
                Spacer(minLength: 0)
            }

            if showsText {
                coverText(width: width, spine: spine, inset: inset, isThumbnail: isThumbnail)
            }
        }
    }

    private func coverText(width: CGFloat, spine: CGFloat, inset: CGFloat, isThumbnail: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(StrobeTheme.displayFont(fixedSize: width * 0.13))
                .foregroundStyle(CoverTone.ink)
                .lineLimit(6)
                .minimumScaleFactor(0.5)
                .multilineTextAlignment(.leading)

            if !isThumbnail {
                Rectangle()
                    .fill(CoverTone.ink.opacity(0.35))
                    .frame(width: width * 0.14, height: 1)
                    .padding(.top, width * 0.07)
            }

            Spacer(minLength: 0)

            if !isThumbnail {
                Text(kind.label)
                    .font(.system(size: max(7, width * 0.065), weight: .semibold))
                    .tracking(width * 0.012)
                    .foregroundStyle(CoverTone.ink.opacity(0.55))
            }
        }
        .padding(.leading, spine + inset)
        .padding(.trailing, inset)
        .padding(.vertical, inset)
    }
}

/// The background of a generated cover, from a palette of deep, muted
/// tones that all carry the same light ink.
nonisolated struct CoverTone: Equatable {
    let rgb: UInt32

    var background: Color { Self.color(rgb) }

    /// The title and label color on every tone.
    static let ink = color(0xF4ECE1)

    /// Kept clear of the accent red, which marks reading progress.
    static let palette: [CoverTone] = [
        CoverTone(rgb: 0x4A1C2A), // wine
        CoverTone(rgb: 0x1C2B44), // ink blue
        CoverTone(rgb: 0x1E3B30), // forest
        CoverTone(rgb: 0x3D2344), // plum
        CoverTone(rgb: 0x4B3424), // tobacco
        CoverTone(rgb: 0x16393D), // deep teal
        CoverTone(rgb: 0x2E343B), // slate
        CoverTone(rgb: 0x3F3D1E), // olive
        CoverTone(rgb: 0x221F40), // indigo
        CoverTone(rgb: 0x4F2C1C), // rust
        CoverTone(rgb: 0x2A3A22), // moss
        CoverTone(rgb: 0x3A2A33), // mauve
    ]

    static func tone(for id: UUID) -> CoverTone {
        palette[index(for: id)]
    }

    /// A palette index derived from the UUID's bytes (FNV-1a), so a document
    /// keeps its color across launches — `UUID.hashValue` is reseeded on
    /// every launch.
    static func index(for id: UUID) -> Int {
        var hash: UInt32 = 2_166_136_261
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes {
                hash = (hash ^ UInt32(byte)) &* 16_777_619
            }
        }
        return Int(hash % UInt32(palette.count))
    }

    private static func color(_ rgb: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double(rgb >> 16 & 0xFF) / 255,
            green: Double(rgb >> 8 & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
