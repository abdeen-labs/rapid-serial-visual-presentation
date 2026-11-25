import Foundation

/// Finds the sentence ends that ``RSVPEngine`` follows with a blank screen
/// when sentence breaks are on.
///
/// A punctuation pause can afford to land on every period, but a blank in the
/// middle of a sentence (`Mr.`, blank, `Smith`) splits it in two. So besides
/// the sentence-end mark ``PunctuationMarks`` finds, a sentence end here needs
/// a word that is not an abbreviation and a next word that starts the way a
/// sentence does.
nonisolated enum SentenceBreak {

    /// Whether a sentence ends with the word at `index`, judged together with
    /// the word after it. Always `false` for the last word.
    ///
    /// - The word must end a sentence by ``PunctuationMarks``: `. ! ?` or a
    ///   CJK or Arabic sentence mark, with nothing after it but closing quotes,
    ///   brackets, or an ellipsis. A bare ellipsis (`wait...`) trails off
    ///   instead.
    /// - The next word must start with a capital, or with a letter of a script
    ///   that has no capitals (CJK, Hangul, Arabic), looking past opening
    ///   quotes and brackets: `"Why?" she asked` is one sentence. A digit
    ///   starts a sentence too, except after a word that ends in a bare
    ///   period: `No. 5`, `Vol. 3`, and `ca. 1500` continue.
    /// - A period straight after the word's last letter or digit must not
    ///   close an abbreviation or a list label:
    ///   - an initial, a capital on its own (`J.`, `F.`), or a single Arabic
    ///     letter (`د.`);
    ///   - a dotted abbreviation (`U.S.`, `e.g.`, `Ph.D.`, `a.m.`);
    ///   - a title or other short form that stands before a name or a number
    ///     (`Mr.`, `Dr.`, `St.`, `Inc.`, `vs.`, `et al.`, `Vol.`);
    ///   - a list label: a word of one or two digits or a single lowercase
    ///     letter, right after a sentence end or colon (`follows: 1. Open`).
    ///     Elsewhere a number or letter is the sentence's last word
    ///     (`born in 1985.`, `the wage w.`).
    ///
    ///   Only the text after the word's last hyphen, dash, or slash counts
    ///   (`J.-P.` is an initial, `U.S.-based.` is not an abbreviation). A
    ///   period after a closing mark (`etc.).`, `U.S.”`) ends the sentence.
    static func endsSentence(at index: Int, in words: [String]) -> Bool {
        guard index >= 0, index + 1 < words.count,
              let last = words[index].unicodeScalars.last,
              !isWordEnding(last) else { return false }
        return scanSentenceEnd(at: index, in: words)
    }

    /// Kept out of line so ``endsSentence(at:in:)`` stays a single check of the
    /// last character for words that end in a letter, digit, clause mark, or
    /// dash, which is most of them.
    @inline(never)
    private static func scanSentenceEnd(at index: Int, in words: [String]) -> Bool {
        let word = words[index]
        guard PunctuationMarks.marks(in: word).contains(.sentenceEnd) else { return false }
        let afterPeriod = endsInBarePeriod(word)
        if afterPeriod {
            let part = periodClosedPart(of: word)
            if isAbbreviation(part) { return false }
            if part.startIndex == word.unicodeScalars.startIndex, isListLabel(part),
               index == 0 || endsSentenceOrIntroducesList(words[index - 1]) {
                return false
            }
        }
        return startsSentence(words[index + 1], afterPeriod: afterPeriod)
    }

    /// Whether `word` ends in a period that directly follows a letter or digit,
    /// the only place an abbreviation's period can be.
    private static func endsInBarePeriod(_ word: String) -> Bool {
        var scalars = word.unicodeScalars.reversed().makeIterator()
        guard scalars.next() == ".", let previous = scalars.next() else { return false }
        return isLetterOrDigit(previous)
    }

    /// The text a word's final period closes: after its last hyphen, dash, or
    /// slash and any opening marks, without the period. `“Dr.` gives `Dr`,
    /// `non-U.S.` gives `U.S`, and `J.-P.` gives `P`.
    private static func periodClosedPart(of word: String) -> Substring.UnicodeScalarView {
        let scalars = word.unicodeScalars
        let end = scalars.index(before: scalars.endIndex)
        var start = end
        while start > scalars.startIndex, !isSeparator(scalars[scalars.index(before: start)]) {
            start = scalars.index(before: start)
        }
        while start < end, !isLetterOrDigit(scalars[start]) {
            start = scalars.index(after: start)
        }
        return scalars[start..<end]
    }

    private static func isAbbreviation(_ part: Substring.UnicodeScalarView) -> Bool {
        guard let first = part.first else { return false }
        if part.index(after: part.startIndex) == part.endIndex, isInitial(first) { return true }
        return isDottedAbbreviation(part) || abbreviations.contains(String(part))
    }

    /// Whether `scalar`, alone before a period, is an initial: a capital, or
    /// an Arabic letter (`د.` for Dr.). A capital on its own stands for a name
    /// far more often than it ends a sentence (`Plan B.`).
    private static func isInitial(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .titlecaseLetter:
            return true
        case .otherLetter:
            return (0x0600...0x06FF).contains(scalar.value)
        default:
            return false
        }
    }

    /// Letters in groups of at most three split by periods: `U.S`, `e.g`,
    /// `Ph.D`, `a.m`. A web address or file name (`example.com`) has longer
    /// groups, and a decimal (`0.2`) has digits.
    private static func isDottedAbbreviation(_ part: Substring.UnicodeScalarView) -> Bool {
        var hasPeriod = false
        var groupLength = 0
        for scalar in part {
            if scalar == "." {
                guard groupLength > 0 else { return false }
                hasPeriod = true
                groupLength = 0
            } else if isLetter(scalar) {
                groupLength += 1
                guard groupLength <= 3 else { return false }
            } else {
                return false
            }
        }
        return hasPeriod && groupLength > 0
    }

    /// Whether `part` has the shape of a list or section label: a lowercase
    /// letter (`b`) or numbers of one or two digits split by periods (`2`,
    /// `12`, `1.2`). A year or page number (`1985`, `166`) doesn't.
    private static func isListLabel(_ part: Substring.UnicodeScalarView) -> Bool {
        guard let first = part.first else { return false }
        if part.index(after: part.startIndex) == part.endIndex,
           first.properties.generalCategory == .lowercaseLetter {
            return true
        }
        var groupLength = 0
        for scalar in part {
            switch scalar {
            case "0"..."9":
                groupLength += 1
                guard groupLength <= 2 else { return false }
            case "." where groupLength > 0:
                groupLength = 0
            default:
                return false
            }
        }
        return groupLength > 0
    }

    /// Whether `word` ends a sentence or with a colon, the two places a list
    /// label follows.
    private static func endsSentenceOrIntroducesList(_ word: String) -> Bool {
        switch word.unicodeScalars.last {
        case ":", "\u{FF1A}":                     // ： fullwidth
            return true
        default:
            return PunctuationMarks.marks(in: word).contains(.sentenceEnd)
        }
    }

    /// Whether `word` starts the way a sentence does. `afterPeriod` rules out
    /// a digit, which after a period is usually a number that the
    /// abbreviation before it introduces.
    private static func startsSentence(_ word: String, afterPeriod: Bool) -> Bool {
        for scalar in word.unicodeScalars {
            switch scalar {
            case "A"..."Z":
                return true
            case "a"..."z":
                return false
            case "0"..."9":
                return !afterPeriod
            case "\u{0}"..."\u{7F}":
                continue
            default:
                switch scalar.properties.generalCategory {
                case .uppercaseLetter, .titlecaseLetter:
                    return true
                case .otherLetter:
                    return !isQuotativeParticle(word)
                case .lowercaseLetter:
                    return false
                case .decimalNumber, .letterNumber, .otherNumber:
                    return !afterPeriod
                default:
                    continue
                }
            }
        }
        return false
    }

    /// Whether `word` is the Japanese particle that ties a quotation to the
    /// rest of its sentence (`「元気？」と彼は言った`), the counterpart of
    /// the lowercase in `"Why?" she asked` in a script without capitals.
    private static func isQuotativeParticle(_ word: String) -> Bool {
        var scalars = word.unicodeScalars.makeIterator()
        switch scalars.next() {
        case "\u{3068}":                          // と
            break
        case "\u{3063}":                          // っ, as in って
            guard scalars.next() == "\u{3066}" else { return false }
        default:
            return false
        }
        // Only punctuation may follow, as in `と、`.
        while let scalar = scalars.next() {
            if isLetter(scalar) { return false }
        }
        return true
    }

    /// Short forms written with a period that usually stand before a
    /// capitalized name or noun, where the capital can't mark a new sentence.
    /// Forms that often end a sentence (`etc.`, `No.`) are left out.
    private static let abbreviations: Set<String> = {
        // Also in capitals, as in a heading or a book's opening line in
        // small capitals: `MR. AND MRS. JONES`.
        let titles = ["Mr", "Mrs", "Ms", "Dr", "Prof", "Rev", "St", "Jr", "Sr"]
        let forms = [
            "Mx", "Messrs", "Mmes", "Drs", "Fr", "Hon", "Rt", "Sen", "Rep", "Gov", "Pres",
            "Gen", "Adm", "Capt", "Cmdr", "Col", "Lt", "Maj", "Sgt", "Cpl", "Pvt",
            "Msgr", "Mgr", "Mme", "Mlle", "Sra", "Srta", "Dra", "Sig", "Dott",
            "Ste", "Mt", "Ft", "Inc", "Ltd", "Co", "Corp", "Bros",
            "vs", "v", "cf", "Cf", "viz", "al", "ed", "eds", "trans",
            "Vol", "Vols", "Fig", "Figs", "Ch", "Chap", "Sec", "Eq", "Eqs",
            "bzw", "vgl", "ggf", "sog", "evtl", "inkl", "ca",
        ]
        return Set(titles + titles.map { $0.uppercased() } + forms)
    }()

    /// Characters no sentence end can come before in the same word: letters,
    /// digits, and the common clause marks and dashes.
    @inline(__always)
    private static func isWordEnding(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", ",", ";", ":", "-",
             "\u{2013}", "\u{2014}":              // – —
            return true
        case "\u{0}"..."\u{7F}":
            return false
        default:
            return isLetterOrDigit(scalar)
        }
    }

    @inline(__always)
    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "-", "/", "\u{2010}"..."\u{2015}":   // ‐ ‑ ‒ – — ―
            return true
        default:
            return false
        }
    }

    @inline(__always)
    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z":
            return true
        case "\u{0}"..."\u{7F}":
            return false
        default:
            return scalar.properties.isAlphabetic
        }
    }

    @inline(__always)
    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9":
            return true
        case "\u{0}"..."\u{7F}":
            return false
        default:
            return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
        }
    }

    // MARK: - Rereading

    /// The furthest back a sentence's start is looked for. Text with no
    /// sentence ends in it, such as verse or a list imported without its
    /// blocks, goes back this many words instead.
    static let longestSentence = 200

    /// How far into a sentence going back still means the sentence before:
    /// by the time a reader lets go to reread one, the next has begun.
    static let nearStart = 2

    /// The index of the first word of the sentence the word at `index` is
    /// in: a chapter's first word, or the word after the nearest sentence
    /// end (``endsSentence(at:in:)``) or pausing block end before it, or
    /// else the document's first. Looks back ``longestSentence`` words at
    /// most.
    static func sentenceStart(
        at index: Int,
        in words: [String],
        blockEnds: BlockEnds = .none,
        startsChapter: (Int) -> Bool = { _ in false }
    ) -> Int {
        guard !words.isEmpty else { return 0 }
        var start = max(0, min(index, words.count - 1))
        let earliest = max(0, start - longestSentence)
        while start > earliest {
            if startsChapter(start)
                || endsSentence(at: start - 1, in: words)
                || blockEnds.pause(after: start - 1, in: words) == .block {
                break
            }
            start -= 1
        }
        return start
    }

    /// Where rereading from the word at `index` goes back to: the first
    /// word of its sentence, or, within ``nearStart`` words of that, the
    /// first word of the sentence before, so going back again steps back a
    /// sentence at a time. Nil at the document's first word, with nowhere
    /// to go back to.
    static func rereadStart(
        from index: Int,
        in words: [String],
        blockEnds: BlockEnds = .none,
        startsChapter: (Int) -> Bool = { _ in false }
    ) -> Int? {
        guard index > 0, index < words.count else { return nil }
        let start = sentenceStart(at: index, in: words, blockEnds: blockEnds, startsChapter: startsChapter)
        guard start > 0, index - start <= nearStart else { return start }
        return sentenceStart(at: start - 1, in: words, blockEnds: blockEnds, startsChapter: startsChapter)
    }
}
