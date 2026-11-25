import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Looking the current word up in the system dictionary, from the paused
/// reader's Look Up button: a sheet over the reader on iOS, the Dictionary
/// app on macOS.
nonisolated enum DictionaryLookup {
    /// A term being looked up, for the sheet that shows it.
    struct Term: Identifiable, Hashable {
        let text: String
        var id: String { text }
    }

    /// What to look up for a stored word: the word without the marks
    /// around it (`“Hello,”` → `Hello`, `elements—` → `elements`), or nil
    /// for a word with no letters, such as a number or a lone dash. Marks
    /// inside the word stay (`don’t`, `wedge-shaped`), and an abbreviation
    /// keeps its last period (`e.g.`, `U.S.`), which its entry is under.
    /// A number unit gives its designator (`2000 BCE` → `BCE`). The
    /// dictionary matches inflected forms itself.
    static func term(for word: String) -> String? {
        // Only a number unit has a space in it.
        if word.contains(" ") {
            return word.split(separator: " ").lazy.compactMap { Self.term(for: String($0)) }.first
        }
        guard let first = word.firstIndex(where: isWordCharacter),
              let last = word.lastIndex(where: isWordCharacter) else { return nil }
        var core = String(word[first...last])
        guard core.contains(where: \.isLetter) else { return nil }
        if word[word.index(after: last)...].first == ".", isAbbreviation(core) {
            core.append(".")
        }
        return core
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// Whether `term`, trimmed of the marks around it, is letters in ones
    /// and twos with periods between: `e.g`, `U.S.A`, `Ph.D`, but not
    /// `example.com` or `3.14`.
    private static func isAbbreviation(_ term: String) -> Bool {
        let parts = term.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count > 1 && parts.allSatisfy { part in
            (1...2).contains(part.count) && part.allSatisfy(\.isLetter)
        }
    }

    #if os(macOS)
    /// Opens the Dictionary app at `term`.
    @MainActor
    static func open(_ term: String) {
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "dict://\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }
    #endif
}

#if os(iOS)
/// The system dictionary's page for a term, with its own Done button and
/// its link to manage dictionaries when none defines the term.
struct DictionaryLookupSheet: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }

    func updateUIViewController(_ controller: UIReferenceLibraryViewController, context: Context) {}
}
#endif

/// The reader's Look Up button, for the word showing while paused. Dimmed
/// where there is nothing to look up: a word with no letters, or the
/// finished card in the word's place.
struct LookUpButton: View {
    let engine: RSVPEngine
    /// Whether the word shows, rather than the finished card.
    let showsWord: Bool
    let action: (String) -> Void

    var body: some View {
        // The word is read only while paused, so the button, hidden with
        // its bar while words play, isn't drawn again for every one.
        let term = engine.isPlaying || !showsWord ? nil : DictionaryLookup.term(for: engine.currentWord)
        ReaderGlassButton(systemImage: "character.book.closed", accessibilityLabel: "Look Up") {
            if let term { action(term) }
        }
        .disabled(term == nil)
        .accessibilityValue(term ?? "")
    }
}
