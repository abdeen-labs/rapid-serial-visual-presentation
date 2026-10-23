import Foundation

/// The voices reading aloud offers: the better-rated English voices of the
/// Kokoro voice model (``KokoroVoiceModel``), by the names the model knows
/// them by. A name's first letter is its accent (`a` American, `b` British)
/// and its second the voice's gender (`f`, `m`).
///
/// Heart, the best of them, reads unless another is chosen. A stored choice
/// the catalog doesn't offer, such as a voice identifier from before, reads
/// as Heart too.
nonisolated enum KokoroVoices {
    nonisolated struct Voice: Identifiable, Hashable, Sendable {
        /// The model's name for the voice, such as `af_heart`, and what the
        /// `readAloudVoice` setting stores.
        let id: String
        /// The name to show, such as Heart.
        let name: String
        let gender: Gender
        let accent: Accent
    }

    nonisolated enum Gender: Hashable, Sendable {
        case female
        case male
    }

    nonisolated enum Accent: Hashable, Sendable, CaseIterable {
        case american
        case british
    }

    /// The voices of one accent, women's first, best first within each.
    nonisolated struct Group: Identifiable, Hashable, Sendable {
        let accent: Accent
        let voices: [Voice]

        var id: Accent { accent }
    }

    /// Every voice offered, best first within each accent and gender.
    static let all: [Voice] = [
        Voice(id: "af_heart", name: "Heart", gender: .female, accent: .american),
        Voice(id: "af_bella", name: "Bella", gender: .female, accent: .american),
        Voice(id: "af_nicole", name: "Nicole", gender: .female, accent: .american),
        Voice(id: "af_aoede", name: "Aoede", gender: .female, accent: .american),
        Voice(id: "af_kore", name: "Kore", gender: .female, accent: .american),
        Voice(id: "af_sarah", name: "Sarah", gender: .female, accent: .american),
        Voice(id: "af_nova", name: "Nova", gender: .female, accent: .american),
        Voice(id: "af_alloy", name: "Alloy", gender: .female, accent: .american),
        Voice(id: "am_michael", name: "Michael", gender: .male, accent: .american),
        Voice(id: "am_fenrir", name: "Fenrir", gender: .male, accent: .american),
        Voice(id: "am_puck", name: "Puck", gender: .male, accent: .american),
        Voice(id: "bf_emma", name: "Emma", gender: .female, accent: .british),
        Voice(id: "bf_isabella", name: "Isabella", gender: .female, accent: .british),
        Voice(id: "bm_george", name: "George", gender: .male, accent: .british),
        Voice(id: "bm_fable", name: "Fable", gender: .male, accent: .british),
    ]

    /// Heart: a warm American woman's voice, and the model's best.
    static let defaultVoice = Voice(id: "af_heart", name: "Heart", gender: .female, accent: .american)

    /// The voice offered under `id`, if there's one.
    static func voice(id: String) -> Voice? {
        all.first { $0.id == id }
    }

    /// The voice that reads for the stored `readAloudVoice` setting: the
    /// one it names, or ``defaultVoice`` for a name the catalog doesn't
    /// offer.
    static func chosen(_ stored: String) -> Voice {
        voice(id: stored) ?? defaultVoice
    }

    /// The voices by accent, for a picker: American first, as the default
    /// is.
    static let groups: [Group] = Accent.allCases.map { accent in
        let voices = all.filter { $0.accent == accent }
        return Group(
            accent: accent,
            voices: voices.filter { $0.gender == .female } + voices.filter { $0.gender == .male }
        )
    }

    /// Whether the voices read a document in `language`, a code from
    /// ``DocumentLanguage/detect(in:)``: English, or nil when there was too
    /// little text to tell, which they read as English.
    static func canRead(documentLanguage language: String?) -> Bool {
        guard let language else { return true }
        return language == "en" || language.hasPrefix("en-")
    }

    /// A line for `voice` to say about itself, to hear how it sounds.
    static func sample(for voice: Voice) -> String {
        "Hello, my name is \(voice.name). This is how I sound reading to you."
    }
}
