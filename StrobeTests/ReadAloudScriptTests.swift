import Testing
import Foundation
@testable import Strobe

struct ReadAloudScriptTests {

    /// The script for all of `words`.
    private func script(_ words: [String]) -> SpeechScript {
        SpeechScript(words: words, range: 0..<words.count)
    }

    /// The text each word's range covers.
    private func spokenWords(_ script: SpeechScript) -> [String] {
        let text = script.text as NSString
        return script.wordRanges.map { text.substring(with: NSRange(location: $0.lowerBound, length: $0.count)) }
    }

    // MARK: - Text and ranges

    @Test func plainWordsAreJoinedBySpaces() {
        let script = script(["The", "cat", "sat."])
        #expect(script.text == "The cat sat.")
        #expect(script.wordRanges == [0..<3, 4..<7, 8..<12])
        #expect(script.words == ["The", "cat", "sat."])
        #expect(script.wordIndices == 0..<3)
    }

    /// Ranges count UTF-16 units, as a voice's markers do: an emoji with a
    /// skin tone is four, and a decomposed accent adds one.
    @Test func rangesCountUTF16Units() {
        let words = ["Hi", "\u{1F44B}\u{1F3FD}", "cafe\u{301}", "na\u{EF}ve,", "fun\u{1F600}."]   // 👋🏽, café, naïve
        let script = script(words)
        #expect(script.text == words.joined(separator: " "))
        #expect(script.wordRanges == [0..<2, 3..<7, 8..<13, 14..<20, 21..<27])
        #expect(spokenWords(script) == words)
        #expect(script.text.utf16.count == 27)
    }

    @Test func rangeOfWordsInsideADocument() {
        let words = ["One.", "Two", "three", "four.", "Five."]
        let script = SpeechScript(words: words, range: 1..<4)
        #expect(script.text == "Two three four.")
        #expect(script.wordIndices == 1..<4)
        #expect(script.words == ["Two", "three", "four."])
    }

    @Test func rangePastTheDocumentIsClamped() {
        let script = SpeechScript(words: ["One", "two."], range: 1..<9)
        #expect(script.wordIndices == 1..<2)
        #expect(script.text == "two.")
    }

    @Test func cjkWordsJoinWithoutSpaces() {
        let script = script(["我们", "今天", "去", "公园。", "Then", "we", "left."])
        #expect(script.text == "我们今天去公园。 Then we left.")
        #expect(script.wordRanges == [0..<2, 2..<4, 4..<5, 5..<8, 9..<13, 14..<16, 17..<22])
    }

    /// Korean is written with spaces, so its words keep them.
    @Test func hangulWordsKeepTheirSpaces() {
        #expect(script(["오늘은", "날씨가", "좋다."]).text == "오늘은 날씨가 좋다.")
    }

    @Test func numberUnitsStayWholeWithTheirSpace() {
        let script = script(["around", "2000 BCE,", "at", "10:30 PM."])
        #expect(script.text == "around 2000 BCE, at 10:30 PM.")
        #expect(spokenWords(script) == ["around", "2000 BCE,", "at", "10:30 PM."])
        #expect(script.wordRanges[1] == 7..<16)
        #expect(script.wordRanges[3] == 20..<29)
    }

    // MARK: - Dashes

    @Test func dashesBetweenWordsReadAsCommas() {
        #expect(script(["the", "stair\u{2014}", "one"]).text == "the stair, one")       // stair—
        #expect(script(["the", "stair\u{2015}", "one"]).text == "the stair, one")       // stair―
        #expect(script(["wait--", "what"]).text == "wait, what")
        #expect(script(["word\u{2013}\u{2013}", "next"]).text == "word, next")        // word––
        #expect(script(["word\u{2013}", "next"]).text == "word, next")                // spaced en dash
        #expect(script(["thought\u{2014}\u{201D}\u{2014}", "she"]).text == "thought\u{201D}, she")
    }

    /// The comma belongs to the word the dash was on.
    @Test func trailingDashCommaIsInsideTheWordsRange() {
        let script = script(["the", "stair\u{2014}", "one"])
        #expect(spokenWords(script) == ["the", "stair,", "one"])
    }

