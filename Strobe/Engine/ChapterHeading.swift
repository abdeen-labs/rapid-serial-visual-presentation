import Foundation

/// Finds the words at the start of a chapter that its announcement already
/// shows, so ``RSVPEngine`` goes on after them instead of playing the title a
/// second time, word by word.
///
/// An EPUB heading chapter starts on its heading's first word. A table of
/// contents entry or PDF outline item usually starts on the heading too, or on
/// a number or label just before it, but can word it differently. The words
/// there repeat the title when their letters and digits spell it, with case,
/// diacritics, punctuation, and spacing set aside, and the match ends where a
/// word ends. Comparing letters rather than words keeps the match independent
/// of how the tokenizer, today's or an earlier one, split or joined the
/// heading: `One—The` or `One—`, `The`; `44 BC` or `44`, `BC`; CJK segments.
nonisolated enum ChapterHeading {

    /// Where reading goes on after each chapter's announcement: for every
    /// chapter whose first words repeat its title, the first word after them.
    ///
    /// A heading that runs to the document's last word is left to play. A
    /// chapter that starts inside another chapter's heading is passed over
    /// only when its own heading ends there too, so the outer title already
    /// showed it (`Introduction: My Story` over `My Story`); otherwise reading
    /// stops at its start so it's announced.
    static func readingStarts(for chapters: [Int: Chapter], in words: [String]) -> [Int: Int] {
        let starts = chapters.keys.sorted()
        var headingEnds: [Int: Int] = [:]
        for start in starts {
            guard let title = chapters[start]?.title else { continue }
            let end = start + headingLength(of: title, at: start, in: words)
            if end > start, end < words.count {
                headingEnds[start] = end
            }
        }
        var readingStarts: [Int: Int] = [:]
        for (position, start) in starts.enumerated() {
            guard let end = headingEnds[start] else { continue }
            let uncovered = starts[(position + 1)...].prefix { $0 < end }.first { inner in
                guard let innerEnd = headingEnds[inner] else { return true }
                return innerEnd > end
            }
            readingStarts[start] = uncovered ?? end
        }
        return readingStarts
    }

    /// The number of words from `start` that repeat `title`, or 0 when the
    /// words there don't read as its heading.
    ///
    /// - The words spell the title: `The Man Who Didn’t Look Right` matches
    ///   `THE MAN WHO DIDN'T LOOK RIGHT`.
    /// - A number or label only one side has is set aside: the title
    ///   `1: The Surprising Power` matches `The Surprising Power`, and
    ///   `The Beginning` matches `Chapter 1 The Beginning`. When both have
    ///   one, they must agree: `1. The Beginning` matches
    ///   `Chapter One: The Beginning`, but `6. Monopsony` doesn't match
    ///   `4-9 Monopsony`.
    /// - A number with its label, or a label alone, at the start of the words
    ///   matches by itself when the title is only that number or label, or
    ///   opens with the same label: `Chapter 1` and `Chapter 1: The Storm`
    ///   cover `CHAPTER ONE`, and `Prologue: The Storm` covers `PROLOGUE`,
    ///   leaving whatever follows to play. A bare number in the words is too
    ///   often a list item or a note for this.
    /// - Words that read on as a sentence never match: they must not start in
    ///   lowercase under a capitalized title, and the word after them must not
    ///   start in lowercase (`Evidence from the 1990s…`,
    ///   `The Two-Minute Rule can seem…`).
    static func headingLength(of title: String, at start: Int, in words: [String]) -> Int {
        guard words.indices.contains(start) else { return 0 }
        var titlePhrase = Phrase()
        for token in title.split(whereSeparator: \.isWhitespace) {
            titlePhrase.append(token)
        }
        guard !titlePhrase.letters.isEmpty, titlePhrase.letters.count <= maximumTitleLength else { return 0 }

        // Enough words to spell the title after the longest number or label.
        var heading = Phrase()
        var index = start
        while index < words.count, heading.tokens.count < maximumHeadingWords,
              heading.letters.count < titlePhrase.letters.count + maximumNumberingLength {
            heading.append(words[index][...])
            index += 1
        }

        let titleNumbering = numbering(of: titlePhrase)
        let headingNumbering = numbering(of: heading)
        let titleRest = titleNumbering.map { titlePhrase.letters[$0.length...] }

        var length = heading.wordCount(spelling: titlePhrase.letters[...], from: 0)
        if length == nil, let titleRest {
            length = heading.wordCount(spelling: titleRest, from: 0)
        }
        if length == nil, let headingNumbering {
            length = heading.wordCount(spelling: titlePhrase.letters[...], from: headingNumbering.length)
        }
        if length == nil, let titleRest, !titleRest.isEmpty, let titleNumbering, let headingNumbering,
           titleNumbering.agrees(with: headingNumbering) {
            length = heading.wordCount(spelling: titleRest, from: headingNumbering.length)
        }
        if length == nil, let titleRest, let titleNumbering, let headingNumbering,
           let label = headingNumbering.label, label != "page",
           titleNumbering.number == headingNumbering.number,
           titleNumbering.label == label || (titleNumbering.label == nil && titleRest.isEmpty) {
            length = heading.wordCount(spelling: [], from: headingNumbering.length)
        }
        guard let length else { return 0 }

        if firstCase(in: title.unicodeScalars) == .upper,
           words[start..<(start + length)].lazy.compactMap({ firstCase(in: $0.unicodeScalars) }).first == .lower {
            return 0
        }
        if start + length < words.count, startsLowercase(words[start + length]) {
            return 0
        }
        return length
    }

    /// The most letters and digits a title can have and still be matched;
    /// longer text is not a heading.
    private static let maximumTitleLength = 240

    /// The most letters and digits a heading's number or label can add in
    /// front of the title's (`chapter twentyseven`, `第二十七章`).
    private static let maximumNumberingLength = 24

    /// The most words read from a chapter's start.
    static let maximumHeadingWords = 64

    // MARK: - Letters

    /// Words reduced to their letters and digits.
    private struct Phrase {
        private(set) var tokens: [Substring] = []
        /// The tokens' letters and digits; see ``letters(of:)``.
        private(set) var letters: [Unicode.Scalar] = []
        /// `letters.count` after each token.
        private(set) var ends: [Int] = []

        mutating func append(_ token: Substring) {
            tokens.append(token)
            letters += ChapterHeading.letters(of: token)
            ends.append(letters.count)
        }

        /// How many tokens it takes to spell `expected` after the first
        /// `offset` letters and end where a token ends — the fewest, when a
        /// punctuation-only token ends there too — or nil when they don't.
        func wordCount(spelling expected: ArraySlice<Unicode.Scalar>, from offset: Int) -> Int? {
            let end = offset + expected.count
            guard end > 0, end <= letters.count, letters[offset..<end].elementsEqual(expected) else { return nil }
            return ends.firstIndex(of: end).map { $0 + 1 }
        }
    }

    /// The letters and digits of `text`, case- and diacritic-folded and
    /// compatibility-decomposed (`ﬁ` → `fi`, `①` → `1`, `Ⅳ` → `iv`).
    private static func letters(of text: Substring) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "a"..."z", "0"..."9":
                result.append(scalar)
            case "A"..."Z":
                result.append(Unicode.Scalar(scalar.value + 32)!)
            case "\u{0}"..."\u{7F}":
                continue
            default:
                guard isLetterOrDigit(scalar) else { continue }
                // Folding is slow, so only words with letters or digits
                // outside ASCII pay for it.
                let folded = String(text).decomposedStringWithCompatibilityMapping
                    .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                return folded.unicodeScalars.filter(isLetterOrDigit)
            }
        }
        return result
    }

    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    private enum LetterCase {
        case upper, lower, uncased
    }

    /// The case of the first letter in `scalars`, or nil without letters.
    private static func firstCase(in scalars: some Sequence<Unicode.Scalar>) -> LetterCase? {
        for scalar in scalars where scalar.properties.isAlphabetic {
            if scalar.properties.isLowercase { return .lower }
            if scalar.properties.isUppercase || scalar.properties.generalCategory == .titlecaseLetter {
                return .upper
            }
            return .uncased
        }
        return nil
    }

    /// Whether `word` starts with a lowercase letter, looking past opening
    /// quotes and brackets but not past a digit.
    private static func startsLowercase(_ word: String) -> Bool {
        for scalar in word.unicodeScalars {
            if scalar.properties.isAlphabetic { return scalar.properties.isLowercase }
            if scalar.properties.numericType != nil { return false }
        }
        return false
    }

    // MARK: - Numbers and labels

    /// A heading's leading number or label: `Chapter 1:`, `Part Two`, `IV.`,
    /// `12.`, `1-1`, `第三章`, `Prologue`, or a page label such as `Page xiv`.
    private struct Numbering {
        /// How many of the phrase's letters it takes up.
        let length: Int
        /// What the label names (`chapter` for `Chapter`, `Ch.`, or
        /// `Kapitel`); nil for a bare number.
        let label: String?
        /// The number's parts: `[1, 1]` for `1-1`, a negative alphabet
        /// position for a letter such as `A`, and empty for a label that
        /// stands alone, such as `Prologue`, or a page label.
        let number: [Int]

        /// Whether the two can number the same heading: whatever both have
        /// is the same.
        func agrees(with other: Numbering) -> Bool {
            if let label, let otherLabel = other.label, label != otherLabel { return false }
            return number.isEmpty || other.number.isEmpty || number == other.number
        }
    }

    /// Words that label a numbered division, by what they name.
    private static let labels: [String: String] = [
        "chapter": "chapter", "chap": "chapter", "ch": "chapter", "kapitel": "chapter",
        "chapitre": "chapter", "capitulo": "chapter", "capitolo": "chapter", "hoofdstuk": "chapter",
        "part": "part", "pt": "part", "teil": "part", "partie": "part", "parte": "part", "deel": "part",
        "book": "book", "buch": "book", "livre": "book", "libro": "book",
        "section": "section", "sect": "section", "sec": "section",
        "volume": "volume", "vol": "volume", "band": "volume", "tome": "volume",
        "appendix": "appendix", "anhang": "appendix", "annexe": "appendix", "apendice": "appendix",
        "unit": "unit", "lesson": "lesson", "lecture": "lecture", "act": "act", "scene": "scene",
        "canto": "canto", "stave": "stave", "episode": "episode", "day": "day", "letter": "letter",
        // Converted PDFs can open a page with its printed number.
        "page": "page",
    ]

    /// Labels that name a division without a number.
    private static let standaloneLabels: Set<String> = [
        "prologue", "epilogue", "introduction", "preface", "foreword", "afterword", "interlude", "conclusion",
    ]

    /// `one` through `ninetynine`, spelled as ``letters(of:)`` reduces them.
    private static let numberWords: [String: Int] = {
        let units = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        let teens = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                     "seventeen", "eighteen", "nineteen"]
        let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        var result: [String: Int] = [:]
        for (offset, unit) in units.enumerated() {
            result[unit] = offset + 1
        }
        for (offset, teen) in teens.enumerated() {
            result[teen] = offset + 10
        }
        for (offset, ten) in tens.enumerated() {
            result[ten] = (offset + 2) * 10
            for (unitOffset, unit) in units.enumerated() {
                result[ten + unit] = (offset + 2) * 10 + unitOffset + 1
            }
        }
        return result
    }()

    /// The number or label `phrase` opens with, if any.
    private static func numbering(of phrase: Phrase) -> Numbering? {
        if let numbering = cjkNumbering(of: phrase.letters) { return numbering }
        guard let first = phrase.tokens.first else { return nil }
        func letters(ofToken index: Int) -> String {
            let start = index == 0 ? 0 : phrase.ends[index - 1]
            return String(String.UnicodeScalarView(phrase.letters[start..<phrase.ends[index]]))
        }

        let firstLetters = letters(ofToken: 0)
        if let label = labels[firstLetters], phrase.tokens.count > 1 {
            let second = phrase.tokens[1]
            let secondLetters = letters(ofToken: 1)
            let number = arabicNumber(second, alone: false) ?? romanNumber(second, alone: false)
            // A page's number says nothing about the chapter's.
            if label == "page" {
                return number.map { _ in Numbering(length: phrase.ends[1], label: label, number: []) }
            }
            if let number {
                return Numbering(length: phrase.ends[1], label: label, number: number)
            }
            if let tens = numberWords[secondLetters], tens >= 20, tens % 10 == 0, phrase.tokens.count > 2,
               let unit = numberWords[letters(ofToken: 2)], unit < 10 {
                return Numbering(length: phrase.ends[2], label: label, number: [tens + unit])
            }
            if let number = numberWords[secondLetters] {
                return Numbering(length: phrase.ends[1], label: label, number: [number])
            }
            if secondLetters.unicodeScalars.count == 1, let letter = secondLetters.unicodeScalars.first,
               ("a"..."z").contains(letter),
               second.unicodeScalars.filter({ $0.properties.isAlphabetic }).count == 1 {
                return Numbering(length: phrase.ends[1], label: label, number: [-Int(letter.value - 96)])
            }
        }
        if standaloneLabels.contains(firstLetters) {
            return Numbering(length: phrase.ends[0], label: firstLetters, number: [])
        }
        if let number = arabicNumber(first, alone: true) ?? romanNumber(first, alone: true) {
            return Numbering(length: phrase.ends[0], label: nil, number: number)
        }
        return nil
    }

    /// Marks that can follow a number before the title: `1.`, `1:`, `1)`, `1—`.
    private static func isNumberSeparator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case ".", ":", ")", "]", "-", ",", ";", "\u{2013}", "\u{2014}":   // – —
            return true
        default:
            return false
        }
    }

    /// `1`, `12.`, `1-1`, `2.3:`: groups of digits split by periods or dashes.
    /// `alone` is for one with no label before it, whose groups have at most
    /// three digits: `2018` is a year, not a chapter.
    private static func arabicNumber(_ token: Substring, alone: Bool) -> [Int]? {
        var scalars = token.unicodeScalars[...]
        while let last = scalars.last, isNumberSeparator(last) {
            scalars.removeLast()
        }
        let maximum = alone ? 999 : 99_999
        var groups: [Int] = []
        var group: Int?
        for scalar in scalars {
            if scalar.properties.numericType == .decimal, let digit = scalar.properties.numericValue {
                let value = (group ?? 0) * 10 + Int(digit)
                guard value <= maximum else { return nil }
                group = value
            } else if scalar == "." || scalar == "-" || scalar == "\u{2013}", let value = group {
                groups.append(value)
                group = nil
            } else {
                return nil
            }
        }
        guard let group else { return nil }
        return groups + [group]
    }

    /// A roman numeral in standard form, `iv` or `XII`. `alone` is for one
    /// with no label before it, which must end in `.`, `:`, or `)`, or be two
    /// or more capitals from `I`, `V`, and `X`: `I` and `MIX` are words.
    private static func romanNumber(_ token: Substring, alone: Bool) -> [Int]? {
        var scalars = token.unicodeScalars[...]
        var isMarked = false
        while let last = scalars.last, isNumberSeparator(last) {
            if last == "." || last == ":" || last == ")" { isMarked = true }
            scalars.removeLast()
        }
        guard !scalars.isEmpty, scalars.count <= 15 else { return nil }
        let isUppercase = scalars.allSatisfy { ("A"..."Z").contains($0) }
        guard isUppercase || scalars.allSatisfy({ ("a"..."z").contains($0) }) else { return nil }
        if alone, !isMarked {
            guard isUppercase, scalars.count >= 2,
                  scalars.allSatisfy({ $0 == "I" || $0 == "V" || $0 == "X" }) else { return nil }
        }
        let numeral = String(String.UnicodeScalarView(scalars)).lowercased()
        let digits = numeral.compactMap { romanDigits[$0] }
        guard digits.count == numeral.count else { return nil }
        var total = 0
        for (offset, value) in digits.enumerated() {
            total += offset + 1 < digits.count && value < digits[offset + 1] ? -value : value
        }
        guard (1..<4000).contains(total), romanNumeral(total) == numeral else { return nil }
        return [total]
    }

    private static let romanDigits: [Character: Int] = [
        "i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000,
    ]

    private static func romanNumeral(_ value: Int) -> String {
        let places: [(value: Int, numeral: String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
            (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var remainder = value
        var result = ""
        for place in places {
            while remainder >= place.value {
                result += place.numeral
                remainder -= place.value
            }
        }
        return result
    }

    /// Counters that close a CJK division number: 第三章, 第12回.
    private static let cjkCounters: Set<Unicode.Scalar> = [
        "章", "节", "節", "回", "部", "卷", "篇", "集", "话", "話", "幕", "课", "課",
    ]

    private static let cjkDigits: [Unicode.Scalar: Int] = [
        "〇": 0, "零": 0, "一": 1, "二": 2, "两": 2, "兩": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]

    private static let cjkPlaces: [Unicode.Scalar: Int] = ["十": 10, "百": 100, "千": 1000]

    /// `第三章`, `第12回`, `第二十七章`: 第, a number, and a counter at the
    /// start of `letters`. Segmentation varies, so the counter needn't end a
    /// word.
    private static func cjkNumbering(of letters: [Unicode.Scalar]) -> Numbering? {
        guard letters.first == "第" else { return nil }
        var index = 1
        var total = 0
        var pending = 0
        var decimal: Int?
        while index < letters.count, index <= 10 {
            let scalar = letters[index]
            if scalar.properties.numericType == .decimal, let digit = scalar.properties.numericValue {
                decimal = (decimal ?? 0) * 10 + Int(digit)
            } else if let digit = cjkDigits[scalar] {
                pending = digit
            } else if let place = cjkPlaces[scalar] {
                total += max(pending, 1) * place
                pending = 0
            } else {
                break
            }
            index += 1
        }
        guard index > 1, index < letters.count, cjkCounters.contains(letters[index]) else { return nil }
        return Numbering(length: index + 1, label: String(letters[index]), number: [decimal ?? total + pending])
    }
}
