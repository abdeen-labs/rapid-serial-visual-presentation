//
//  StrobeTests.swift
//  StrobeTests
//
//  Created by CZTH on 2/13/26.
//

import Testing
import NaturalLanguage
import CoreGraphics
import CoreText
import PDFKit
@testable import Strobe
internal import UniformTypeIdentifiers

struct StrobeTests {

    @Test func normalizesSoftAndNonBreakingHyphens() {
        let words = Tokenizer.tokenize("hy\u{00AD}phen non\u{2011}breaking")
        #expect(words == ["hyphen", "non-breaking"])
    }

    @Test func resolvesSourceTypeFromExtension() {
        #expect(DocumentImportPipeline.resolveSourceType(for: URL(fileURLWithPath: "/tmp/book.pdf")) == .pdf)
        #expect(DocumentImportPipeline.resolveSourceType(for: URL(fileURLWithPath: "/tmp/book.epub")) == .epub)
        #expect(DocumentImportPipeline.resolveSourceType(for: URL(fileURLWithPath: "/tmp/book.txt")) == .plainText)
        #expect(DocumentImportPipeline.resolveSourceType(for: URL(fileURLWithPath: "/tmp/notes.md")) == .plainText)
        #expect(DocumentImportPipeline.resolveSourceType(for: URL(fileURLWithPath: "/tmp/book.bin")) == .unknown)
    }

    @Test func resolvesSourceTypeFromDetectedContentType() {
        let unknownPath = URL(fileURLWithPath: "/tmp/book.bin")
        #expect(DocumentImportPipeline.resolveSourceType(for: unknownPath, detectedContentType: .pdf) == .pdf)
        #expect(DocumentImportPipeline.resolveSourceType(for: unknownPath, detectedContentType: .epub) == .epub)
    }

    @Test func epubExtractionFailsForMissingFile() {
        do {
            _ = try DocumentImportPipeline.extractWordsAndChapters(
                from: URL(fileURLWithPath: "/tmp/nonexistent.epub"),
                detectedContentType: .epub
            )
            Issue.record("Expected EPUB extraction to throw an error for a missing file.")
        } catch let error as DocumentImportError {
            #expect(error == .epubExtractionFailed)
        } catch {
            // Any error is acceptable for a missing file
        }
    }

