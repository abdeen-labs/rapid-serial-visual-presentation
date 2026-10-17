import SwiftUI

/// A quiet chapter break with its own type scale, independent of RSVP word size.
struct ChapterAnnouncementView: View {
    let title: String
    @AppStorage(ReaderTextTone.storageKey) private var readerTextToneSelection = ReaderTextTone.defaultValue.rawValue
    @AppStorage(ReaderHighlightColor.storageKey) private var readerHighlightColorSelection = ReaderHighlightColor.defaultValue.rawValue

    var body: some View {
        let parts = titleParts
        let tone = ReaderTextTone.resolve(readerTextToneSelection)
        let highlight = ReaderHighlightColor.resolve(readerHighlightColorSelection)

        VStack(spacing: 14) {
            if let label = parts.label {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .tracking(2)
                    .textCase(.uppercase)
                    .foregroundStyle(StrobeTheme.textSecondary)
                    .lineLimit(2)
            }

            Text(parts.heading)
                .font(ReaderFont.fraunces.regularFont(size: 34, relativeTo: .title))
                .foregroundStyle(tone.textColor.opacity(0.94))
                .lineSpacing(4)
                .lineLimit(4)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)

            Capsule()
                .fill(tone.anchorColor(for: highlight).opacity(0.8))
                .frame(width: 24, height: 2)
                .padding(.top, 8)
                .accessibilityHidden(true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .padding(.horizontal, 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }

    /// Give explicit labels like "Chapter Twelve:" their own line. Leave
    /// ordinary titles and unrecognized languages intact rather than guessing.
    private var titleParts: (label: String?, heading: String) {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let labels: Set<String> = ["chapter", "part", "section", "book", "volume", "prologue", "epilogue", "interlude"]
        guard let firstWord = normalized.split(whereSeparator: { $0.isWhitespace || $0 == ":" }).first,
              labels.contains(firstWord.lowercased()),
              let separator = normalized.firstIndex(where: { $0 == ":" || $0 == "—" }) else {
            return (nil, normalized)
        }
        let label = normalized[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = normalized[normalized.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heading.isEmpty else { return (nil, normalized) }
        return (label, heading)
    }
}
