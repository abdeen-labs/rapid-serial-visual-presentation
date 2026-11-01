import Foundation

/// The words on either side of the current one, shown beside it when
/// context words are on.
nonisolated enum ContextWords {
    struct Neighbors: Equatable {
        let previous: String?
        let next: String?

        /// These neighbours with the side `sides` leaves out removed.
        func showing(_ sides: Sides) -> Neighbors {
            Neighbors(
                previous: sides == .next ? nil : previous,
                next: sides == .previous ? nil : next
            )
        }
    }

    /// Which neighbours show.
    enum Sides: String, CaseIterable, Identifiable {
        /// The UserDefaults key used to persist the choice.
        static let storageKey = "contextWordsSides"
        static let defaultValue: Sides = .both

        case both
        case previous
        case next

        var id: String { rawValue }

        /// Resolves a stored raw value to a case, falling back to the default.
        static func resolve(_ rawValue: String) -> Sides {
            Sides(rawValue: rawValue) ?? defaultValue
        }

        var displayName: String {
            switch self {
            case .both: "Both"
            case .previous: "Previous"
            case .next: "Next"
            }
        }
    }

    /// The words on either side of `index` that `sides` shows: nil past
    /// either end of the document, and on both sides for an index outside it.
    static func neighbors(of index: Int, in words: [String], sides: Sides = .both) -> Neighbors {
        guard words.indices.contains(index) else {
            return Neighbors(previous: nil, next: nil)
        }
        return Neighbors(
            previous: index > 0 ? words[index - 1] : nil,
            next: index + 1 < words.count ? words[index + 1] : nil
        ).showing(sides)
    }

    /// The neighbours' opacity, as a fraction of the tone's text color: at
    /// the opacity setting's `level` (``ReaderTextTone/opacity(level:)``)
    /// while words play, and never fainter than the tone's faded text while
    /// paused, so they can always be read then.
    static func opacity(isPlaying: Bool, level: Double, tone: ReaderTextTone) -> Double {
        let playing = tone.opacity(level: level)
        return isPlaying ? playing : max(playing, tone.fadedTextOpacity)
    }
}