    /// A dash opening a word reads as a comma after the word before it, in
    /// the space between them.
    @Test func leadingDashReadsAsACommaBefore() {
        let script = script(["said", "\u{2014}Hello,", "and"])
        #expect(script.text == "said, Hello, and")
        #expect(spokenWords(script) == ["said", "Hello,", "and"])
        #expect(self.script(["\u{2014}Hello,", "he", "said."]).text == "Hello, he said.")
        #expect(self.script(["said", "\u{2014}\u{201C}Hello"]).text == "said, \u{201C}Hello")
    }

    /// Documents imported before the tokenizer split words at dashes can
    /// still hold two words fused by one.
    @Test func dashInsideAWordReadsAsAComma() {
        #expect(script(["elements\u{2014}stone", "and"]).text == "elements, stone and")
        #expect(script(["well--maybe"]).text == "well, maybe")
    }

    @Test func dashWordAloneReadsAsACommaAndIsLeftOut() {
        let script = script(["Hello", "\u{2014}", "world"])
        #expect(script.text == "Hello, world")
        #expect(script.wordRanges == [0..<5, 5..<5, 7..<12])
        // No second comma after one already there.
        #expect(self.script(["Hello,", "\u{2014}", "world"]).text == "Hello, world")
    }

    @Test func hyphensAndRangesStay() {
        let words = ["well-known", "1990\u{2013}2000", "pre-", "and", "post-war", "-5"]
        #expect(script(words).text == words.joined(separator: " "))
    }

    @Test func cjkDashReadsAsAFullwidthComma() {
        let script = script(["他说\u{2014}\u{2014}", "我们", "走吧。"])
        #expect(script.text == "他说\u{FF0C}我们走吧。")
        #expect(spokenWords(script) == ["他说\u{FF0C}", "我们", "走吧。"])
    }

    // MARK: - Symbols

    @Test func decorativeWordsAreLeftOut() {
        let script = script(["***", "Chapter", "\u{2022}", "one", "|", "two", "#", "three", "\u{2767}"])   // •, ❧
        #expect(script.text == "Chapter one two three")
        #expect(script.wordRanges == [0..<0, 0..<7, 7..<7, 8..<11, 11..<11, 12..<15, 15..<15, 16..<21, 21..<21])
    }

    @Test func decorativeMarksAtWordEdgesAreDropped() {
        let script = script(["end.***", "*note*", "item\u{2022}", "Home|", "word\u{2020}"])   // item•, word†
        #expect(script.text == "end. note item Home word")
    }

    @Test func spokenSymbolsStay() {
        let words = ["&", "50%", "#1", "C#", "~100", "$5", "\u{1F600}", "+", "\u{00A7}"]   // 😀, §
        let script = script(words)
        #expect(script.text == words.joined(separator: " "))
        #expect(script.wordRanges.allSatisfy { !$0.isEmpty })
    }

    // MARK: - Titles

    @Test func titleReadsWithoutWords() {
        let title = SpeechScript(title: "Chapter 1 \u{2014} The Beginning")
        #expect(title.text == "Chapter 1, The Beginning")
        #expect(title.words.isEmpty)
        #expect(title.wordRanges.isEmpty)
        #expect(title.wordIndices.isEmpty)
        #expect(SpeechScript(title: "*** Part  Two ***").text == "Part Two")
        // A title's spaces are its own, so they stay between CJK words.
        #expect(SpeechScript(title: "第一章 开始").text == "第一章 开始")
        #expect(SpeechScript(title: "***").text.isEmpty)
    }

    // MARK: - Lookups

    /// "The quick brown fox." at 0..<3, 4..<9, 10..<15, 16..<20.
    private let fox = SpeechScript(words: ["The", "quick", "brown", "fox."], range: 0..<4)

    @Test func lookupInsideAWord() {
        #expect(fox.wordPositions(touching: 5..<7) == 1..<2)
        #expect(fox.wordPositions(touching: 4..<9) == 1..<2)
        #expect(fox.wordPositions(touching: 6..<6) == 1..<2)
        #expect(fox.wordPositions(touching: 4..<4) == 1..<2)
        #expect(fox.wordPositions(touching: 0..<1) == 0..<1)
    }

