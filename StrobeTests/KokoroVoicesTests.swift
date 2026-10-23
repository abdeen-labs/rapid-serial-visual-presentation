import Foundation
import Testing
@testable import Strobe

/// Which voices reading aloud offers, which one reads for a stored choice,
/// and which documents they read.
struct KokoroVoicesTests {

    private typealias Voice = KokoroVoices.Voice

    /// The American and British voices the model's English bundle has, as
    /// FluidAudio lists them (`KokoroAneConstants.englishVoices`). Only
    /// these names load.
    private static let modelVoices: Set<String> = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore",
        "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael",
        "am_onyx", "am_puck", "am_santa",
        "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
    ]

    // MARK: - Catalog

    @Test func everyVoiceIsOneTheModelHas() {
        for voice in KokoroVoices.all {
            #expect(Self.modelVoices.contains(voice.id), "\(voice.id)")
        }
    }

    @Test func offersTheBetterRatedVoices() {
        #expect(Set(KokoroVoices.all.map(\.id)) == [
            "af_heart", "af_bella", "af_nicole", "af_aoede", "af_kore", "af_sarah", "af_nova", "af_alloy",
            "am_michael", "am_fenrir", "am_puck",
            "bf_emma", "bf_isabella",
            "bm_george", "bm_fable",
        ])
    }

    @Test func voicesAreListedOnce() {
        let ids = KokoroVoices.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        let names = KokoroVoices.all.map(\.name)
        #expect(Set(names).count == names.count)
    }

    /// The model's names say the accent and the gender, and the catalog
    /// agrees: `af_` is an American woman, `bm_` a British man.
    @Test func accentAndGenderFollowTheName() {
        for voice in KokoroVoices.all {
            let prefix = voice.id.prefix(3)
            let accent: KokoroVoices.Accent = prefix.hasPrefix("a") ? .american : .british
            let gender: KokoroVoices.Gender = prefix.dropFirst().hasPrefix("f") ? .female : .male
            #expect(voice.accent == accent, "\(voice.id)")
            #expect(voice.gender == gender, "\(voice.id)")
            #expect(prefix.hasSuffix("_"), "\(voice.id)")
        }
    }

    @Test func namesAreTheVoiceNamesCapitalized() {
        for voice in KokoroVoices.all {
            #expect(voice.name == voice.id.dropFirst(3).capitalized, "\(voice.id)")
        }
    }

    // MARK: - Default

    @Test func heartReadsByDefault() {
        #expect(KokoroVoices.defaultVoice.id == "af_heart")
        #expect(KokoroVoices.defaultVoice.gender == .female)
        #expect(KokoroVoices.all.first == KokoroVoices.defaultVoice)
        #expect(ReaderSettings.Defaults.readAloudVoice == KokoroVoices.defaultVoice.id)
    }

    @Test func aChosenVoiceReads() {
        #expect(KokoroVoices.chosen("bm_george").id == "bm_george")
        #expect(KokoroVoices.chosen("af_bella").name == "Bella")
    }

    /// A voice identifier stored before, a voice the model has but the
    /// catalog doesn't offer, or nothing, all read as the default.
    @Test func anythingElseReadsAsTheDefault() {
        #expect(KokoroVoices.chosen("com.apple.voice.premium.en-US.Ava") == KokoroVoices.defaultVoice)
        #expect(KokoroVoices.chosen("am_santa") == KokoroVoices.defaultVoice)
        #expect(KokoroVoices.chosen("") == KokoroVoices.defaultVoice)
        #expect(KokoroVoices.voice(id: "am_santa") == nil)
    }

    // MARK: - Groups

    @Test func groupsAreByAccentAmericanFirst() {
        #expect(KokoroVoices.groups.map(\.accent) == [.american, .british])
        #expect(KokoroVoices.groups.first?.voices.first == KokoroVoices.defaultVoice)
    }

    @Test func groupsHoldEveryVoiceWomenFirst() {
        let grouped = KokoroVoices.groups.flatMap(\.voices)
        #expect(Set(grouped) == Set(KokoroVoices.all))
        #expect(grouped.count == KokoroVoices.all.count)
        for group in KokoroVoices.groups {
            #expect(group.voices.allSatisfy { $0.accent == group.accent })
            let genders = group.voices.map(\.gender)
            let firstMan = genders.firstIndex(of: .male) ?? genders.endIndex
            #expect(genders[..<firstMan].allSatisfy { $0 == .female })
            #expect(genders[firstMan...].allSatisfy { $0 == .male })
        }
    }

    /// Best first within each accent and gender: the catalog's own order.
    @Test func groupsKeepTheCatalogsOrder() {
        for group in KokoroVoices.groups {
            for gender in [KokoroVoices.Gender.female, .male] {
                let listed = KokoroVoices.all.filter { $0.accent == group.accent && $0.gender == gender }
                #expect(group.voices.filter { $0.gender == gender } == listed)
            }
        }
    }

    @Test func theSampleSaysTheVoicesName() {
        let sample = KokoroVoices.sample(for: KokoroVoices.chosen("bf_emma"))
        #expect(sample.contains("Emma"))
    }

    // MARK: - Documents read

    @Test func readsEnglishDocuments() {
        #expect(KokoroVoices.canRead(documentLanguage: "en"))
        #expect(KokoroVoices.canRead(documentLanguage: "en-GB"))
    }

    /// Too little text to tell, as with a list of numbers, reads as English.
    @Test func readsDocumentsOfNoTellingLanguage() {
        #expect(KokoroVoices.canRead(documentLanguage: nil))
    }

    @Test func doesntReadOtherLanguages() {
        #expect(!KokoroVoices.canRead(documentLanguage: "fr"))
        #expect(!KokoroVoices.canRead(documentLanguage: "zh-Hans"))
        #expect(!KokoroVoices.canRead(documentLanguage: "es"))
        // Not English, though it starts like it.
        #expect(!KokoroVoices.canRead(documentLanguage: "eno"))
    }

    // MARK: - Document language

    private func words(_ sentence: String, times: Int) -> [String] {
        Array(repeating: sentence.split(separator: " ").map(String.init), count: times).flatMap { $0 }
    }

    @Test func detectsTheDocumentsLanguage() {
        #expect(DocumentLanguage.detect(in: words("The rain fell all night, and in the morning the river had risen.", times: 3)) == "en")
        #expect(DocumentLanguage.detect(in: words("Le chat dort sur la table pendant que la pluie tombe.", times: 3)) == "fr")
        #expect(DocumentLanguage.detect(in: words("我 是 学生 。 今天 天气 很 好 。", times: 3)) == "zh-Hans")
        #expect(DocumentLanguage.detect(in: words("我們 是 學生 。 今天 天氣 很 好 。", times: 3)) == "zh-Hant")
    }

    @Test func tooLittleTextHasNoLanguage() {
        #expect(DocumentLanguage.detect(in: []) == nil)
        #expect(DocumentLanguage.detect(in: ["2024", "1999", "42"]) == nil)
    }

    /// A long book is told by its start.
    @Test func onlyTheStartIsRead() {
        let english = words("The rain fell all night and the river rose high.", times: 200)
        #expect(english.count == DocumentLanguage.sampleWordCount)
        let french = words("Le chat dort sur la table pendant que la pluie tombe.", times: 500)
        #expect(DocumentLanguage.detect(in: english + french) == "en")
    }

    @Test func englishDocumentsAreRead() {
        let english = DocumentLanguage.detect(in: words("The rain fell all night, and in the morning the river had risen.", times: 3))
        let french = DocumentLanguage.detect(in: words("Le chat dort sur la table pendant que la pluie tombe.", times: 3))
        #expect(KokoroVoices.canRead(documentLanguage: english))
        #expect(!KokoroVoices.canRead(documentLanguage: french))
    }
}
