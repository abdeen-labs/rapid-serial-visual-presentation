import Foundation

/// The color choices for the ORP anchor letter and the marks that follow it:
/// the anchor's guide line, the chapter announcement's rule, and the passage
/// view's current word.
///
/// Each choice is tuned per ``ReaderTextTone`` the way the original red is:
/// vivid on `bright`, where the word is white, and muted on `soft`, `sepia`,
/// and `night`, where a vivid letter would glare out of a quiet word. The
/// muted values sit near the red's perceived lightness on that tone (OKLab L)
/// with about two-thirds of their bright saturation, as the red does, so each
/// stands out from the word about as much as the red without outshining it,
/// and keeps at least 3:1 against both reader backgrounds. Yellow isn't
/// offered: muted, it turns olive and nearly matches sepia and night text,
/// and the passage view already marks search matches in yellow.
nonisolated enum ReaderHighlightColor: String, CaseIterable, Identifiable {
    /// The UserDefaults key used to persist the highlight color selection.
    static let storageKey = "readerHighlightColor"
    static let defaultValue: ReaderHighlightColor = .red

    case red
    case orange
    case green
    case teal
    case blue
    case purple
    case pink

    var id: String { rawValue }

    /// Resolves a stored raw value to a color case, falling back to the default.
    static func resolve(_ rawValue: String) -> ReaderHighlightColor {
        ReaderHighlightColor(rawValue: rawValue) ?? defaultValue
    }

    var displayName: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .green: "Green"
        case .teal: "Teal"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        }
    }

    /// This color as tuned for `tone`.
    func rgb(on tone: ReaderTextTone) -> UInt32 {
        switch tone {
        case .bright: palette.bright
        case .soft: palette.soft
        case .sepia: palette.sepia
        case .night: palette.night
        }
    }

    private var palette: (bright: UInt32, soft: UInt32, sepia: UInt32, night: UInt32) {
        switch self {
        // The anchor colors from before the choice existed.
        case .red: (0xFF453A, 0xC8554D, 0xCC5A45, 0xA8402F)
        // Burnt orange on the muted tones, turned slightly toward red and kept
        // more saturated: sepia and night text are warm too, and a yellower or
        // duller orange blends into them.
        case .orange: (0xFF9F0A, 0xBD7221, 0xC1711F, 0x9C5301)
        case .green: (0x30D158, 0x3B944B, 0x3E984E, 0x247A36)
        // Keeps more of its saturation than the others when muted, since it
        // starts out paler and would otherwise turn gray beside soft text.
        case .teal: (0x40C8E0, 0x22909E, 0x2793A1, 0x027582)
        // Lighter than the system blue on bright: a deep blue letter is hard
        // to make out on black.
        case .blue: (0x409CFF, 0x4B82C0, 0x4E85C4, 0x3669A2)
        case .purple: (0xBF5AF2, 0x9D60BF, 0xA163C3, 0x824AA0)
        // Toward magenta, so it doesn't read as a second red.
        case .pink: (0xFF6AC1, 0xB75A8E, 0xBB5D92, 0x994474)
        }
    }

    /// Whether a word drawn on this color as a fill, like the passage view's
    /// current word, should be black rather than white. White stays unless it
    /// falls under 3:1, as it does on the lighter vivid colors of `bright`.
    func prefersDarkText(on tone: ReaderTextTone) -> Bool {
        // White reaches 3:1 on a fill whose luminance is at most 1.05 / 3 − 0.05.
        Self.relativeLuminance(of: rgb(on: tone)) > 0.3
    }

    /// WCAG relative luminance of an sRGB color.
    private static func relativeLuminance(of rgb: UInt32) -> Double {
        func linear(_ channel: UInt32) -> Double {
            let value = Double(channel & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb >> 16) + 0.7152 * linear(rgb >> 8) + 0.0722 * linear(rgb)
    }
}
