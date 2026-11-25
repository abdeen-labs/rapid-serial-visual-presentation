import Testing
import Foundation
@testable import Strobe

struct DictionaryLookupTests {

    private func expectTerms(_ expectations: [(word: String, term: String?)]) {
        for (word, term) in expectations {
            #expect(DictionaryLookup.term(for: word) == term, "mismatch for \(word)")
        }
    }

    @Test func plainWordsLookUpAsTheyAre() {
        expectTerms([
            ("word", "word"),
            ("Strobe", "Strobe"),
            ("naïve", "naïve"),
            ("阅读", "阅读"),
            ("قراءة", "قراءة"),
        ])
    }

    @Test func marksAroundTheWordComeOff() {
        expectTerms([
            ("end.", "end"),
            ("hello,", "hello"),
            ("what?!", "what"),
            ("\u{201C}Hello,\u{201D}", "Hello"),   // “Hello,”
            ("(word)", "word"),
            ("[sic]", "sic"),
            ("elements\u{2014}", "elements"),      // elements—
            ("wait\u{2026}", "wait"),              // wait…
            ("'quoted'", "quoted"),
            ("dogs\u{2019}", "dogs"),              // dogs’
        ])
    }

    @Test func marksInsideTheWordStay() {
        expectTerms([
            ("don\u{2019}t", "don\u{2019}t"),      // don’t
            ("dog's", "dog's"),
            ("wedge-shaped", "wedge-shaped"),
            ("and/or", "and/or"),
            ("(re-read),", "re-read"),
            ("COVID-19.", "COVID-19"),
        ])
    }

    /// An abbreviation's entry is under its periods, the last one too.
    @Test func abbreviationsKeepTheirLastPeriod() {
        expectTerms([
            ("e.g.", "e.g."),
            ("e.g.,", "e.g."),
            ("(i.e.", "i.e."),
            ("U.S.", "U.S."),
            ("U.S.A.", "U.S.A."),
            ("Ph.D.", "Ph.D."),
            ("p.m.", "p.m."),
            ("U.S", "U.S"),
        ])
    }

    /// A sentence's period is not an abbreviation's.
    @Test func otherPeriodsComeOff() {
        expectTerms([
            ("Mr.", "Mr"),
            ("etc.", "etc"),
            ("example.com.", "example.com"),
            ("v2.0.", "v2.0"),
        ])
    }

    @Test func wordsWithoutLettersHaveNothingToLookUp() {
        expectTerms([
            ("", nil),
            ("\u{2014}", nil),                     // —
            ("...", nil),
            ("1984", nil),
            ("3.14.", nil),
            ("$5,000", nil),
            ("10:30", nil),
            ("***", nil),
        ])
    }

    /// The tokenizer joins a number and its designator into one word.
    @Test func numberUnitsLookUpTheirDesignator() {
        expectTerms([
            ("2000 BCE", "BCE"),
            ("44 B.C.", "B.C."),
            ("AD 79,", "AD"),
            ("10:30 PM.", "PM"),
            ("5 p.m.", "p.m."),
        ])
    }
}
