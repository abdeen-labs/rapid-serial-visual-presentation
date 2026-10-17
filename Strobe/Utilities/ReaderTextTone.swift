import SwiftUI

/// The available color tones for the RSVP reader display.
///
/// Each case sets the word color, and each ``ReaderHighlightColor`` is tuned
/// for it, so the ORP anchor letter stays distinguishable from the rest of
/// the word in every tone.
nonisolated enum ReaderTextTone: String, CaseIterable, Identifiable {
    /// The UserDefaults key used to persist the tone selection.
    static let storageKey = "readerTextTone"
    static let defaultValue: ReaderTextTone = .bright

    case bright
    case soft
    case sepia
    case night

    var id: String { rawValue }

    /// Resolves a stored raw value to a tone case, falling back to the default.
    static func resolve(_ rawValue: String) -> ReaderTextTone {
        ReaderTextTone(rawValue: rawValue) ?? defaultValue
    }

    var displayName: String {
        switch self {
        case .bright: "Bright"
        case .soft: "Soft"
        case .sepia: "Sepia"
        case .night: "Night"
        }
    }

    var textRGB: UInt32 {
        switch self {
        case .bright: 0xFFFFFF
        case .soft: 0xB4B4B4
        case .sepia: 0xD6C2A1
        case .night: 0x9C8466
        }
    }

    /// How far `textColor` fades for quiet orientation text on the reading
    /// surface. Tuned per tone to land near 3:1 contrast against the reader
    /// background in each — one shared opacity would leave `night` illegible
    /// or `bright` too loud.
    var fadedTextOpacity: Double {
        switch self {
        case .bright: 0.35
        case .soft: 0.5
        case .sepia: 0.45
        case .night: 0.65
        }
    }

    /// How far `textColor` fades for text meant to be seen but not read, like
    /// context words during playback. Tuned per tone to land near 1.3:1
    /// contrast against the reader background.
    var dimTextOpacity: Double {
        switch self {
        case .bright: 0.13
        case .soft: 0.18
        case .sepia: 0.17
        case .night: 0.24
        }
    }

    /// The color of the word being read.
    var textColor: Color { Self.color(textRGB) }

    /// The color of the ORP anchor letter and its guide line: the chosen
    /// highlight color as tuned for this tone.
    func anchorColor(for highlight: ReaderHighlightColor) -> Color {
        Self.color(highlight.rgb(on: self))
    }

    /// The color of a word drawn on an `anchorColor(for:)` fill, like the
    /// passage view's current word.
    func textColorOnAnchor(for highlight: ReaderHighlightColor) -> Color {
        highlight.prefersDarkText(on: self) ? .black : .white
    }

    /// A low-contrast `textColor` for text that must never compete with the word.
    var fadedTextColor: Color { textColor.opacity(fadedTextOpacity) }

    private static func color(_ rgb: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double(rgb >> 16 & 0xFF) / 255,
            green: Double(rgb >> 8 & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