    @Test func lookupAcrossWords() {
        #expect(fox.wordPositions(touching: 2..<12) == 0..<3)
        #expect(fox.wordPositions(touching: 0..<20) == 0..<4)
        // A range taking in the space after a word stays with that word.
        #expect(fox.wordPositions(touching: 4..<10) == 1..<2)
    }

    @Test func lookupBetweenWordsGivesTheNextWord() {
        #expect(fox.wordPositions(touching: 3..<4) == 1..<2)
        #expect(fox.wordPositions(touching: 9..<9) == 2..<3)
        #expect(fox.wordPositions(touching: 15..<16) == 3..<4)
    }

    @Test func lookupAfterTheWordsIsEmpty() {
        #expect(fox.wordPositions(touching: 20..<22) == 4..<4)
        #expect(fox.wordPositions(touching: 25..<30) == 4..<4)
        #expect(fox.wordPositions(touching: 20..<20) == 4..<4)
        #expect(fox.wordPositions(touching: 18..<25) == 3..<4)
    }

    @Test func lookupSkipsWordsLeftOut() {
        let script = script(["one", "***", "two", "\u{2022}"])
        #expect(script.text == "one two")
        #expect(script.wordPositions(touching: 0..<7) == 0..<3)
        #expect(script.wordPositions(touching: 3..<4) == 2..<3)
        #expect(script.wordPositions(touching: 7..<8) == 4..<4)
    }

    @Test func lookupOnAnInsertedCommaGivesTheNextWord() {
        let script = script(["said", "\u{2014}Hello"])
        #expect(script.text == "said, Hello")
        #expect(script.wordPositions(touching: 4..<5) == 1..<2)
        #expect(script.wordPositions(touching: 4..<6) == 1..<2)
    }

    @Test func lookupInCJKText() {
        let script = script(["我们", "今天", "去", "公园。"])
        #expect(script.wordPositions(touching: 2..<4) == 1..<2)
        #expect(script.wordPositions(touching: 3..<5) == 1..<3)
        #expect(script.wordPositions(touching: 0..<8) == 0..<4)
    }

    @Test func lookupInANumberUnit() {
        let script = script(["around", "2000 BCE,", "and"])
        // A voice reports the halves of `2000 BCE` separately.
        #expect(script.wordPositions(touching: 7..<11) == 1..<2)
        #expect(script.wordPositions(touching: 12..<15) == 1..<2)
    }

    // MARK: - Chunks

    private func words(_ text: String) -> [String] {
        text.split(separator: " ").map(String.init)
    }

    @Test func chunkRunsToTheSentenceEnd() {
        let words = words("Mr. Smith went to Washington. He arrived at 5 p.m. on Friday. Then he left.")
        #expect(SpeechChunker.chunk(startingAt: 0, in: words, chapterStarts: []) == 0..<5)
        #expect(SpeechChunker.chunk(startingAt: 5, in: words, chapterStarts: []) == 5..<12)
        #expect(SpeechChunker.chunk(startingAt: 12, in: words, chapterStarts: []) == 12..<15)
    }

    @Test func abbreviationsDontEndAChunk() {
        let words = words("A letter from Dr. Hale and the U.S. Army arrived. It was late.")
        #expect(SpeechChunker.chunk(startingAt: 0, in: words, chapterStarts: []) == 0..<10)
        let initials = self.words("J. R. R. Tolkien wrote it. Then")
        #expect(SpeechChunker.chunk(startingAt: 0, in: initials, chapterStarts: []) == 0..<6)
    }

    @Test func chunkFromMidSentenceReadsTheRestOfIt() {
        let words = words("Mr. Smith went to Washington. He arrived.")
        #expect(SpeechChunker.chunk(startingAt: 2, in: words, chapterStarts: []) == 2..<5)
        #expect(SpeechChunker.chunk(startingAt: 4, in: words, chapterStarts: []) == 4..<5)
    }

    @Test func chunkStopsBeforeAChapterStart() {
        let words = words("the end of one Chapter Two begins here. More")
        #expect(SpeechChunker.chunk(startingAt: 0, in: words, chapterStarts: [4]) == 0..<4)
        // Its own chapter start doesn't stop it.
        #expect(SpeechChunker.chunk(startingAt: 4, in: words, chapterStarts: [4]) == 4..<8)
        // Reading on past a heading that repeats the title.
        #expect(SpeechChunker.chunk(startingAt: 5, in: words, chapterStarts: [4, 7]) == 5..<7)
    }