    @Test func unknownExtractionTypeThrowsUnsupportedTypeError() {
        // .txt is now a supported plain-text import — use a genuinely
        // unsupported extension.
        do {
            _ = try DocumentImportPipeline.extractWordsAndChapters(
                from: URL(fileURLWithPath: "/tmp/book.jpg")
            )
            Issue.record("Expected unknown type to throw unsupported-file-type error.")
        } catch let error as DocumentImportError {
            #expect(error == .unsupportedFileType)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Standalone punctuation filtering

    @Test func attachesStandalonePunctuationToPreviousWord() {
        let words = Tokenizer.tokenize("hello ' world . end")
        #expect(words == ["hello'", "world.", "end"])
    }

    @Test func keepsPunctuationAttachedToWords() {
        let words = Tokenizer.tokenize("don't end. \"hello\"")
        #expect(words == ["don't", "end.", "\"hello\""])
    }

    @Test func attachesMultipleIsolatedPunctuationToPreviousWord() {
        let words = Tokenizer.tokenize("word ... — – word2")
        #expect(words == ["word...—–", "word2"])
    }

    // MARK: - Tabular data cleaning

    @Test func detectsTabularDataLines() {
        let input = "12.5  34  67.8  90.1\nThis is a normal sentence.\n$100  $200  $300  $400"
        let cleaned = TextCleaner.cleanText(input, level: .standard)
        #expect(cleaned.contains("normal sentence"))
        #expect(!cleaned.contains("12.5"))
        #expect(!cleaned.contains("$100"))
    }

    @Test func preservesNormalTextWithSomeNumbers() {
        let input = "Chapter 3 describes 42 experiments in detail"
        let cleaned = TextCleaner.cleanText(input, level: .standard)
        #expect(cleaned.contains("42 experiments"))
    }

    // MARK: - Smart timing

    @Test func smartTimingMultiplierAccountsForTerminalPunctuation() {
        let plain = RSVPEngine.smartTimingMultiplier(for: "reading")
        let punctuated = RSVPEngine.smartTimingMultiplier(for: "reading.")
        #expect(punctuated > plain)
    }

    @Test func smartTimingMultiplierSkipsWordsBelowMinimumLength() {
        let multiplier = RSVPEngine.smartTimingMultiplier(for: "cat", minimumWordLength: 6)
        #expect(multiplier == 1.0)
    }

    /// Once a word reaches the threshold, the full per-letter calculation
    /// applies — the threshold gates the slowdown, it doesn't rescale it, so
    /// existing per-letter tuning keeps producing the same long-word durations.
    @Test func smartTimingMultiplierAppliesFullSlowdownAtMinimumLength() {
        let exact = RSVPEngine.smartTimingMultiplier(for: "strobe", minimumWordLength: 6)
        let long = RSVPEngine.smartTimingMultiplier(for: "characteristically", minimumWordLength: 6)
        #expect(exact == RSVPEngine.smartTimingMultiplier(for: "strobe"))
        #expect(long == RSVPEngine.smartTimingMultiplier(for: "characteristically"))
        #expect(exact > 1.0)
    }

    /// Punctuation doesn't count toward the threshold, and the clause-boundary
    /// bonus survives it — a short word with a trailing comma still gets its
    /// brief pause even when the length slowdown is gated off.
    @Test func smartTimingMultiplierKeepsPunctuationBonusBelowMinimumLength() {
        let multiplier = RSVPEngine.smartTimingMultiplier(for: "and,", minimumWordLength: 6)
        #expect(multiplier == 1.2)
    }

    /// The default threshold (1) must reproduce the historical behavior for
    /// every token shape, including punctuation-only tokens like an em-dash
    /// (0 letters, so it clears no threshold but keeps its 0.2 bonus).
    @Test func smartTimingMinimumLengthOfOneMatchesLegacyBehavior() {
        let expected: [(word: String, multiplier: Double)] = [
            ("a", 1.04),                     // 1 letter
            ("cat", 1.12),                   // 3 letters
            ("and,", 1.32),                  // 3 letters + punctuation bonus
            ("reading.", 1.48),              // 7 letters + punctuation bonus
            ("—", 1.2),                      // 0 letters, punctuation bonus only
            ("characteristically", 1.72),    // 18 letters
        ]
        for (word, multiplier) in expected {
            let gated = RSVPEngine.smartTimingMultiplier(for: word, minimumWordLength: 1)
            #expect(abs(gated - multiplier) < 0.0001, "mismatch for \(word)")
        }
    }

    // MARK: - RSVPEngine playback

    @Test func enginePlayAndPause() {
        let engine = RSVPEngine(words: ["one", "two", "three"])
        #expect(!engine.isPlaying)
        engine.play()
        #expect(engine.isPlaying)
        engine.pause()
        #expect(!engine.isPlaying)
    }

    @Test func engineSeekClampsToValidRange() {
        let engine = RSVPEngine(words: ["a", "b", "c", "d"])
        engine.seek(to: 100)
        #expect(engine.currentIndex == 3)
        engine.seek(to: -5)
        #expect(engine.currentIndex == 0)
    }

    @Test func engineScrubReturnsHitBoundary() {
        let engine = RSVPEngine(words: ["a", "b", "c"])
        engine.seek(to: 2)
        let hitEnd = engine.scrub(by: 1)
        #expect(hitEnd)
        #expect(engine.currentIndex == 2)
    }

    @Test func engineProgressCalculation() {
        let engine = RSVPEngine(words: ["a", "b", "c", "d", "e"])
        #expect(engine.progress == 0)
        engine.seek(to: 2)
        #expect(engine.progress == 0.5)
        engine.seek(to: 4)
        #expect(engine.progress == 1.0)
    }

    @Test func engineIsAtEnd() {
        let engine = RSVPEngine(words: ["a", "b"])
        #expect(!engine.isAtEnd)
        engine.seek(to: 1)
        #expect(engine.isAtEnd)
    }

    @Test func engineDoesNotPlayWhenAtEnd() {
        let engine = RSVPEngine(words: ["a", "b"])
        engine.seek(to: 1)
        engine.play()
        #expect(!engine.isPlaying)
    }

    @Test func engineSingleWordProgress() {
        let engine = RSVPEngine(words: ["only"])
        #expect(engine.progress == 1.0)
        #expect(engine.isAtEnd)
    }

    // MARK: - Chapter announcements

    @MainActor
    @Test func chapterAnnouncementHoldsAndResumesAtItsFirstWord() {
        let chapter = Chapter(title: "Part Two", wordIndex: 1)
        let engine = RSVPEngine(words: ["before", "first", "next"], wordsPerMinute: 1, chapters: [chapter])
        defer { engine.pause() }
        engine.play()
        engine.advance()
        #expect(engine.chapterAnnouncement == chapter)
        #expect(engine.isChapterTitleVisible)
        #expect(engine.isPlaying)
        #expect(engine.currentWord == "first")
        engine.advance() // Begin fade-out; words remain frozen.
        #expect(!engine.isChapterTitleVisible)
        #expect(engine.chapterAnnouncement == chapter)
        #expect(engine.currentWord == "first")
        engine.advance() // Reveal the first word for a full interval.
        #expect(engine.chapterAnnouncement == nil)
        #expect(engine.currentWord == "first")
        #expect(engine.isPlaying)
        engine.advance()
        #expect(engine.currentWord == "next")
    }

    @MainActor
    @Test(arguments: [false, true])
    func pausingAnAnnouncementCancelsBothPhases(duringFade: Bool) {
        let engine = RSVPEngine(words: ["first", "next"], wordsPerMinute: 1,
                                chapters: [Chapter(title: "Chapter One", wordIndex: 0)])
        engine.play()
        if duringFade { engine.advance() }
        engine.pause() // Hold release, Space, background, or leaving the reader.
        engine.advance() // A stale timer callback cannot resume playback.
        #expect(!engine.isPlaying)
        #expect(engine.chapterAnnouncement == nil)
        #expect(engine.currentIndex == 0)
        engine.play()
        #expect(engine.chapterAnnouncement == nil) // Do not repeat on every hold.
        engine.pause()
    }

    @MainActor
    @Test func seekingAndLoadingCancelAnnouncements() {
        let chapter = Chapter(title: "Chapter", wordIndex: 0)
        let engine = RSVPEngine(words: ["a", "b", "c"], chapters: [chapter])
        engine.play()
        engine.seek(to: 1)
        engine.advance()
        #expect(!engine.isPlaying)
        #expect(engine.chapterAnnouncement == nil)
        #expect(engine.currentIndex == 1)
        engine.restart()
        engine.play()
        #expect(engine.chapterAnnouncement == chapter)
        engine.load(words: ["new", "book"], currentIndex: 0, complexityScores: nil)
        engine.advance()
        #expect(!engine.isPlaying)
        #expect(engine.chapterAnnouncement == nil)
        engine.play()
        #expect(engine.chapterAnnouncement == nil) // Old chapter map was replaced.
        engine.pause()
    }

    @MainActor
    @Test func chapterAtFinalWordCompletesOnlyAfterAnnouncementAndWord() {
        let engine = RSVPEngine(words: ["before", "last"], wordsPerMinute: 1,
                                chapters: [Chapter(title: "Epilogue", wordIndex: 1)])
        engine.play()
        engine.advance()
        #expect(engine.isAtEnd)
        #expect(engine.isPlaying)
        engine.advance()
        engine.advance()
        #expect(engine.isPlaying)
        #expect(engine.currentWord == "last")
        engine.advance()
        #expect(!engine.isPlaying)
    }

    // Checks the title's deadline instead of sleeping and then expecting the
    // title to still show: other tests can hold the main actor for longer
    // than the title lasts, and the engine's overdue timer may then run
    // before this test resumes.
    @MainActor
    @Test func chapterTimerIgnoresSpeedChangesAndResumesAutomatically() async throws {
        let engine = RSVPEngine(words: ["first", "last"], wordsPerMinute: 60,
                                chapters: [Chapter(title: "Chapter One", wordIndex: 0)])
        defer { engine.pause() }
        engine.play()
        let titleDeadline = try #require(engine.scheduledDeadline)
        engine.wpmOverride = 6000
        engine.smartTimingEnabled = true
        // Still on the main actor, so the timer can't have fired yet.
        #expect(engine.scheduledDeadline == titleDeadline)
        #expect(engine.chapterAnnouncement != nil)
        #expect(engine.isChapterTitleVisible)
        #expect(engine.currentIndex == 0)
        for _ in 0..<400 where engine.isPlaying {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.chapterAnnouncement == nil)
        #expect(engine.isAtEnd)
        #expect(!engine.isPlaying)
    }

    // MARK: - Hold-to-read speed control

    @Test func holdSpeedWPMReturnsBaseInsideDeadZone() {
        #expect(RSVPEngine.holdSpeedWPM(baseWPM: 300, verticalTranslation: 0) == 300)
        #expect(RSVPEngine.holdSpeedWPM(baseWPM: 300, verticalTranslation: -15) == 300)
        #expect(RSVPEngine.holdSpeedWPM(baseWPM: 300, verticalTranslation: 15) == 300)
    }

    @Test func holdSpeedWPMIncreasesWhenMovingUp() {
        #expect(RSVPEngine.holdSpeedWPM(baseWPM: 300, verticalTranslation: -215) == 800)
    }

    @Test func holdSpeedWPMDecreasesWhenMovingDown() {
        #expect(RSVPEngine.holdSpeedWPM(baseWPM: 300, verticalTranslation: 55) == 200)
    }

    @Test func holdSpeedWPMSnapsToTenWPMSteps() {
        let adjusted = RSVPEngine.holdSpeedWPM(baseWPM: 300, verticalTranslation: -21)
        #expect(adjusted == 320)
        #expect(RSVPEngine.holdSpeedWPM(baseWPM: 300, verticalTranslation: -19) == 310)
    }

    @Test func holdSpeedWPMClampsToSliderRange() {
        #expect(RSVPEngine.holdSpeedWPM(baseWPM: 300, verticalTranslation: -2000) == 1000)
        #expect(RSVPEngine.holdSpeedWPM(baseWPM: 300, verticalTranslation: 2000) == 100)
    }

    @Test func holdSpeedWPMRoundsToNearestStep() {
        // 312.5 → 310 (ordinary round-down; complements the -21 tie case).
        #expect(RSVPEngine.holdSpeedWPM(baseWPM: 300, verticalTranslation: -20) == 310)
    }

    @Test func holdSpeedWPMClampsFromBoundaryBases() {
        #expect(RSVPEngine.holdSpeedWPM(baseWPM: 1000, verticalTranslation: -50) == 1000)
        #expect(RSVPEngine.holdSpeedWPM(baseWPM: 100, verticalTranslation: 50) == 100)
    }

    @Test func holdSpeedWPMNormalizesOffGridBaseInDeadZone() {
        // Batch A makes the dead-zone path snap+clamp too, so an off-grid or
        // out-of-range base normalizes even with no drag.
        #expect(RSVPEngine.holdSpeedWPM(baseWPM: 305, verticalTranslation: 0) == 310)
        #expect(RSVPEngine.holdSpeedWPM(baseWPM: 50, verticalTranslation: 0) == 100)
    }

    @MainActor
    @Test func engineEffectiveWPMFollowsOverrideWithoutTouchingBase() {
        let engine = RSVPEngine(words: ["a", "b", "c"], wordsPerMinute: 300)
        #expect(engine.effectiveWordsPerMinute == 300)
        engine.wpmOverride = 500
        #expect(engine.effectiveWordsPerMinute == 500)
        #expect(engine.wordsPerMinute == 300)
    }

    @MainActor
    @Test func enginePauseClearsWPMOverride() {
        let engine = RSVPEngine(words: ["a", "b", "c"], wordsPerMinute: 300)
        engine.play()
        engine.wpmOverride = 700
        engine.pause()
        #expect(engine.wpmOverride == nil)
        #expect(engine.effectiveWordsPerMinute == 300)
    }

    @MainActor
    @Test func engineResumesAtBaseSpeedAfterPause() {
        let engine = RSVPEngine(words: ["a", "b", "c"], wordsPerMinute: 300)
        engine.play()
        engine.wpmOverride = 900
        engine.pause()
        engine.play()
        #expect(engine.isPlaying)
        #expect(engine.effectiveWordsPerMinute == 300)
        engine.pause()
    }

    // Base 60 WPM = 1 s/word (three words ≈ 3 s to finish). Raising the override
    // to 6000 WPM = 10 ms/word must let playback finish well under the ~800 ms
    // budget — impossible unless baseInterval derives from the override.
    @MainActor
    @Test func enginePlaybackTimerHonorsWPMOverride() async throws {
        let engine = RSVPEngine(words: ["a", "b", "c"], wordsPerMinute: 60)
        engine.play()
        engine.wpmOverride = 6000
        for _ in 0..<80 where engine.isPlaying {   // ~800 ms budget
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.isAtEnd)
        #expect(!engine.isPlaying)
        engine.pause()
    }

    // MARK: - WordStorage round-trip

    @Test func wordStorageEncodeDecodeRoundTrip() {
        let words = ["Hello", "world", "test", "café", "naïve"]
        let encoded = WordStorage.encode(words)
        let decoded = WordStorage.decode(encoded)
        #expect(decoded == words)
    }

    @Test func wordStorageEmptyArray() {
        let encoded = WordStorage.encode([])
        let decoded = WordStorage.decode(encoded)
        #expect(decoded == [])
    }

    // MARK: - Text cleaning patterns

    @Test func removesStandalonePageNumbers() {
        let cleaned = TextCleaner.cleanText("42\nSome real text here.\n- 7 -", level: .standard)
        #expect(!cleaned.contains("42"))
        #expect(!cleaned.contains("- 7 -"))
        #expect(cleaned.contains("real text"))
    }

    @Test func removesPageOfPatterns() {
        let cleaned = TextCleaner.cleanText("Page 5 of 100\nContent here.\npage 12", level: .standard)
        #expect(!cleaned.contains("Page 5"))
        #expect(!cleaned.contains("page 12"))
        #expect(cleaned.contains("Content here"))
    }

    @Test func removesISBNLines() {
        let cleaned = TextCleaner.cleanText("ISBN 978-0-123456-78-9\nActual content.", level: .standard)
        #expect(!cleaned.contains("ISBN"))
        #expect(cleaned.contains("Actual content"))
    }

    @Test func removesCopyrightNotices() {
        let cleaned = TextCleaner.cleanText("© 2024 Author Name\nAll rights reserved.\nReal text.", level: .standard)
        #expect(!cleaned.contains("©"))
        #expect(!cleaned.contains("All rights reserved"))
        #expect(cleaned.contains("Real text"))
    }

    @Test func removesNavigationText() {
        let cleaned = TextCleaner.cleanText("Next Chapter\nParagraph content.\nTable of Contents", level: .standard)
        #expect(!cleaned.lowercased().contains("next chapter"))
        #expect(!cleaned.lowercased().contains("table of contents"))
        #expect(cleaned.contains("Paragraph content"))
    }

    @Test func removesPublisherBoilerplate() {
        let cleaned = TextCleaner.cleanText("Published by Penguin\nFirst edition 2023\nStory begins here.", level: .standard)
        #expect(!cleaned.contains("Published by"))
        #expect(!cleaned.contains("First edition"))
        #expect(cleaned.contains("Story begins"))
    }

    @Test func removesTocLeaderLines() {
        let cleaned = TextCleaner.cleanText("Chapter 1 ......... 15\nActual paragraph.", level: .standard)
        #expect(!cleaned.contains("......"))
        #expect(cleaned.contains("Actual paragraph"))
    }

    @Test func cleaningLevelNonePreservesEverything() {
        let input = "Page 5\n42\nISBN 978-0-123456-78-9\nReal text."
        let cleaned = TextCleaner.cleanText(input, level: .none)
        #expect(cleaned == input)
    }

    // MARK: - Title resolution

    @Test func resolveTitlePrefersMetadata() {
        let title = DocumentImportPipeline.resolveTitle(metadataTitle: "My Book", fileName: "ugly_file-name.pdf")
        #expect(title == "My Book")
    }

    @Test func resolveTitleFallsBackToCleanedFileName() {
        let title = DocumentImportPipeline.resolveTitle(metadataTitle: nil, fileName: "my_cool-book.pdf")
        #expect(title == "My Cool Book")
    }

    @Test func resolveTitleHandlesEmptyMetadata() {
        let title = DocumentImportPipeline.resolveTitle(metadataTitle: "  ", fileName: "fallback.epub")
        #expect(title == "Fallback")
    }

    // MARK: - Chinese / CJK tokenization

    @Test func tokenizesChineseTextIntoWords() {
        let words = Tokenizer.tokenize("今天天气很好")
        // NLTokenizer should segment this into multiple words, not one blob
        #expect(words.count > 1)
        // Rejoining should give back the original text
        #expect(words.joined() == "今天天气很好")
    }

    @Test func tokenizesMixedChineseEnglish() {
        let words = Tokenizer.tokenize("Hello 世界 is great")
        #expect(words.contains("Hello"))
        #expect(words.contains("is"))
        #expect(words.contains("great"))
        // 世界 should appear as a token (possibly with punctuation attached)
        #expect(words.contains(where: { $0.contains("世界") }))
    }

    @Test func attachesChinesePunctuationToPrecedingWord() {
        let words = Tokenizer.tokenize("你好。世界")
        // The 。 should be attached to the word before it, not standalone
        #expect(words.contains(where: { $0.hasSuffix("。") }))
        #expect(!words.contains("。"))
    }

    // MARK: - Arabic support

    @Test func tokenizesArabicText() {
        let words = Tokenizer.tokenize("مرحبا بالعالم")
        #expect(words == ["مرحبا", "بالعالم"])
    }

    // MARK: - Complexity timing

    @Test func complexityMultiplierAtMidpointIsUnity() {
        let multiplier = RSVPEngine.complexityMultiplier(score: 0.5, speedUp: 1.0, slowDown: 1.0)
        #expect(multiplier == 1.0)
    }

    @Test func complexityMultiplierSpeedsUpSimpleWords() {
        let multiplier = RSVPEngine.complexityMultiplier(score: 0.0, speedUp: 1.0, slowDown: 1.0)
        #expect(abs(multiplier - 0.4) < 1e-9)
    }

    @Test func complexityMultiplierSlowsComplexWords() {
        let multiplier = RSVPEngine.complexityMultiplier(score: 1.0, speedUp: 1.0, slowDown: 1.0)
        #expect(abs(multiplier - 1.6) < 1e-9)
    }

    /// Each side of average follows its own intensity and ignores the
    /// other's.
    @Test func complexitySpeedUpAndSlowDownAreIndependent() {
        #expect(RSVPEngine.complexityMultiplier(score: 0.0, speedUp: 0, slowDown: 1) == 1)
        #expect(RSVPEngine.complexityMultiplier(score: 1.0, speedUp: 1, slowDown: 0) == 1)
        #expect(abs(RSVPEngine.complexityMultiplier(score: 0.25, speedUp: 0.5, slowDown: 1) - 0.85) < 1e-9)
        #expect(abs(RSVPEngine.complexityMultiplier(score: 0.75, speedUp: 1, slowDown: 0.5) - 1.15) < 1e-9)
        // An average word is never changed.
        #expect(RSVPEngine.complexityMultiplier(score: 0.5, speedUp: 0.3, slowDown: 0.9) == 1)
    }

    /// The one intensity from before moves into both of its replacements,
    /// once, and leaves either alone once it's set.
    @Test func legacyComplexityIntensityMovesIntoBothDirections() throws {
        typealias Keys = ReaderSettings.Keys
        let suiteName = "ReaderSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(0.8, forKey: Keys.legacyComplexityIntensity)
        ReaderSettings.migrate(defaults)
        #expect(defaults.object(forKey: Keys.legacyComplexityIntensity) == nil)
        let snapshot = ReaderSettings.timingSnapshot(from: defaults)
        #expect(snapshot.complexitySpeedUpIntensity == 0.8)
        #expect(snapshot.complexitySlowDownIntensity == 0.8)

        // Nothing to move: the settings stay as they are.
        defaults.set(0.2, forKey: Keys.complexitySpeedUpIntensity)
        ReaderSettings.migrate(defaults)
        #expect(defaults.double(forKey: Keys.complexitySpeedUpIntensity) == 0.2)
        #expect(defaults.double(forKey: Keys.complexitySlowDownIntensity) == 0.8)

        // A fresh install has nothing to move and keeps the defaults.
        defaults.removePersistentDomain(forName: suiteName)
        ReaderSettings.migrate(defaults)
        #expect(defaults.object(forKey: Keys.complexitySpeedUpIntensity) == nil)
        #expect(defaults.object(forKey: Keys.complexitySlowDownIntensity) == nil)
    }

    /// ReaderSettings.timingSnapshot seeds RSVPEngine before @AppStorage is
    /// usable; its fallback defaults must match the engine's own initializer
    /// defaults or a fresh install would behave differently depending on the
    /// code path that created the engine.
    @Test func readerSettingsSnapshotDefaultsMatchEngineDefaults() throws {
        let suiteName = "ReaderSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let snapshot = ReaderSettings.timingSnapshot(from: defaults)
        let engine = RSVPEngine(words: ["word"])

        #expect(snapshot.smartTimingEnabled == engine.smartTimingEnabled)
        #expect(snapshot.sentencePauseEnabled == engine.sentencePauseEnabled)
        #expect(snapshot.smartTimingPercentPerLetter == engine.smartTimingPercentPerLetter)
        #expect(snapshot.smartTimingMinimumWordLength == engine.smartTimingMinimumWordLength)
        #expect(snapshot.sentencePauseMultiplier == engine.sentencePauseMultiplier)
        #expect(snapshot.complexityTimingEnabled == engine.complexityTimingEnabled)
        #expect(snapshot.complexitySpeedUpIntensity == engine.complexitySpeedUpIntensity)
        #expect(snapshot.complexitySlowDownIntensity == engine.complexitySlowDownIntensity)
    }

    @Test func readerSettingsSnapshotReadsStoredValues() throws {
        let suiteName = "ReaderSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: ReaderSettings.Keys.smartTimingEnabled)
        defaults.set(7.0, forKey: ReaderSettings.Keys.smartTimingPercentPerLetter)
        defaults.set(6, forKey: ReaderSettings.Keys.smartTimingMinimumWordLength)
        defaults.set(2.5, forKey: ReaderSettings.Keys.sentencePauseMultiplier)

        let snapshot = ReaderSettings.timingSnapshot(from: defaults)
        #expect(snapshot.smartTimingEnabled == true)
        #expect(snapshot.smartTimingPercentPerLetter == 7.0)
        #expect(snapshot.smartTimingMinimumWordLength == 6)
        #expect(snapshot.sentencePauseMultiplier == 2.5)
        // Unset keys still fall back to defaults.
        #expect(snapshot.complexityTimingEnabled == ReaderSettings.Defaults.complexityTimingEnabled)
    }

    @Test func complexityMultiplierAtZeroIntensityIsUnity() {
        let low = RSVPEngine.complexityMultiplier(score: 0.0, speedUp: 0.0, slowDown: 0.0)
        let high = RSVPEngine.complexityMultiplier(score: 1.0, speedUp: 0.0, slowDown: 0.0)
        #expect(low == 1.0)
        #expect(high == 1.0)
    }

    @Test func complexityAnalyzerProducesCorrectCount() {
        let words = ["the", "quick", "brown", "fox"]
        let scores = WordComplexityAnalyzer.analyzeComplexity(words)
        #expect(scores.count == words.count)
    }

    @Test func complexityAnalyzerScoresCommonWordsLow() {
        let scores = WordComplexityAnalyzer.analyzeComplexity(["the", "is", "and", "epistemological"])
        // Common words should score lower than a rare, long word
        #expect(scores[0] < scores[3])
        #expect(scores[1] < scores[3])
        #expect(scores[2] < scores[3])
    }

    @Test func complexityAnalyzerHandlesEmptyInput() {
        let scores = WordComplexityAnalyzer.analyzeComplexity([])
        #expect(scores.isEmpty)
    }

    /// Whether this environment's NLTagger has usable lexical-class models.
    /// CI iOS simulators can lack the linguistic assets and tag every word
    /// `.otherWord`, which makes exact-tag assertions meaningless there.
    nonisolated static var lexicalTaggingAvailable: Bool {
        WordComplexityAnalyzer.tagText(words: ["the"]).lexical.first == .determiner
    }

    /// Runs everywhere, even without linguistic assets: the tag tables must
    /// always be parallel to the word array.
    @Test func complexityTagTablesMatchWordCount() {
        let words = ["He", "said", "stop—go", "now", "please", "tomorrow"]
        let (lexical, entity) = WordComplexityAnalyzer.tagText(words: words)
        #expect(lexical.count == words.count)
        #expect(entity.count == words.count)
    }

    /// NLTagger splits tokens the app tokenizer keeps whole (e.g. the em-dash
    /// compound "stop—go"). Tags must stay aligned to the word array by
    /// character offset, not by token count — a counting bug shifted every
    /// tag after the first split token.
    @Test(.enabled(if: StrobeTests.lexicalTaggingAvailable))
    func complexityTagsStayAlignedAcrossTaggerSplitTokens() {
        let words = ["He", "said", "stop—go", "now", "please", "tomorrow"]
        let (lexical, _) = WordComplexityAnalyzer.tagText(words: words)

        // "said" and the words after the split compound keep their own tags.
        #expect(lexical[1] == .verb)
        #expect(lexical[3] == .adverb)
        // The last word still receives a tag (the counting bug ran past the
        // end of the array and left trailing words untagged).
        #expect(lexical[5] != nil)
    }

    @Test(.enabled(if: StrobeTests.lexicalTaggingAvailable))
    func complexityTagsAlignForPlainText() {
        let words = ["The", "quick", "brown", "fox", "jumps"]
        let (lexical, _) = WordComplexityAnalyzer.tagText(words: words)
        #expect(lexical[0] == .determiner)
        #expect(lexical[1] == .adjective)
        #expect(lexical[3] == .noun)
    }

    /// A token starting with a combining mark (common in messy PDF
    /// extractions) merges with the preceding joiner space into a single
    /// grapheme cluster, so a Character-counted offset table desyncs from
    /// the joined text — every word after the malformed token then receives
    /// its neighbor's tag. Offsets must be scalar-based to stay exact.
    @Test(.enabled(if: StrobeTests.lexicalTaggingAvailable))
    func complexityTagsStayAlignedAfterLeadingCombiningMark() {
        let words = ["He", "said", "\u{0301}stop", "the", "quick", "tomorrow"]
        let (lexical, _) = WordComplexityAnalyzer.tagText(words: words)

        // Words after the combining-mark token keep their own tags instead
        // of shifting one index back.
        #expect(lexical[3] == .determiner)
        #expect(lexical[4] == .adjective)
        #expect(lexical[5] != nil)
    }

    // MARK: - ORP anchor position

    /// The Optimal Recognition Point sits left of center, around the 1/3 mark.
    /// Pins the classic mapping so the anchor never regresses to dead center.
    @Test func orpLetterPositionFollowsClassicMapping() {
        #expect(WordView.orpLetterPosition(letterCount: 1) == 0)
        #expect(WordView.orpLetterPosition(letterCount: 2) == 1)
        #expect(WordView.orpLetterPosition(letterCount: 5) == 1)
        #expect(WordView.orpLetterPosition(letterCount: 6) == 2)
        #expect(WordView.orpLetterPosition(letterCount: 9) == 2)
        #expect(WordView.orpLetterPosition(letterCount: 10) == 3)
        #expect(WordView.orpLetterPosition(letterCount: 13) == 3)
        #expect(WordView.orpLetterPosition(letterCount: 14) == 4)
        #expect(WordView.orpLetterPosition(letterCount: 20) == 4)
    }

    @Test func orpLetterPositionStaysLeftOfCenterForLongWords() {
        for letterCount in 4...30 {
            let pos = WordView.orpLetterPosition(letterCount: letterCount)
            #expect(pos < letterCount / 2, "ORP for \(letterCount)-letter word should sit left of center")
        }
    }

    /// The ORP centering offset shifts the word sideways after it has been
    /// fitted; unclamped, long words ran off the trailing screen edge.
    @Test func orpAnchorOffsetIsClampedToAvailableWidth() {
        // Plenty of slack: the ideal offset passes through unchanged.
        #expect(WordView.clampedAnchorOffset(idealOffset: 30, wordWidth: 200, availableWidth: 400) == 30)
        #expect(WordView.clampedAnchorOffset(idealOffset: -30, wordWidth: 200, availableWidth: 400) == -30)

        // Offset would push the word past the edge: clamped to the slack.
        #expect(WordView.clampedAnchorOffset(idealOffset: 150, wordWidth: 300, availableWidth: 400) == 50)
        #expect(WordView.clampedAnchorOffset(idealOffset: -150, wordWidth: 300, availableWidth: 400) == -50)

        // Word as wide as (or wider than) the space: plain centering.
        #expect(WordView.clampedAnchorOffset(idealOffset: 80, wordWidth: 400, availableWidth: 400) == 0)
        #expect(WordView.clampedAnchorOffset(idealOffset: 80, wordWidth: 500, availableWidth: 400) == 0)
    }

    /// A clamped offset must keep both word edges inside the view for any
    /// word narrower than the available width.
    @Test func clampedOffsetKeepsWordWithinBounds() {
        let availableWidth: CGFloat = 393
        for wordWidth in stride(from: CGFloat(50), through: 392, by: 38) {
            for ideal in stride(from: CGFloat(-300), through: 300, by: 60) {
                let offset = WordView.clampedAnchorOffset(
                    idealOffset: ideal, wordWidth: wordWidth, availableWidth: availableWidth
                )
                let leftEdge = availableWidth / 2 - wordWidth / 2 + offset
                let rightEdge = availableWidth / 2 + wordWidth / 2 + offset
                #expect(leftEdge >= 0, "left edge out of bounds for width \(wordWidth), ideal \(ideal)")
                #expect(rightEdge <= availableWidth, "right edge out of bounds for width \(wordWidth), ideal \(ideal)")
            }
        }
    }

    // MARK: - Reader text tone

    @Test func readerTextToneResolvesStoredValues() {
        for tone in ReaderTextTone.allCases {
            #expect(ReaderTextTone.resolve(tone.rawValue) == tone)
        }
        #expect(ReaderTextTone.resolve("") == ReaderTextTone.defaultValue)
        #expect(ReaderTextTone.resolve("magenta") == ReaderTextTone.defaultValue)
    }

    @Test func complexityStorageRoundTrip() {
        let scores: [Float] = [0.1, 0.5, 0.9, 0.0, 1.0]
        let encoded = ComplexityStorage.encode(scores)
        let decoded = ComplexityStorage.decode(encoded)
        #expect(decoded == scores)
    }

    @Test func complexityStorageEmptyArray() {
        let encoded = ComplexityStorage.encode([])
        let decoded = ComplexityStorage.decode(encoded)
        #expect(decoded.isEmpty)
    }

    // MARK: - Mixed language (CJK + Latin)

    @Test func tokenizesChineseWithLatinInterspersed() {
        // Common pattern: Chinese text with English brand names / tech terms
        let words = Tokenizer.tokenize("我在使用iPhone阅读")
        #expect(words.count >= 2)
        // All original text should be preserved
        #expect(words.joined() == "我在使用iPhone阅读")
    }

    // MARK: - ZIP security

    @Test func zipExtractorRejectsPathTraversal() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Build a minimal ZIP with a path-traversal entry: "../../evil.txt"
        let zipData = buildMinimalZIP(name: "../../evil.txt", content: Data("pwned".utf8))
        let zipURL = tempDir.appendingPathComponent("malicious.zip")
        try zipData.write(to: zipURL)

        let extractDir = tempDir.appendingPathComponent("extracted")
        try ZIPExtractor.extract(zipAt: zipURL, to: extractDir)

        // The file should NOT exist outside the extraction directory
        let escapedFile = tempDir.appendingPathComponent("evil.txt")
        #expect(!FileManager.default.fileExists(atPath: escapedFile.path))
    }

    @Test func zipEntryURLStaysInsideDestination() {
        let destination = URL(fileURLWithPath: "/private/var/mobile/tmp/epub_x", isDirectory: true)

        func path(_ name: String) -> String? {
            ZIPExtractor.entryURL(forEntryNamed: name, in: destination)?.path
        }

        #expect(path("mimetype") == "/private/var/mobile/tmp/epub_x/mimetype")
        #expect(path("META-INF/container.xml") == "/private/var/mobile/tmp/epub_x/META-INF/container.xml")
        #expect(path("./OEBPS//ch1.xhtml") == "/private/var/mobile/tmp/epub_x/OEBPS/ch1.xhtml")
        #expect(path("/etc/passwd") == "/private/var/mobile/tmp/epub_x/etc/passwd")
        #expect(path("..hidden/notes..txt") == "/private/var/mobile/tmp/epub_x/..hidden/notes..txt")
        #expect(ZIPExtractor.entryURL(forEntryNamed: "OEBPS/", in: destination)?.hasDirectoryPath == true)
        #expect(ZIPExtractor.entryURL(forEntryNamed: "OEBPS/ch1.xhtml", in: destination)?.hasDirectoryPath == false)

        #expect(path("") == nil)
        #expect(path("/") == nil)
        #expect(path("./") == nil)
        #expect(path("..") == nil)
        #expect(path("../evil.txt") == nil)
        #expect(path("a/../../evil.txt") == nil)
        #expect(path("a/b\u{0}.txt") == nil)
    }

    /// U+0600 (Prepend) and U+0301 (combining) each fuse with an adjacent `/`
    /// into one grapheme cluster, so a `Character`-level split never sees a
    /// bare `..` component even though the kernel does.
    @Test func zipExtractorRejectsGraphemeFusedPathTraversal() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fused = "\u{0600}/../../\u{0301}evil.txt"
        #expect(!fused.split(separator: "/").contains(".."))
        #expect(ZIPExtractor.entryURL(forEntryNamed: fused, in: tempDir) == nil)

        let entries: [(name: String, content: Data, useDataDescriptor: Bool)] = [
            ("\u{0600}/placeholder.txt", Data("ok".utf8), false),
            (fused, Data("pwned".utf8), false),
        ]
        let zipURL = tempDir.appendingPathComponent("malicious.zip")
        try buildZIPWithCentralDirectory(entries: entries).write(to: zipURL)

        let extractDir = tempDir.appendingPathComponent("extracted")
        try ZIPExtractor.extract(zipAt: zipURL, to: extractDir)

        let outside = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        #expect(Set(outside) == ["malicious.zip", "extracted"])
    }

