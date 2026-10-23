import Foundation
import NaturalLanguage

/// The language a document is written in, so reading aloud can tell the
/// documents its voices speak (``KokoroVoices/canRead(documentLanguage:)``).
nonisolated enum DocumentLanguage {
    /// How many words from the start are read to tell: plenty to be sure,
    /// and quick even for a long book.
    static let sampleWordCount = 2_000

    /// How sure the guess has to be. A few words can look like several
    /// languages ("Gift" is Swedish too), and a wrong guess would keep an
    /// English document from being read aloud, where no guess reads it.
    static let minimumConfidence = 0.5

    /// The language most of the first ``sampleWordCount`` words are in, as
    /// a BCP-47 code (`en`, `fr`, `zh-Hans`), or nil when there's too little
    /// text to tell.
    static func detect(in words: [String]) -> String? {
        let sample = words.prefix(sampleWordCount).joined(separator: " ")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first,
              best.key != .undetermined,
              best.value >= minimumConfidence else { return nil }
        return best.key.rawValue
    }
}