    @Test func lastSentenceRunsToTheEnd() {
        let words = words("It ends without a mark")
        #expect(SpeechChunker.chunk(startingAt: 1, in: words, chapterStarts: []) == 1..<5)
        #expect(SpeechChunker.chunk(startingAt: 4, in: words, chapterStarts: []) == 4..<5)
    }

    @Test func startOutsideTheWordsIsEmpty() {
        let words = words("One two.")
        #expect(SpeechChunker.chunk(startingAt: 2, in: words, chapterStarts: []).isEmpty)
        #expect(SpeechChunker.chunk(startingAt: -1, in: words, chapterStarts: []).isEmpty)
        #expect(SpeechChunker.chunk(startingAt: 0, in: [], chapterStarts: []).isEmpty)
    }

    /// A sentence of `count` words, ending in a period, with a comma after
    /// each word in `commas` and a dash after each in `dashes`. Its words
    /// are short, so the word limits bind before the length limits.
    private func longSentence(_ count: Int, commas: Set<Int> = [], dashes: Set<Int> = []) -> [String] {
        (0..<count).map { index in
            if index == count - 1 { return "end." }
            if commas.contains(index) { return "word," }
            if dashes.contains(index) { return "word\u{2014}" }
            return "word"
        } + ["Next"]
    }

    private let maximum = SpeechChunker.maximumWords
    private let preferred = SpeechChunker.preferredWords

    @Test func limitsSuitTheVoiceModel() {
        #expect(SpeechChunker.minimumSplitWords < SpeechChunker.preferredWords)
        #expect(SpeechChunker.preferredWords < SpeechChunker.maximumWords)
        #expect(SpeechChunker.preferredLength < SpeechChunker.maximumLength)
        // Kokoro takes at most 510 phonemes in a call. English has about one
        // for each letter, and the margin leaves room for numbers, which
        // read longer than they're written.
        #expect(SpeechChunker.maximumLength <= 510 / 2)
    }

    /// A sentence up to the maximum stays whole, clause marks and all.
    @Test func sentenceUpToTheMaximumStaysWhole() {
        let words = longSentence(maximum, commas: [4, preferred - 2], dashes: [preferred + 2])
        #expect(SpeechChunker.chunk(startingAt: 0, in: words, chapterStarts: []) == 0..<maximum)
        let longer = longSentence(maximum + 1, commas: [4, preferred - 2])
        #expect(SpeechChunker.chunk(startingAt: 0, in: longer, chapterStarts: []).count < maximum)
    }

    /// A longer sentence splits at the last clause mark that keeps the
    /// chunk within the preferred size, and the rest of it reads on.
    @Test func longSentenceSplitsAtItsLastClauseMarkWithinThePreferredSize() {
        let count = maximum + 10
        let words = longSentence(count, commas: [preferred - 6, preferred - 2, preferred + 2])
        #expect(SpeechChunker.chunk(startingAt: 0, in: words, chapterStarts: []) == 0..<preferred - 1)
        // A chunk ending on the preferred size itself.
        let atPreferred = longSentence(count, commas: [preferred - 1])
        #expect(SpeechChunker.chunk(startingAt: 0, in: atPreferred, chapterStarts: []) == 0..<preferred)
    }

    @Test func longSentenceSplitsAtADash() {
        let words = longSentence(maximum + 10, dashes: [preferred - 3])
        #expect(SpeechChunker.chunk(startingAt: 0, in: words, chapterStarts: []) == 0..<preferred - 2)
    }

    /// A clause mark past the preferred size still beats splitting inside a
    /// clause: the first one past it.
    @Test func clauseMarkPastThePreferredSizeBeatsSplittingMidClause() {
        let words = longSentence(maximum + 10, commas: [preferred + 1, preferred + 3])
        #expect(SpeechChunker.chunk(startingAt: 0, in: words, chapterStarts: []) == 0..<preferred + 2)
    }