    /// iOS devices place the temp directory under `/private/var`. macOS exposes
    /// the same path shape via the `/var` symlink; the simulator does not, so
    /// there this only exercises the plain temp directory.
    @Test func zipExtractorExtractsIntoPrivatePrefixedDestination() throws {
        let plainTemp = FileManager.default.temporaryDirectory
        let privateTemp = URL(fileURLWithPath: "/private" + plainTemp.path, isDirectory: true)
        var isDirectory: ObjCBool = false
        let hasPrivateAlias = FileManager.default.fileExists(atPath: privateTemp.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        #if os(macOS)
        // A sandboxed test host keeps its temp directory in its container,
        // outside `/var`, where there is no `/private` alias to exercise.
        if plainTemp.path.hasPrefix("/var/") {
            #expect(hasPrivateAlias)
        }
        #endif

        let tempDir = (hasPrivateAlias ? privateTemp : plainTemp)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let entries: [(name: String, content: Data, useDataDescriptor: Bool)] = [
            ("mimetype", Data("application/epub+zip".utf8), false),
            ("META-INF/container.xml", Data("<container/>".utf8), false),
            ("OEBPS/content.opf", Data("<package/>".utf8), true),
        ]
        let zipURL = tempDir.appendingPathComponent("book.epub")
        try buildZIPWithCentralDirectory(entries: entries).write(to: zipURL)

        let extractDir = tempDir.appendingPathComponent("epub_extract", isDirectory: true)
        try ZIPExtractor.extract(zipAt: zipURL, to: extractDir)

        for entry in entries {
            let extracted = extractDir.appendingPathComponent(entry.name)
            #expect(try Data(contentsOf: extracted) == entry.content, "missing \(entry.name)")
        }
    }

    @Test func zipInflateCapsDecompressionBuffer() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Build a ZIP whose uncompressed-size header claims ~200 MB (exceeds 100 MB cap).
        // The actual content is tiny, but the header tricks the allocator.
        let content = Data("hello".utf8)
        var zip = Data()
        let name = Data("bomb.txt".utf8)

        // Local file header
        zip.append(contentsOf: withUnsafeBytes(of: UInt32(0x04034b50).littleEndian) { Data($0) })
        zip.append(contentsOf: withUnsafeBytes(of: UInt16(20).littleEndian) { Data($0) })   // version
        zip.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian) { Data($0) })    // flags
        zip.append(contentsOf: withUnsafeBytes(of: UInt16(8).littleEndian) { Data($0) })    // compression: deflate
        zip.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian) { Data($0) })    // mod time
        zip.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian) { Data($0) })    // mod date
        zip.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Data($0) })    // crc32
        zip.append(contentsOf: withUnsafeBytes(of: UInt32(content.count).littleEndian) { Data($0) })  // compressed size
        zip.append(contentsOf: withUnsafeBytes(of: UInt32(200_000_000).littleEndian) { Data($0) })    // uncompressed: 200 MB
        zip.append(contentsOf: withUnsafeBytes(of: UInt16(name.count).littleEndian) { Data($0) })
        zip.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian) { Data($0) })    // extra length
        zip.append(name)
        zip.append(content)

        let zipURL = tempDir.appendingPathComponent("bomb.zip")
        try zip.write(to: zipURL)

        let extractDir = tempDir.appendingPathComponent("extracted")
        try ZIPExtractor.extract(zipAt: zipURL, to: extractDir)

        // The file should NOT be extracted (inflate returns nil due to cap)
        let extractedFile = extractDir.appendingPathComponent("bomb.txt")
        #expect(!FileManager.default.fileExists(atPath: extractedFile.path))
    }

    // MARK: - ZIP central directory

    @Test func zipExtractorReadsAllEntriesViaCentralDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let entries: [(name: String, content: Data, useDataDescriptor: Bool)] = [
            ("mimetype", Data("application/epub+zip".utf8), false),
            ("META-INF/container.xml", Data("<container/>".utf8), false),
            ("OEBPS/content.opf", Data("<package/>".utf8), false),
            ("OEBPS/chapter1.xhtml", Data("first chapter body".utf8), false),
        ]
        let zip = buildZIPWithCentralDirectory(entries: entries)
        let zipURL = tempDir.appendingPathComponent("test.zip")
        try zip.write(to: zipURL)

        let extractDir = tempDir.appendingPathComponent("extracted")
        try ZIPExtractor.extract(zipAt: zipURL, to: extractDir)

        for entry in entries {
            let extracted = try Data(contentsOf: extractDir.appendingPathComponent(entry.name))
            #expect(extracted == entry.content, "entry \(entry.name) round-trips through extraction")
        }
    }

    /// Reproduces the App Store bug where EPUBs produced by tools that stream
    /// the archive (Sigil, Calibre, Pages) failed to extract. Those tools set
    /// GP-flag bit 3, zero out the size fields in the local header, and place
    /// the real sizes in a data descriptor after the payload. Walking local
    /// headers blindly stops at the first such entry; parsing the central
    /// directory recovers the authoritative sizes.
    @Test func zipExtractorHandlesEntriesWithDataDescriptors() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let entries: [(name: String, content: Data, useDataDescriptor: Bool)] = [
            ("mimetype", Data("application/epub+zip".utf8), false),
            // container.xml uses a data descriptor — this is the entry the
            // original bug reporter's EPUB was failing to extract.
            ("META-INF/container.xml", Data("<container/>".utf8), true),
            ("OEBPS/content.opf", Data("<package/>".utf8), true),
        ]
        let zip = buildZIPWithCentralDirectory(entries: entries)
        let zipURL = tempDir.appendingPathComponent("test.zip")
        try zip.write(to: zipURL)

        let extractDir = tempDir.appendingPathComponent("extracted")
        try ZIPExtractor.extract(zipAt: zipURL, to: extractDir)

        for entry in entries {
            let extractedURL = extractDir.appendingPathComponent(entry.name)
            #expect(
                FileManager.default.fileExists(atPath: extractedURL.path),
                "entry \(entry.name) was extracted"
            )
            let extracted = try Data(contentsOf: extractedURL)
            #expect(extracted == entry.content, "entry \(entry.name) extracted with correct bytes")
        }
    }

    /// The per-entry decompression cap doesn't stop an archive packed with
    /// many entries from exhausting temp storage; the cumulative budget must
    /// bound total bytes written. Entries over the remaining budget are
    /// skipped rather than aborting the archive, so media-heavy but
    /// legitimate EPUBs still import.
    @Test func zipExtractorSkipsEntriesOverTotalExtractionBudget() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let entries: [(name: String, content: Data, useDataDescriptor: Bool)] = [
            ("a.txt", Data(repeating: 0x41, count: 10), false),
            ("b.txt", Data(repeating: 0x42, count: 10), false),
            ("c.txt", Data(repeating: 0x43, count: 10), false),
        ]
        let zipURL = tempDir.appendingPathComponent("test.zip")
        try buildZIPWithCentralDirectory(entries: entries).write(to: zipURL)

        // Budget covers only the first two entries — the third is skipped,
        // but extraction succeeds and earlier entries are intact.
        let cappedDir = tempDir.appendingPathComponent("capped")
        try ZIPExtractor.extract(zipAt: zipURL, to: cappedDir, maxTotalBytes: 25)
        #expect(try Data(contentsOf: cappedDir.appendingPathComponent("a.txt")) == entries[0].content)
        #expect(try Data(contentsOf: cappedDir.appendingPathComponent("b.txt")) == entries[1].content)
        #expect(!FileManager.default.fileExists(atPath: cappedDir.appendingPathComponent("c.txt").path))

        // A sufficient budget extracts everything.
        let fullDir = tempDir.appendingPathComponent("full")
        try ZIPExtractor.extract(zipAt: zipURL, to: fullDir, maxTotalBytes: 30)
        for entry in entries {
            let extracted = try Data(contentsOf: fullDir.appendingPathComponent(entry.name))
            #expect(extracted == entry.content)
        }
    }

    /// The EOCD record can be followed by a comment of up to 65535 bytes.
    /// `findEOCD` must locate the record even when the file doesn't end
    /// exactly at the EOCD's fixed-size portion.
    @Test func zipExtractorLocatesEOCDWithTrailingComment() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let entries: [(name: String, content: Data, useDataDescriptor: Bool)] = [
            ("README.txt", Data("hello".utf8), false),
        ]
        let comment = Data(repeating: 0x21, count: 128) // 128 bytes of '!'
        let zip = buildZIPWithCentralDirectory(entries: entries, comment: comment)
        let zipURL = tempDir.appendingPathComponent("test.zip")
        try zip.write(to: zipURL)

        let extractDir = tempDir.appendingPathComponent("extracted")
        try ZIPExtractor.extract(zipAt: zipURL, to: extractDir)

        let extracted = try Data(contentsOf: extractDir.appendingPathComponent("README.txt"))
        #expect(extracted == Data("hello".utf8))
    }

    @Test func epubExtractionReadsContainerXMLFromDataDescriptorArchive() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0">
          <metadata>
            <dc:title>Review EPUB</dc:title>
          </metadata>
          <manifest>
            <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="chapter1"/>
          </spine>
        </package>
        """

        let chapter = """
        <html>
          <body>
            <p>Hello review reader.</p>
          </body>
        </html>
        """

        let entries: [(name: String, content: Data, useDataDescriptor: Bool)] = [
            ("mimetype", Data("application/epub+zip".utf8), false),
            ("META-INF/container.xml", Data(containerXML.utf8), true),
            ("OEBPS/content.opf", Data(opf.utf8), true),
            ("OEBPS/chapter1.xhtml", Data(chapter.utf8), true),
        ]

        let epubURL = tempDir.appendingPathComponent("review.epub")
        try buildZIPWithCentralDirectory(entries: entries).write(to: epubURL)

        let result = try EPUBTextExtractor.extractWordsAndChapters(from: epubURL)
        #expect(result.words.contains("Hello"))
        #expect(result.words.contains("review"))
        #expect(result.words.contains("reader."))
    }

    /// Real-world EPUB 3 nav documents often wrap link text in child elements
    /// (`<a><span>Chapter 1</span></a>`). The nav parser must read descendant
    /// text instead of dropping those chapters.
    @Test func epubNavChapterTitlesSurviveNestedSpans() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0">
          <metadata>
            <dc:title>Nested Nav EPUB</dc:title>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>
            <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="c1"/>
            <itemref idref="c2"/>
          </spine>
        </package>
        """

        let nav = """
        <html xmlns="http://www.w3.org/1999/xhtml">
          <body>
            <nav epub:type="toc">
              <ol>
                <li><a href="chapter1.xhtml"><span>Chapter One</span></a></li>
                <li><a href="chapter2.xhtml">Chapter <em>Two</em></a></li>
              </ol>
            </nav>
          </body>
        </html>
        """

        let chapter1 = "<html><body><p>First chapter words here.</p></body></html>"
        let chapter2 = "<html><body><p>Second chapter words here.</p></body></html>"

        let entries: [(name: String, content: Data, useDataDescriptor: Bool)] = [
            ("mimetype", Data("application/epub+zip".utf8), false),
            ("META-INF/container.xml", Data(containerXML.utf8), false),
            ("OEBPS/content.opf", Data(opf.utf8), false),
            ("OEBPS/nav.xhtml", Data(nav.utf8), false),
            ("OEBPS/chapter1.xhtml", Data(chapter1.utf8), false),
            ("OEBPS/chapter2.xhtml", Data(chapter2.utf8), false),
        ]

        let epubURL = tempDir.appendingPathComponent("nested-nav.epub")
        try buildZIPWithCentralDirectory(entries: entries).write(to: epubURL)

        let result = try EPUBTextExtractor.extractWordsAndChapters(from: epubURL)
        #expect(result.title == "Nested Nav EPUB")
        #expect(result.chapters.count == 2)
        #expect(result.chapters.first?.title == "Chapter One")
        #expect(result.chapters.last?.title == "Chapter Two")
        #expect(result.chapters.first?.wordIndex == 0)
    }

    // MARK: - PDF error propagation

    @Test func pdfExtractionThrowsForInvalidFile() {
        do {
            _ = try DocumentImportPipeline.extractWordsAndChapters(
                from: URL(fileURLWithPath: "/tmp/nonexistent.pdf"),
                detectedContentType: .pdf
            )
            Issue.record("Expected PDF extraction to throw an error for a missing file.")
        } catch let error as DocumentImportError {
            #expect(error == .pdfLoadFailed)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - CJK utilities

    @Test func cjkUtilitiesDetectsAllRanges() {
        // CJK Unified Ideographs
        #expect(CJKUtilities.isCJK(Unicode.Scalar(0x4E00)!))
        // CJK Extension A
        #expect(CJKUtilities.isCJK(Unicode.Scalar(0x3400)!))
        // CJK Compatibility
        #expect(CJKUtilities.isCJK(Unicode.Scalar(0xF900)!))
        // CJK Extension B
        #expect(CJKUtilities.isCJK(Unicode.Scalar(0x20000)!))
        // CJK punctuation
        #expect(CJKUtilities.isCJK(Unicode.Scalar(0x3001)!))  // 、
        // Fullwidth forms
        #expect(CJKUtilities.isCJK(Unicode.Scalar(0xFF01)!))  // ！
        // Bopomofo
        #expect(CJKUtilities.isCJK(Unicode.Scalar(0x3105)!))
        // Hiragana
        #expect(CJKUtilities.isCJK(Unicode.Scalar(0x3042)!))  // あ
        // Katakana
        #expect(CJKUtilities.isCJK(Unicode.Scalar(0x30A2)!))  // ア
        // Latin should NOT match
        #expect(!CJKUtilities.isCJK(Unicode.Scalar(0x0041)!)) // A
    }

    @Test func cjkUtilitiesHanIdeographExcludesKana() {
        // Han ideograph should match
        #expect(CJKUtilities.isHanIdeograph(Unicode.Scalar(0x4E00)!))
        // Hiragana should NOT match isHanIdeograph
        #expect(!CJKUtilities.isHanIdeograph(Unicode.Scalar(0x3042)!))
        // Fullwidth should NOT match isHanIdeograph
        #expect(!CJKUtilities.isHanIdeograph(Unicode.Scalar(0xFF01)!))
    }

    @Test func cjkUtilitiesIsCJKDominant() {
        #expect(CJKUtilities.isCJKDominant("你好世界"))
        #expect(!CJKUtilities.isCJKDominant("Hello World"))
        #expect(CJKUtilities.isCJKDominant("你好世界ab"))  // 4/6 CJK > 50%
    }

    // MARK: - ComplexityStorage alignment safety

    @Test func complexityStorageDecodesSubsetOfData() {
        // Verify decode handles data that's not an exact multiple of Float size
        let scores: [Float] = [0.1, 0.2, 0.3]
        var encoded = ComplexityStorage.encode(scores)
        encoded.append(contentsOf: [0xFF, 0xFF]) // extra trailing bytes
        let decoded = ComplexityStorage.decode(encoded)
        #expect(decoded == scores) // should ignore trailing partial float
    }

    // MARK: - HTML entity resolution

    @Test func resolvesNamedHTMLEntities() {
        let input = "Hello&nbsp;World&amp;Co &lt;tag&gt; &quot;quoted&quot; &apos;apos&apos;"
        let result = EPUBTextExtractor.resolveHTMLEntities(input)
        #expect(result == "Hello World&Co <tag> \"quoted\" 'apos'")
    }

    @Test func resolvesTypographicEntities() {
        let input = "word&mdash;word&ndash;word&hellip;more"
        let result = EPUBTextExtractor.resolveHTMLEntities(input)
        #expect(result == "word\u{2014}word\u{2013}word\u{2026}more")
    }

    @Test func resolvesQuoteEntities() {
        let input = "&lsquo;single&rsquo; &ldquo;double&rdquo;"
        let result = EPUBTextExtractor.resolveHTMLEntities(input)
        #expect(result == "\u{2018}single\u{2019} \u{201C}double\u{201D}")
    }

    @Test func resolvesDecimalNumericEntities() {
        // &#65; = 'A', &#8212; = em dash
        let input = "&#65; &#8212; &#169;"
        let result = EPUBTextExtractor.resolveHTMLEntities(input)
        #expect(result == "A \u{2014} \u{00A9}")
    }

    @Test func resolvesHexNumericEntities() {
        // &#x41; = 'A', &#x2014; = em dash, &#x1F600; = grinning face emoji
        let input = "&#x41; &#x2014; &#x1F600;"
        let result = EPUBTextExtractor.resolveHTMLEntities(input)
        #expect(result == "A \u{2014} \u{1F600}")
    }

    @Test func numericEntityWithMissingSemicolonEmitsLiteral() {
        // No semicolon — should emit the literal '&' and continue
        let input = "&#65 next"
        let result = EPUBTextExtractor.resolveHTMLEntities(input)
        #expect(result == "&#65 next")
    }

    @Test func numericEntityWithEmptyDigitsEmitsLiteral() {
        // &#; has no digits — should pass through
        let input = "&#; text"
        let result = EPUBTextExtractor.resolveHTMLEntities(input)
        #expect(result == "&#; text")
    }

    @Test func numericEntityWithInvalidCodePointEmitsLiteral() {
        // 0xFFFFFF is not a valid Unicode scalar
        let input = "&#xFFFFFF; text"
        let result = EPUBTextExtractor.resolveHTMLEntities(input)
        #expect(result == "&#xFFFFFF; text")
    }

    @Test func mixedNamedAndNumericEntities() {
        let input = "&amp;&#38;&#x26;"  // all three ways to encode '&'
        let result = EPUBTextExtractor.resolveHTMLEntities(input)
        #expect(result == "&&&")
    }

    @Test func textWithNoEntitiesPassesThrough() {
        let input = "Plain text with no entities at all."
        let result = EPUBTextExtractor.resolveHTMLEntities(input)
        #expect(result == input)
    }

    // MARK: - EPUB structural markers

    private func importStructuredEPUB(body: String, nav: String? = nil, ncx: String? = nil,
                                      cleaning: TextCleaningLevel = .standard) throws -> EPUBExtractionResult {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let container = #"<container><rootfiles><rootfile full-path="OEBPS/book.opf"/></rootfiles></container>"#
        let opf = """
        <package><metadata><title>Structure</title></metadata><manifest>
        <item id="body" href="Text/./book%20one.xhtml"/>
        <item id="nav" href="Navigation/nav.xhtml" properties="nav"/>
        <item id="ncx" href="Navigation/toc.ncx"/>
        </manifest><spine toc="ncx"><itemref idref="body"/></spine></package>
        """
        var entries: [(name: String, content: Data, useDataDescriptor: Bool)] = [
            ("META-INF/container.xml", Data(container.utf8), false),
            ("OEBPS/book.opf", Data(opf.utf8), false),
            ("OEBPS/Text/book one.xhtml", Data(body.utf8), false),
        ]
        if let nav { entries.append(("OEBPS/Navigation/nav.xhtml", Data(nav.utf8), false)) }
        if let ncx { entries.append(("OEBPS/Navigation/toc.ncx", Data(ncx.utf8), false)) }
        let url = dir.appendingPathComponent("book.epub")
        try buildZIPWithCentralDirectory(entries: entries).write(to: url)
        return try EPUBTextExtractor.extractWordsAndChapters(from: url, cleaningLevel: cleaning)
    }

    @Test(arguments: [TextCleaningLevel.none, .standard])
    func epubPreservesNestedFragmentTargetsAndIgnoresOtherNavigation(cleaning: TextCleaningLevel) throws {
        let body = """
        <html><head><title>Hidden title</title></head><body>
        Copyright notice to remove
        <h1 id="part">Part One</h1><p>Opening words.</p>
        <h2 id="chapter">First Chapter</h2><p>Chapter body.</p>
        <h3 id="séc%20">Section &amp; <em>detail</em></h3><p>Section body.</p>
        <h4>Unlisted subdivision</h4><p>Last body.</p><a id="end"/>
        </body></html>
        """
        let nav = """
        <html><body>
        <nav epub:type="page-list"><a href="../Text/book%20one.xhtml#part">Page 1</a></nav>
        <nav epub:type="toc"><ol>
          <li><a href="../Text/book%20one.xhtml#part">Part One</a><ol>
            <li><a href="../Text/book%20one.xhtml#chapter">Chapter label</a><ol>
              <li><a href="../Text/book%20one.xhtml#s%C3%A9c%2520"><span>Section label</span></a></li>
            </ol></li>
          </ol></li>
          <li><a href="../Text/book%20one.xhtml#missing">Broken link</a></li>
          <li><a href="../Text/book%20one.xhtml#end">Empty tail</a></li>
        </ol></nav>
        <nav epub:type="landmarks"><a href="../Text/book%20one.xhtml#chapter">Body matter</a></nav>
        </body></html>
        """
        let result = try importStructuredEPUB(body: body, nav: nav, cleaning: cleaning)
        #expect(result.chapters.map(\.title) == ["Part One", "Chapter label", "Section label", "Unlisted subdivision"])
        #expect(result.chapters.map { result.words[$0.wordIndex] } == ["Part", "First", "Section&", "Unlisted"])
        #expect(!result.words.contains("Hidden"))
        #expect(Set(result.chapters.map(\.wordIndex)).count == result.chapters.count)
    }

    @Test func epubNCXRetainsParentsChildrenAndDeepSiblings() throws {
        let body = """
        <body><p id="part">Part words</p><p id="chapter">Chapter words</p>
        <p id="section">Section words</p><p id="subsection">Subsection words</p>
        <p id="sibling">Sibling words</p></body>
        """
        let ncx = """
        <ncx><navMap><navPoint><navLabel><text>Part</text></navLabel><content src="../Text/book%20one.xhtml#part"/>
          <navPoint><navLabel><text>Chapter</text></navLabel><content src="../Text/book%20one.xhtml#chapter"/>
            <navPoint><navLabel><text>Section</text></navLabel><content src="../Text/book%20one.xhtml#section"/>
              <navPoint><navLabel><text>Subsection</text></navLabel><content src="../Text/book%20one.xhtml#subsection"/></navPoint>
            </navPoint>
            <navPoint><navLabel><text>Sibling</text></navLabel><content src="../Text/book%20one.xhtml#sibling"/></navPoint>
          </navPoint>
        </navPoint></navMap></ncx>
        """
        let result = try importStructuredEPUB(body: body, ncx: ncx)
        #expect(result.chapters.map(\.title) == ["Part", "Chapter", "Section", "Subsection", "Sibling"])
        #expect(result.chapters.map(\.wordIndex) == [0, 2, 4, 6, 8])
    }

    @Test func epubHeadingsWorkWithoutTOCAndKeepInlineWordsIntact() throws {
        let body = """
        <body><!-- <h1>Fake heading</h1> -->
        <h1 data-note="a > b">Part <em>One</em></h1>
        <p>he<a id="inline"/>llo world. 中文测试</p>
        <script><h2>Hidden script</h2></script><table><tr><td>123</td></tr></table>
        <h2>1</h2><p>Next subchapter.</p></body>
        """
        let result = try importStructuredEPUB(body: body)
        #expect(result.chapters.map(\.title) == ["Part One", "1"])
        #expect(result.words.contains("hello"))
        #expect(!result.words.contains("Hidden"))
        #expect(!result.words.contains("Fake"))
        #expect(result.words[result.chapters[1].wordIndex] == "1")
    }

    @Test func epubMarkerMappingPreservesTokenizerOutput() {
        let source = """
        <body><p id="a">infor-</p><p id="b">mation and one-in-a-</p>
        <p id="c">lifetime he<span id="d"/>llo 中文测试 &amp; more.</p>
        <p>unmerged-</p><h2 id="e">Chapter two</h2></body>
        """
        let content = EPUBContent.parse(Data(source.utf8))
        var words: [String] = []
        var carry: String?
        let positions = content.appendWords(cleanedText: content.text, into: &words, carry: &carry)
        if let carry { words.append(carry) }
        #expect(words == Tokenizer.tokenize(content.text))
        #expect(words[positions[content.anchors["b"]!]!] == "information")
        #expect(words[positions[content.anchors["d"]!]!] == "hello")
        #expect(words[positions[content.anchors["e"]!]!] == "Chapter")
    }

    @Test func cleaningCanPreserveUTF16PositionsForEPUBMarkers() {
        let input = "Copyright © 😀\n42\nActual readable words."
        let preserved = TextCleaner.cleanPages([input], level: .standard, preserveOffsets: true)[0]
        #expect(preserved.utf16.count == input.utf16.count)
        #expect((preserved as NSString).range(of: "Actual").location == (input as NSString).range(of: "Actual").location)
        #expect(Tokenizer.tokenize(preserved) == Tokenizer.tokenize(TextCleaner.cleanText(input, level: .standard)))
    }

    @Test func epubEmptyAndTrailingAnchorsDoNotPointIntoTheNextFile() {
        for source in ["<body><a id='empty'/></body>", "<body>words<a id='empty'/></body>"] {
            let content = EPUBContent.parse(Data(source.utf8))
            var words: [String] = []
            var carry: String?
            let positions = content.appendWords(cleanedText: content.text, into: &words, carry: &carry)
            #expect(positions[content.anchors["empty"]!] == nil)
        }
    }

    // MARK: - ZIP test helpers

    /// Builds a ZIP archive with stored (uncompressed) entries, a full central
    /// directory, and an EOCD record. Each entry may optionally use a data
    /// descriptor (GP-flag bit 3): the local header's size fields are zeroed
    /// and the real sizes are written after the payload, mirroring the layout
    /// produced by streaming EPUB tools like Sigil and Calibre.
    private func buildZIPWithCentralDirectory(
        entries: [(name: String, content: Data, useDataDescriptor: Bool)],
        comment: Data = Data()
    ) -> Data {
        var zip = Data()
        var localHeaderOffsets: [Int] = []
        localHeaderOffsets.reserveCapacity(entries.count)

        // Local file headers + stored data (+ optional data descriptors)
        for entry in entries {
            localHeaderOffsets.append(zip.count)
            let nameData = Data(entry.name.utf8)
            let gpFlag: UInt16 = entry.useDataDescriptor ? 0x0008 : 0
            let headerCompressedSize: UInt32 = entry.useDataDescriptor ? 0 : UInt32(entry.content.count)
            let headerUncompressedSize: UInt32 = entry.useDataDescriptor ? 0 : UInt32(entry.content.count)

            zip.append(uint32LE(0x04034b50))            // local file header signature
            zip.append(uint16LE(20))                    // version needed
            zip.append(uint16LE(gpFlag))                // general purpose bit flag
            zip.append(uint16LE(0))                     // compression: stored
            zip.append(uint16LE(0))                     // mod time
            zip.append(uint16LE(0))                     // mod date
            zip.append(uint32LE(0))                     // crc-32 (extractor doesn't validate)
            zip.append(uint32LE(headerCompressedSize))
            zip.append(uint32LE(headerUncompressedSize))
            zip.append(uint16LE(UInt16(nameData.count)))
            zip.append(uint16LE(0))                     // extra length
            zip.append(nameData)
            zip.append(entry.content)

            if entry.useDataDescriptor {
                zip.append(uint32LE(0x08074b50))         // optional descriptor signature
                zip.append(uint32LE(0))                  // crc-32
                zip.append(uint32LE(UInt32(entry.content.count)))
                zip.append(uint32LE(UInt32(entry.content.count)))
            }
        }

        // Central directory
        let cdOffset = zip.count
        for (i, entry) in entries.enumerated() {
            let nameData = Data(entry.name.utf8)
            let gpFlag: UInt16 = entry.useDataDescriptor ? 0x0008 : 0

            zip.append(uint32LE(0x02014b50))            // central directory signature
            zip.append(uint16LE(20))                    // version made by
            zip.append(uint16LE(20))                    // version needed
            zip.append(uint16LE(gpFlag))
            zip.append(uint16LE(0))                     // compression: stored
            zip.append(uint16LE(0))                     // mod time
            zip.append(uint16LE(0))                     // mod date
            zip.append(uint32LE(0))                     // crc-32
            zip.append(uint32LE(UInt32(entry.content.count)))  // compressed size
            zip.append(uint32LE(UInt32(entry.content.count)))  // uncompressed size
            zip.append(uint16LE(UInt16(nameData.count)))
            zip.append(uint16LE(0))                     // extra length
            zip.append(uint16LE(0))                     // comment length
            zip.append(uint16LE(0))                     // disk number start
            zip.append(uint16LE(0))                     // internal attributes
            zip.append(uint32LE(0))                     // external attributes
            zip.append(uint32LE(UInt32(localHeaderOffsets[i])))
            zip.append(nameData)
        }
        let cdSize = zip.count - cdOffset

        // End of central directory record
        zip.append(uint32LE(0x06054b50))                // EOCD signature
        zip.append(uint16LE(0))                          // disk number
        zip.append(uint16LE(0))                          // disk with CD start
        zip.append(uint16LE(UInt16(entries.count)))      // entries on this disk
        zip.append(uint16LE(UInt16(entries.count)))      // total entries
        zip.append(uint32LE(UInt32(cdSize)))
        zip.append(uint32LE(UInt32(cdOffset)))
        zip.append(uint16LE(UInt16(comment.count)))
        zip.append(comment)

        return zip
    }

    private func uint16LE(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private func uint32LE(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// Builds a minimal valid ZIP archive containing a single stored (uncompressed) entry.
    private func buildMinimalZIP(name: String, content: Data) -> Data {
        let nameData = Data(name.utf8)
        var zip = Data()

        // Local file header
        zip.append(contentsOf: withUnsafeBytes(of: UInt32(0x04034b50).littleEndian) { Data($0) })  // signature
        zip.append(contentsOf: withUnsafeBytes(of: UInt16(20).littleEndian) { Data($0) })          // version needed
        zip.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian) { Data($0) })           // flags
        zip.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian) { Data($0) })           // compression (stored)
        zip.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian) { Data($0) })           // mod time
        zip.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian) { Data($0) })           // mod date
        zip.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Data($0) })           // crc32
        zip.append(contentsOf: withUnsafeBytes(of: UInt32(content.count).littleEndian) { Data($0) }) // compressed size
        zip.append(contentsOf: withUnsafeBytes(of: UInt32(content.count).littleEndian) { Data($0) }) // uncompressed size
        zip.append(contentsOf: withUnsafeBytes(of: UInt16(nameData.count).littleEndian) { Data($0) }) // name length
        zip.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian) { Data($0) })           // extra length
        zip.append(nameData)
        zip.append(content)

        return zip
    }

    // MARK: - PassageView search

    @Test func findMatchesReturnsEmptyForEmptyQuery() {
        let words = ["hello", "world", "hello"]
        #expect(PassageView.findMatches(query: "", in: words).isEmpty)
        #expect(PassageView.findMatches(query: "   ", in: words).isEmpty)
        #expect(PassageView.findMatches(query: "\n\t ", in: words).isEmpty)
    }

    @Test func findMatchesReturnsAscendingIndices() {
        let words = ["alpha", "beta", "alpha", "gamma", "alpha"]
        let matches = PassageView.findMatches(query: "alpha", in: words)
        #expect(matches == [0, 2, 4])
    }

    @Test func findMatchesIsCaseInsensitive() {
        let words = ["Hello", "WORLD", "hello"]
        #expect(PassageView.findMatches(query: "HELLO", in: words) == [0, 2])
        #expect(PassageView.findMatches(query: "world", in: words) == [1])
    }

    @Test func findMatchesAcceptsSubstrings() {
        // Should match anywhere inside a word, not just whole-word equality.
        let words = ["recovery", "recovered", "discovery", "cover"]
        let matches = PassageView.findMatches(query: "cover", in: words)
        #expect(matches == [0, 1, 2, 3])
    }

    @Test func findMatchesTrimsWhitespaceAroundQuery() {
        let words = ["the", "quick", "brown", "fox"]
        #expect(PassageView.findMatches(query: "  quick  ", in: words) == [1])
    }

    @Test func findMatchesHandlesPunctuationInWords() {
        // Words come from the tokenizer with attached punctuation; substring
        // search should still find the bare query inside them.
        let words = ["don't", "end.", "\"hello\""]
        #expect(PassageView.findMatches(query: "don", in: words) == [0])
        #expect(PassageView.findMatches(query: "end", in: words) == [1])
        #expect(PassageView.findMatches(query: "hello", in: words) == [2])
    }

    @Test func findMatchesSupportsCJKSubstrings() {
        let words = ["你好", "世界", "你好啊"]
        #expect(PassageView.findMatches(query: "你好", in: words) == [0, 2])
    }

    @Test func findMatchesReturnsEmptyWhenNoWordMatches() {
        let words = ["alpha", "beta", "gamma"]
        #expect(PassageView.findMatches(query: "delta", in: words).isEmpty)
    }

    // Issue #6: queries containing whitespace always returned zero matches
    // because each word was tested for containing the space-joined needle.

    @Test func findMatchesPhraseAcrossConsecutiveWords() {
        let words = ["we", "ate", "banana", "pie", "today"]
        #expect(PassageView.findMatches(query: "banana pie", in: words) == [2])
        #expect(PassageView.findMatches(query: "ate banana pie", in: words) == [1])
    }

    @Test func findMatchesPhraseIsCaseInsensitive() {
        let words = ["Banana", "Pie"]
        #expect(PassageView.findMatches(query: "banana PIE", in: words) == [0])
    }

    @Test func findMatchesPhraseAllowsTrailingPunctuationOnLastWord() {
        // Tokenized words keep punctuation attached; "pie." still begins
        // with "pie", matching how the passage text reads.
        let words = ["we", "ate", "banana", "pie.", "yum"]
        #expect(PassageView.findMatches(query: "banana pie", in: words) == [2])
    }

    @Test func findMatchesPhraseUsesSuffixAndPrefixAtBoundaries() {
        // Substring-of-passage semantics: the first token may end a word and
        // the last may begin one — "na pie" occurs inside "banana pies".
        let words = ["banana", "pies"]
        #expect(PassageView.findMatches(query: "na pie", in: words) == [0])
    }

    @Test func findMatchesPhraseRequiresExactMiddleWords() {
        let words = ["big", "banana", "cream", "pie"]
        #expect(PassageView.findMatches(query: "banana cream pie", in: words) == [1])
        #expect(PassageView.findMatches(query: "banana creamy pie", in: words).isEmpty)
        // Punctuation between the words means the passage doesn't read as the
        // queried phrase, so strict adjacency correctly rejects it.
        let punctuated = ["big", "banana,", "cream", "pie"]
        #expect(PassageView.findMatches(query: "banana cream pie", in: punctuated).isEmpty)
    }

    @Test func findMatchesPhraseFindsOverlappingOccurrences() {
        let words = ["fish", "fish", "fish"]
        #expect(PassageView.findMatches(query: "fish fish", in: words) == [0, 1])
    }

    @Test func findMatchesPhraseNormalizesInteriorWhitespace() {
        let words = ["banana", "pie"]
        #expect(PassageView.findMatches(query: "  banana   pie  ", in: words) == [0])
    }

    @Test func findMatchesPhraseLongerThanDocumentIsEmpty() {
        let words = ["banana"]
        #expect(PassageView.findMatches(query: "banana pie", in: words).isEmpty)
        #expect(PassageView.findMatches(query: "a b", in: []).isEmpty)
    }

    @Test func findMatchesPhraseSupportsCJKWords() {
        let words = ["你好", "世界", "你好啊"]
        #expect(PassageView.findMatches(query: "你好 世界", in: words) == [0])
    }

    @Test func matchRangesCoverOneWordPerQueryToken() {
        let words = ["i", "ate", "banana", "cream", "pie"]
        #expect(PassageView.findMatchRanges(query: "banana", inLowercasedWords: words) == [2..<3])
        #expect(PassageView.findMatchRanges(query: "banana cream", inLowercasedWords: words) == [2..<4])
        #expect(PassageView.findMatchRanges(query: "  banana   cream  pie ", inLowercasedWords: words) == [2..<5])
        #expect(PassageView.findMatchRanges(query: "", inLowercasedWords: words).isEmpty)
        #expect(PassageView.findMatchRanges(query: "   ", inLowercasedWords: words).isEmpty)
    }

    @Test func coveredIndicesSpanEveryMatchedWord() {
        #expect(PassageView.coveredIndices(of: [2..<4, 7..<9]) == [2, 3, 7, 8])
        #expect(PassageView.coveredIndices(of: [1..<2]) == [1])
        #expect(PassageView.coveredIndices(of: [0..<2, 1..<3]) == [0, 1, 2])
        #expect(PassageView.coveredIndices(of: []).isEmpty)
    }

    // MARK: - PassageView nearest-match

    @Test func nearestMatchPositionIsZeroForEmptyMatches() {
        #expect(PassageView.nearestMatchPosition(to: 50, in: []) == 0)
    }

    @Test func nearestMatchPositionHandlesSingleMatch() {
        #expect(PassageView.nearestMatchPosition(to: 0, in: [42]) == 0)
        #expect(PassageView.nearestMatchPosition(to: 100, in: [42]) == 0)
    }

    @Test func nearestMatchPositionLandsOnExactHit() {
        let matches = [10, 30, 50, 70]
        #expect(PassageView.nearestMatchPosition(to: 30, in: matches) == 1)
        #expect(PassageView.nearestMatchPosition(to: 70, in: matches) == 3)
    }

    @Test func nearestMatchPositionClampsBelowFirstAndAboveLast() {
        let matches = [10, 30, 50, 70]
        // Target before all matches → first match (index 0)
        #expect(PassageView.nearestMatchPosition(to: 0, in: matches) == 0)
        #expect(PassageView.nearestMatchPosition(to: -100, in: matches) == 0)
        // Target after all matches → last match
        #expect(PassageView.nearestMatchPosition(to: 100, in: matches) == 3)
    }

    @Test func nearestMatchPositionPicksCloserNeighbor() {
        let matches = [10, 30, 50, 70]
        // 14 is closer to 10 than 30 → index 0
        #expect(PassageView.nearestMatchPosition(to: 14, in: matches) == 0)
        // 28 is closer to 30 than 10 → index 1
        #expect(PassageView.nearestMatchPosition(to: 28, in: matches) == 1)
        // 60 is closer to 50 than 70 → index 2
        #expect(PassageView.nearestMatchPosition(to: 60, in: matches) == 2)
    }

    @Test func nearestMatchPositionBreaksTieTowardEarlierMatch() {
        // 20 is equidistant between 10 and 30 — tie breaks to the earlier (10).
        let matches = [10, 30]
        #expect(PassageView.nearestMatchPosition(to: 20, in: matches) == 0)
    }

    // MARK: - Document furthest-read progress

    /// A standalone (not inserted into a container) document with `count` words.
    private func makeDocument(wordCount count: Int) -> Document {
        Document(
            title: "Test",
            fileName: "test",
            bookmarkData: Data(),
            words: Array(repeating: "word", count: count)
        )
    }

    @Test func newDocumentStartsWithZeroProgress() {
        let doc = makeDocument(wordCount: 11)
        #expect(doc.furthestWordIndex == 0)
        #expect(doc.progress == 0)
        #expect(doc.progressPercentage == 0)
    }

    @Test func newDocumentSeedsFurthestFromStartingIndex() {
        let doc = Document(
            title: "Test",
            fileName: "test",
            bookmarkData: Data(),
            words: Array(repeating: "word", count: 11),
            currentWordIndex: 4
        )
        #expect(doc.furthestWordIndex == 4)
    }

    @Test func progressReflectsFurthestNotCurrentPosition() {
        // Navigating backward (currentWordIndex behind the furthest marker)
        // must not lower the displayed progress.
        let doc = makeDocument(wordCount: 11)
        doc.furthestWordIndex = 5
        doc.currentWordIndex = 2
        #expect(doc.displayedFurthestWordIndex == 5)
        #expect(doc.progress == 0.5)
        #expect(doc.progressPercentage == 50)
    }

    @Test func progressFallsBackToCurrentIndexForMigratedDocuments() {
        // Documents saved before furthestWordIndex existed migrate with 0;
        // display must not regress below the previously saved position.
        let doc = makeDocument(wordCount: 11)
        doc.currentWordIndex = 8
        doc.furthestWordIndex = 0
        #expect(doc.displayedFurthestWordIndex == 8)
        #expect(doc.progress == 0.8)
        #expect(doc.progressPercentage == 80)
    }

    @Test func progressIsCompleteAtLastWord() {
        let doc = makeDocument(wordCount: 11)
        doc.furthestWordIndex = 10
        #expect(doc.progress == 1.0)
        #expect(doc.progressPercentage == 100)
    }

    @Test func progressHandlesDegenerateWordCounts() {
        let empty = makeDocument(wordCount: 0)
        #expect(empty.progress == 0)

        let single = makeDocument(wordCount: 1)
        #expect(single.progress == 0)
        single.furthestWordIndex = 1
        #expect(single.progress == 1)
    }

    @Test func singleWordDocumentCompletesOnceRead() {
        // A single-word document can never advance its indices past 0 —
        // having been read (lastReadDate set) is the completion signal.
        let single = makeDocument(wordCount: 1)
        #expect(single.progress == 0)
        single.recordPosition(currentIndex: 0, wordsPerMinute: 300, touchLastReadDate: true)
        #expect(single.progress == 1)
    }

    // MARK: - Document.recordPosition

    @Test func recordPositionAdvancesCurrentAndFurthest() {
        let doc = makeDocument(wordCount: 11)
        doc.recordPosition(currentIndex: 6, wordsPerMinute: 420, touchLastReadDate: false)
        #expect(doc.currentWordIndex == 6)
        #expect(doc.furthestWordIndex == 6)
        #expect(doc.wordsPerMinute == 420)
        #expect(doc.lastReadDate == nil)
    }

    @Test func recordPositionNeverLowersFurthestMarker() {
        let doc = makeDocument(wordCount: 11)
        doc.recordPosition(currentIndex: 8, wordsPerMinute: 300, touchLastReadDate: false)
        doc.recordPosition(currentIndex: 2, wordsPerMinute: 300, touchLastReadDate: false)
        #expect(doc.currentWordIndex == 2)
        #expect(doc.furthestWordIndex == 8)
    }

    @Test func recordPositionFoldsLegacySavedPositionIntoFurthest() {
        // Documents saved before the marker existed: currentWordIndex holds
        // the old position and furthest migrated as 0. Recording a smaller
        // outgoing index must adopt the old position as the floor.
        let doc = makeDocument(wordCount: 11)
        doc.currentWordIndex = 7
        doc.furthestWordIndex = 0
        doc.recordPosition(currentIndex: 3, wordsPerMinute: 300, touchLastReadDate: false)
        #expect(doc.furthestWordIndex == 7)
        #expect(doc.currentWordIndex == 3)
    }

    @Test func recordPositionTouchesLastReadDateOnlyWhenAsked() {
        let doc = makeDocument(wordCount: 11)
        doc.recordPosition(currentIndex: 1, wordsPerMinute: 300, touchLastReadDate: false)
        #expect(doc.lastReadDate == nil)
        doc.recordPosition(currentIndex: 1, wordsPerMinute: 300, touchLastReadDate: true)
        #expect(doc.lastReadDate != nil)
    }

    // MARK: - Legacy word-storage migration

    @Test func compactLegacyWordStorageMigratesWordsToBlob() {
        let doc = makeDocument(wordCount: 0)
        // Simulate a pre-blob document: words in the legacy array, no blob.
        doc.wordsBlob = nil
        doc.words = ["alpha", "beta", "gamma"]
        doc.compactWordStorageIfNeeded()
        #expect(doc.wordsBlob != nil)
        #expect(doc.words.isEmpty)
        #expect(doc.wordCount == 3)
        #expect(doc.readingWords == ["alpha", "beta", "gamma"])
    }

    @Test func compactLegacyWordStorageIsNoOpWhenBlobExists() {
        let doc = makeDocument(wordCount: 2)
        // Leftover legacy words mustn't replace the blob.
        doc.words = ["stale"]
        let blobBefore = doc.wordsBlob
        let countBefore = doc.wordCount
        doc.compactWordStorageIfNeeded()
        #expect(doc.wordsBlob == blobBefore)
        #expect(doc.wordCount == countBefore)
    }

    // MARK: - Engine loading & clamping

    @Test func emptyEngineIsNotAtEndAndDoesNotPlay() {
        let engine = RSVPEngine(words: [])
        #expect(!engine.isAtEnd)
        #expect(engine.progress == 0)
        engine.play()
        #expect(!engine.isPlaying)
    }

    @Test func engineInitClampsOutOfBoundsIndex() {
        let past = RSVPEngine(words: ["a", "b"], currentIndex: 10)
        #expect(past.currentIndex == 1)
        let negative = RSVPEngine(words: ["a", "b"], currentIndex: -5)
        #expect(negative.currentIndex == 0)
    }

    @Test func engineLoadReplacesWordsAndClampsIndex() {
        let engine = RSVPEngine(words: [])
        engine.load(words: ["a", "b", "c"], currentIndex: 99, complexityScores: [0.1, 0.2, 0.3])
        #expect(engine.currentIndex == 2)
        #expect(engine.currentWord == "c")
        #expect(engine.complexityScores == [0.1, 0.2, 0.3])
    }

    // MARK: - Engine live playback

    // MainActor for two reasons: the engine (and its main-queue timer) is
    // main-actor-isolated, and staying on the actor between play() and the
    // first assertion means the timer can't fire in that window — the
    // "isPlaying right after play()" check would otherwise race the ~30 ms
    // playback under parallel test load.
    @MainActor
    @Test func enginePlaybackAdvancesAndAutoPausesAtEnd() async throws {
        // 6000 WPM → 10 ms per word; three words should finish in ~30 ms.
        let engine = RSVPEngine(words: ["a", "b", "c"], wordsPerMinute: 6000)
        engine.play()
        #expect(engine.isPlaying)

        for _ in 0..<400 where engine.isPlaying {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(engine.currentIndex == 2)
        #expect(engine.isAtEnd)
        #expect(!engine.isPlaying) // auto-paused at the last word
    }

    // MARK: - Chapter math

    private func makeChapters(_ starts: [Int]) -> [Chapter] {
        starts.enumerated().map { Chapter(title: "Ch \($0.offset + 1)", wordIndex: $0.element) }
    }

    @Test func chapterBoundsUseNextChapterStartOrTotalCount() {
        let chapters = makeChapters([0, 100, 250])
        let first = ChapterListView.chapterBounds(at: 0, chapters: chapters, totalWordCount: 400)
        #expect(first.start == 0 && first.end == 100)
        let last = ChapterListView.chapterBounds(at: 2, chapters: chapters, totalWordCount: 400)
        #expect(last.start == 250 && last.end == 400)
    }

    @Test func chapterRowResumesInsideChapterOtherwiseStartsAtChapter() {
        let chapters = makeChapters([0, 100, 250])
        // Current position inside chapter 1 → resume there.
        #expect(ChapterListView.startingWordIndex(forChapterAt: 1, chapters: chapters, totalWordCount: 400, currentWordIndex: 150) == 150)
        // Current position outside chapter 1 → start at the chapter.
        #expect(ChapterListView.startingWordIndex(forChapterAt: 1, chapters: chapters, totalWordCount: 400, currentWordIndex: 50) == 100)
        // Sitting exactly on the chapter start → chapter start.
        #expect(ChapterListView.startingWordIndex(forChapterAt: 1, chapters: chapters, totalWordCount: 400, currentWordIndex: 100) == 100)
        // Sitting on the chapter's last word restarts it (the `end - 1` rule).
        #expect(ChapterListView.startingWordIndex(forChapterAt: 1, chapters: chapters, totalWordCount: 400, currentWordIndex: 249) == 100)
    }

    @Test func chapterStatusReflectsFurthestPosition() {
        let chapters = makeChapters([0, 100, 250])
        #expect(ChapterListView.chapterStatus(at: 1, chapters: chapters, totalWordCount: 400, furthestWordIndex: 0) == .notStarted)
        #expect(ChapterListView.chapterStatus(at: 1, chapters: chapters, totalWordCount: 400, furthestWordIndex: 150) == .inProgress)
        #expect(ChapterListView.chapterStatus(at: 1, chapters: chapters, totalWordCount: 400, furthestWordIndex: 249) == .completed)
        // Final chapter completes at the document's last word.
        #expect(ChapterListView.chapterStatus(at: 2, chapters: chapters, totalWordCount: 400, furthestWordIndex: 399) == .completed)
    }

    // MARK: - Tokenizer carry ordering

    @Test func carryFlushesBeforeCJKText() {
        // A trailing hyphenated fragment must be emitted before following CJK
        // words, not appended after them. (How NLTokenizer segments 你好 —
        // one word or two — is not what's under test here.)
        let words = Tokenizer.tokenize("informa- 你好")
        #expect(words.first == "informa-")
        #expect(words.dropFirst().joined() == "你好")
    }

    // MARK: - Entity double-encoding

    @Test func doubleEncodedEntitiesDecodeExactlyOnce() {
        // Single-pass resolution: the output of one entity is never rescanned.
        #expect(EPUBTextExtractor.resolveHTMLEntities("&amp;lt;") == "&lt;")
        #expect(EPUBTextExtractor.resolveHTMLEntities("&amp;#65;") == "&#65;")
        #expect(EPUBTextExtractor.resolveHTMLEntities("&amp;amp;") == "&amp;")
    }

    // MARK: - Plain text import

    @Test func plainTextImportTokenizesFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("strobe_test_\(UUID().uuidString).txt")
        try "hello plain world".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try DocumentImportPipeline.extractWordsAndChapters(from: url)
        #expect(result.words == ["hello", "plain", "world"])
        #expect(result.complexityScores.count == 3)
        #expect(result.sourceType == .plainText)
        #expect(result.chapters.isEmpty)
    }

    // MARK: - EPUB DRM detection

    @Test func drmProtectedEPUBIsRejected() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0">
          <manifest>
            <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="c1"/>
          </spine>
        </package>
        """

        // A spine content document is listed as encrypted → DRM.
        let encryptionXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
            <enc:CipherData>
              <enc:CipherReference URI="OEBPS/chapter1.xhtml"/>
            </enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """

        let entries: [(name: String, content: Data, useDataDescriptor: Bool)] = [
            ("mimetype", Data("application/epub+zip".utf8), false),
            ("META-INF/container.xml", Data(containerXML.utf8), false),
            ("META-INF/encryption.xml", Data(encryptionXML.utf8), false),
            ("OEBPS/content.opf", Data(opf.utf8), false),
            ("OEBPS/chapter1.xhtml", Data([0x00, 0x01, 0x02, 0x03]), false),
        ]

        let epubURL = tempDir.appendingPathComponent("drm.epub")
        try buildZIPWithCentralDirectory(entries: entries).write(to: epubURL)

        do {
            _ = try EPUBTextExtractor.extractWordsAndChapters(from: epubURL)
            Issue.record("Expected DRM-protected EPUB to be rejected.")
        } catch let error as DocumentImportError {
            #expect(error == .epubDRMProtected)
        }
    }

    @Test func fontObfuscationOnlyEncryptionIsAllowed() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0">
          <manifest>
            <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="c1"/>
          </spine>
        </package>
        """

        // Only a font is encrypted (the common benign use) — must import.
        let encryptionXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
            <enc:CipherData>
              <enc:CipherReference URI="OEBPS/fonts/body.otf"/>
            </enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """

        let chapter = "<html><body><p>Readable words here.</p></body></html>"

        let entries: [(name: String, content: Data, useDataDescriptor: Bool)] = [
            ("mimetype", Data("application/epub+zip".utf8), false),
            ("META-INF/container.xml", Data(containerXML.utf8), false),
            ("META-INF/encryption.xml", Data(encryptionXML.utf8), false),
            ("OEBPS/content.opf", Data(opf.utf8), false),
            ("OEBPS/chapter1.xhtml", Data(chapter.utf8), false),
        ]

        let epubURL = tempDir.appendingPathComponent("font-obfuscated.epub")
        try buildZIPWithCentralDirectory(entries: entries).write(to: epubURL)

        let result = try EPUBTextExtractor.extractWordsAndChapters(from: epubURL)
        #expect(result.words.contains("Readable"))
    }

    // MARK: - ZIP robustness (mutation sweep)

    /// The ZIP parser's safety rests on manual bounds checks — this sweep
    /// defends that invariant. Truncating a valid archive at every length and
    /// flipping bytes at deterministic positions must never crash the
    /// extractor; throwing or extracting garbage are both acceptable.
    @Test func zipExtractorSurvivesTruncationAndByteFlips() throws {
        let entries: [(name: String, content: Data, useDataDescriptor: Bool)] = [
            ("META-INF/container.xml", Data("<container/>".utf8), false),
            ("OEBPS/content.opf", Data(String(repeating: "<x/>", count: 50).utf8), true),
        ]
        let valid = buildZIPWithCentralDirectory(entries: entries)

        func attemptExtraction(_ data: Data) {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("zipfuzz_\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let zipURL = dir.appendingPathComponent("t.zip")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: zipURL)
                try ZIPExtractor.extract(zipAt: zipURL, to: dir.appendingPathComponent("out"))
            } catch {
                // Throwing on malformed input is correct behavior.
            }
        }

        // Every truncation length (stride keeps the sweep fast).
        var length = 0
        while length < valid.count {
            attemptExtraction(valid.prefix(length))
            length += 7
        }

        // Deterministic byte flips across the archive.
        var offset = 0
        while offset < valid.count {
            var mutated = valid
            mutated[offset] ^= 0xFF
            attemptExtraction(mutated)
            offset += 11
        }
    }

    // MARK: - PDF happy path

    /// Draws each page's text into a real PDF via CoreText so PDFKit's text
    /// extraction has something to find.
    private func makeTextPDF(pages: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("strobe_test_\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw DocumentImportError.pdfLoadFailed
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        for text in pages {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(
                string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: mediaBox.insetBy(dx: 50, dy: 50), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    @Test func pdfOutlineIncludesSubsectionsBeyondTwoLevels() throws {
        let url = try makeTextPDF(pages: ["Part begins", "Chapter begins", "Section begins", "Subsection begins"])
        defer { try? FileManager.default.removeItem(at: url) }
        let pdf = try #require(PDFDocument(url: url))
        let root = PDFOutline()
        var parent = root
        for (index, label) in ["Part", "Chapter", "Section", "Subsection"].enumerated() {
            let item = PDFOutline()
            item.label = label
            item.destination = PDFDestination(page: try #require(pdf.page(at: index)), at: .zero)
            parent.insertChild(item, at: 0)
            parent = item
        }
        pdf.outlineRoot = root
        // Exercise PDFKit's outline directly: serializing a synthetic outline
        // is OS-dependent and can drop the bookmarks on write.
        let chapters = PDFTextExtractor.extractChapters(from: pdf, pageWordOffsets: [0, 2, 4, 6])
        #expect(chapters.map(\.title) == ["Part", "Chapter", "Section", "Subsection"])
        #expect(chapters.map(\.wordIndex) == [0, 2, 4, 6])
    }

    @Test func pdfExtractionReadsTextFromPages() throws {
        let url = try makeTextPDF(pages: ["alpha beta gamma", "delta epsilon"])
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try PDFTextExtractor.extractWordsAndChapters(from: url, cleaningLevel: .none)
        #expect(result.words.contains("alpha"))
        #expect(result.words.contains("gamma"))
        #expect(result.words.contains("epsilon"))
        // Page 1's words precede page 2's.
        if let alphaIndex = result.words.firstIndex(of: "alpha"),
           let deltaIndex = result.words.firstIndex(of: "delta") {
            #expect(alphaIndex < deltaIndex)
        } else {
            Issue.record("Expected words from both pages to be extracted.")
        }
    }
}
