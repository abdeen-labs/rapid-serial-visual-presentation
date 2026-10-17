import Testing
import Foundation
@testable import Strobe

struct HighlightColorTests {

    // MARK: - Setting

    @Test func resolvesStoredValues() {
        for highlight in ReaderHighlightColor.allCases {
            #expect(ReaderHighlightColor.resolve(highlight.rawValue) == highlight)
        }
    }

    @Test func missingOrUnknownValuesFallBackToRed() {
        #expect(ReaderHighlightColor.defaultValue == .red)
        #expect(ReaderHighlightColor.resolve("") == .red)
        #expect(ReaderHighlightColor.resolve("chartreuse") == .red)
        #expect(ReaderHighlightColor.resolve("Blue") == .red)
    }

    /// A renamed key or case would quietly reset everyone's choice.
    @Test func storedNamesAreStable() {
        #expect(ReaderHighlightColor.storageKey == "readerHighlightColor")
        #expect(ReaderHighlightColor.allCases.map(\.rawValue)
                == ["red", "orange", "green", "teal", "blue", "purple", "pink"])
    }

    // MARK: - Colors

    /// Readers who never pick a color keep the anchor colors each tone had
    /// before the setting existed.
    @Test func defaultKeepsTheOriginalAnchorColors() {
        let original: [ReaderTextTone: UInt32] = [
            .bright: 0xFF453A, .soft: 0xC8554D, .sepia: 0xCC5A45, .night: 0xA8402F
        ]
        for tone in ReaderTextTone.allCases {
            #expect(ReaderHighlightColor.defaultValue.rgb(on: tone) == original[tone], "\(tone.rawValue)")
        }
    }

    @Test func everyColorDiffersFromTheWordInEveryTone() {
        for tone in ReaderTextTone.allCases {
            for highlight in ReaderHighlightColor.allCases {
                #expect(highlight.rgb(on: tone) != tone.textRGB, "\(highlight.rawValue) on \(tone.rawValue)")
            }
        }
    }

    @Test func colorsStayDistinctWithinEachTone() {
        for tone in ReaderTextTone.allCases {
            let colors = Set(ReaderHighlightColor.allCases.map { $0.rgb(on: tone) })
            #expect(colors.count == ReaderHighlightColor.allCases.count, "\(tone.rawValue)")
        }
    }

    /// The anchor never outshines the word it marks, which keeps the muted
    /// tones from glaring.
    @Test func everyColorIsDimmerThanTheWord() {
        for tone in ReaderTextTone.allCases {
            let word = Self.luminance(tone.textRGB)
            for highlight in ReaderHighlightColor.allCases {
                let anchor = Self.luminance(highlight.rgb(on: tone))
                #expect(anchor < word, "\(highlight.rawValue) on \(tone.rawValue): \(anchor) vs \(word)")
            }
        }
    }

    /// Every anchor stays legible on true black and on the lighter end of the
    /// standard reader background.
    @Test func everyColorReachesThreeToOneOnBothBackgrounds() {
        for tone in ReaderTextTone.allCases {
            for highlight in ReaderHighlightColor.allCases {
                let rgb = highlight.rgb(on: tone)
                for background: UInt32 in [0x000000, 0x0A0A0A] {
                    let contrast = Self.contrast(rgb, background)
                    #expect(contrast >= 3, "\(highlight.rawValue) on \(tone.rawValue): \(contrast)")
                }
            }
        }
    }

    // MARK: - Text on the color

    /// The passage view's current word stays white on the default red.
    @Test func defaultKeepsWhiteTextOnItsFill() {
        for tone in ReaderTextTone.allCases {
            #expect(!ReaderHighlightColor.defaultValue.prefersDarkText(on: tone), "\(tone.rawValue)")
        }
    }

    @Test func textOnEveryFillReachesThreeToOne() {
        for tone in ReaderTextTone.allCases {
            for highlight in ReaderHighlightColor.allCases {
                let fill = highlight.rgb(on: tone)
                let text: UInt32 = highlight.prefersDarkText(on: tone) ? 0x000000 : 0xFFFFFF
                let contrast = Self.contrast(fill, text)
                #expect(contrast >= 3, "\(highlight.rawValue) on \(tone.rawValue): \(contrast)")
            }
        }
    }

    // MARK: - Helpers

    /// WCAG relative luminance of an sRGB color.
    private static func luminance(_ rgb: UInt32) -> Double {
        func linear(_ channel: UInt32) -> Double {
            let value = Double(channel & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb >> 16) + 0.7152 * linear(rgb >> 8) + 0.0722 * linear(rgb)
    }

    private static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (first, second) = (luminance(a), luminance(b))
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