    /// A clause mark in the first few words would leave a chunk of a word
    /// or two.
    @Test func clauseMarkNearTheStartIsntASplit() {
        let words = longSentence(maximum + 10, commas: [0, SpeechChunker.minimumSplitWords - 2])
        #expect(SpeechChunker.chunk(startingAt: 0, in: words, chapterStarts: []) == 0..<preferred)
    }

    @Test func longSentenceWithoutMarksSplitsAtThePreferredSize() {
        let words = longSentence(maximum + 10)
        #expect(SpeechChunker.chunk(startingAt: 0, in: words, chapterStarts: []) == 0..<preferred)
        // The rest of the sentence fits, so it stays whole.
        #expect(SpeechChunker.chunk(startingAt: preferred, in: words, chapterStarts: []) == preferred..<maximum + 10)
        // A clause mark past the maximum doesn't count.
        let late = longSentence(maximum + 10, commas: [maximum + 2])
        #expect(SpeechChunker.chunk(startingAt: 0, in: late, chapterStarts: []) == 0..<preferred)
    }

    /// A sentence of long words splits by its length before its word count.
    @Test func sentenceOfLongWordsSplitsByLength() {
        let long = String(repeating: "x", count: 20)
        // Each word takes 21 units, with its space.
        let fitsPreferred = SpeechChunker.preferredLength / 21
        let fitsMaximum = SpeechChunker.maximumLength / 21
        #expect(fitsPreferred >= SpeechChunker.minimumSplitWords)

        var words = Array(repeating: long, count: fitsMaximum - 1) + ["end."]
        #expect(SpeechChunker.chunk(startingAt: 0, in: words, chapterStarts: []) == 0..<fitsMaximum)

        words = Array(repeating: long, count: 30) + ["end."]
        #expect(SpeechChunker.chunk(startingAt: 0, in: words, chapterStarts: []) == 0..<fitsPreferred)
        words[fitsMaximum - 2] = long + ","
        #expect(SpeechChunker.chunk(startingAt: 0, in: words, chapterStarts: []) == 0..<fitsMaximum - 1)
    }

    @Test func overlongWordIsAChunkOfItsOwn() {
        let words = [String(repeating: "x", count: 500), "and", "more."]
        #expect(SpeechChunker.chunk(startingAt: 0, in: words, chapterStarts: []) == 0..<1)
        #expect(SpeechChunker.chunk(startingAt: 1, in: words, chapterStarts: []) == 1..<3)
    }

    /// Ordinary sentences, even long ones with a few commas, read whole.
    @Test func ordinaryProseReadsInWholeSentences() {
        let words = words(
            "The keeper climbed the narrow stair, as he had done every single evening for thirty years, and lit the lamp. "
                + "Below him, the harbor lay still."
        )
        #expect(SpeechChunker.chunk(startingAt: 0, in: words, chapterStarts: []) == 0..<20)
        #expect(SpeechChunker.chunk(startingAt: 20, in: words, chapterStarts: []) == 20..<26)
    }

    /// Reading chunk after chunk covers every word once, in order, and no
    /// chunk passes the limits.
    @Test func chunksCoverTheDocument() {
        let sentence = words("He climbed the narrow stair\u{2014} one hundred steps\u{2014} and wiped the lens.")
        let words = Array([sentence, longSentence(90, commas: [20, 50]), sentence, longSentence(130)].joined())
        let chapters: Set<Int> = [14, 120]
        var start = 0
        var count = 0
        while start < words.count {
            let chunk = SpeechChunker.chunk(startingAt: start, in: words, chapterStarts: chapters)
            #expect(chunk.lowerBound == start)
            #expect(!chunk.isEmpty)
            #expect(chunk.count <= SpeechChunker.maximumWords)
            let length = words[chunk].reduce(0) { $0 + $1.utf16.count + 1 }
            #expect(chunk.count == 1 || length <= SpeechChunker.maximumLength)
            #expect(!chapters.contains { $0 > chunk.lowerBound && $0 < chunk.upperBound })
            start = chunk.upperBound
            count += 1
        }
        #expect(start == words.count)
        // The long sentences are split, so there are more chunks than the
        // fewest that could hold the words.
        #expect(count > words.count / SpeechChunker.maximumWords + 2)
    }
}
