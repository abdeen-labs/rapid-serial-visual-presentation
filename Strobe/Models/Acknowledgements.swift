import Foundation

/// The open-source work Strobe ships or downloads, credited in Settings ▸
/// About ▸ Acknowledgements with each license's full text.
///
/// Strobe ships FluidAudio (and what it compiles in) and the fonts, and
/// downloads the voice when reading aloud is set up. Adding a package, a
/// font, or a downloaded model means adding its credit here. A project's
/// copyright lines are copied as it states them; most models and some
/// libraries state none. A project offered under several licenses is
/// credited under the one Strobe takes, Apache 2.0 where it's offered.
nonisolated enum Acknowledgements {

    struct Credit: Identifiable, Hashable, Sendable {
        let name: String
        /// Who made it.
        let author: String
        let license: License
        let url: URL
        /// Its copyright lines, word for word; empty when it states none.
        var notices: [String] = []
        /// Its Apache NOTICE file, word for word, which the license asks
        /// to pass on.
        var noticeFile: String?
        /// What it is to Strobe, or where it came from.
        var note: String?

        var id: String { name }
    }

    enum License: String, Hashable, Sendable {
        case apache2
        case mit
        case bsd2
        case ofl
        case paraType

        var name: String {
            switch self {
            case .apache2: "Apache License 2.0"
            case .mit: "MIT License"
            case .bsd2: "BSD 2-Clause License"
            case .ofl: "SIL Open Font License 1.1"
            case .paraType: "ParaType Free Font License"
            }
        }
    }

    /// Credits under a heading, with a line on what they do for Strobe.
    struct Group: Identifiable, Sendable {
        let title: String
        let summary: String
        let credits: [Credit]

        var id: String { title }
    }

    static let groups: [Group] = [voice, fluidAudio, textNormalization, fonts]

    // MARK: - Reading aloud

    static let voice = Group(
        title: "Voice",
        summary: "Downloaded when you set up reading aloud. The voice runs on this device.",
        credits: [
            Credit(
                name: "Kokoro",
                author: "hexgrad",
                license: .apache2,
                url: URL(string: "https://huggingface.co/hexgrad/Kokoro-82M")!,
                note: "Kokoro's training data includes recordings from Koniwa (CC BY 3.0, https://github.com/koniwa/koniwa) and SIWIS (CC BY 4.0, https://datashare.ed.ac.uk/handle/10283/2353)."
            ),
            Credit(
                name: "Kokoro Core ML",
                author: "laishere",
                license: .apache2,
                url: URL(string: "https://github.com/laishere/kokoro-coreml")!,
                notices: ["Copyright 2026 laishere"],
                note: "The seven-stage Core ML conversion of Kokoro, used by FluidAudio with the author's permission."
            ),
            Credit(
                name: "Kokoro 82M Core ML",
                author: "FluidInference",
                license: .apache2,
                url: URL(string: "https://huggingface.co/FluidInference/kokoro-82m-coreml")!,
                note: "The model, voice, and pronunciation files Strobe downloads."
            ),
            Credit(
                name: "Misaki",
                author: "hexgrad",
                license: .apache2,
                url: URL(string: "https://github.com/hexgrad/misaki")!,
                note: "The English pronunciation lexicon, and pronunciation rules FluidAudio ports to Swift."
            ),
        ]
    )

    // MARK: - FluidAudio

    static let fluidAudio = Group(
        title: "FluidAudio",
        summary: "Runs the voice model on this device. It includes the projects below it.",
        credits: [
            Credit(
                name: "FluidAudio",
                author: "FluidInference",
                license: .apache2,
                url: URL(string: "https://github.com/FluidInference/FluidAudio")!
            ),
            Credit(
                name: "fastcluster",
                author: "Daniel Müllner and Google",
                license: .bsd2,
                url: URL(string: "https://danifold.net/fastcluster.html")!,
                notices: [
                    "Copyright:",
                    "Until package version 1.1.23: © 2011 Daniel Müllner <https://danifold.net>",
                    "All changes from version 1.1.24 on: © Google Inc. <https://www.google.com>",
                    "All rights reserved.",
                ]
            ),
            Credit(
                name: "VBx",
                author: "BUT Speech@FIT",
                license: .apache2,
                url: URL(string: "https://github.com/BUTSpeechFIT/VBx")!,
                notices: ["Copyright 2021-2024 BUT Speech@FIT (original VBx project)"]
            ),
            Credit(
                name: "cutlet",
                author: "Paul O'Leary McCann",
                license: .mit,
                url: URL(string: "https://github.com/polm/cutlet")!,
                notices: ["Copyright (c) 2020 Paul O'Leary McCann"],
                note: "FluidAudio's Japanese pronunciation is a Swift port of Misaki's adaptation of cutlet."
            ),
            Credit(
                name: "Convert Numbers to Japanese",
                author: "David Wilson",
                license: .mit,
                url: URL(string: "https://github.com/Greatdane/Convert-Numbers-to-Japanese")!,
                notices: ["Copyright (c) 2018 David Wilson, https://github.com/Greatdane"]
            ),
        ]
    )

    // MARK: - Text normalization

    static let textNormalization = Group(
        title: "Text Normalization",
        summary: "Reads numbers, dates, and abbreviations as they're spoken. Compiled into FluidAudio, with the Rust libraries below it.",
        credits: [
            Credit(
                name: "text-processing-rs",
                author: "FluidInference",
                license: .apache2,
                url: URL(string: "https://github.com/FluidInference/text-processing-rs")!,
                notices: ["Copyright 2026 FluidInference"],
                noticeFile: """
                    text-processing-rs
                    Copyright 2026 FluidInference

                    This product is a Rust port of NVIDIA NeMo Text Processing (https://github.com/NVIDIA/NeMo-text-processing), which is licensed under the Apache License, Version 2.0.

                    Copyright (c) NVIDIA CORPORATION & AFFILIATES.
                    Licensed under the Apache License, Version 2.0.

                    In addition, when built with the optional `fst-engine` feature, this product includes and redistributes artifacts derived from NVIDIA NeMo Text Processing (Apache-2.0, pinned commit 1f1263579fe57ba7ed783cad3dddee710fcc5064):

                    * the compiled weighted-FST grammars under `grammars/` (exported from NeMo's Pynini source), and
                    * the text-normalization test fixtures under `tests/fixtures/` (copied from, or regenerated as the deterministic output of, NeMo's `data_text_normalization` test cases).

                    This product's binary distributions (e.g. the published xcframework) also statically link third-party libraries. See THIRD-PARTY-LICENSES.md for the full list and their licenses.
                    """
            ),
            Credit(
                name: "NeMo Text Processing",
                author: "NVIDIA",
                license: .apache2,
                url: URL(string: "https://github.com/NVIDIA/NeMo-text-processing")!,
                notices: ["Copyright (c) NVIDIA CORPORATION & AFFILIATES."]
            ),
            // Each crate at the version text-processing-rs v0.3.1 locks, with
            // the authors its manifest names and the copyright lines its
            // license files carry.
            rust("rustfst", by: "Alexandre Caulier", at: "https://github.com/Garvys/rustfst"),
            rust("flate2", by: "Alex Crichton and Josh Triplett", at: "https://github.com/rust-lang/flate2-rs",
                 notices: ["Copyright (c) 2014-2026 Alex Crichton"]),
            rust("adler2", by: "Jonas Schievink and oyvindln", at: "https://github.com/oyvindln/adler2",
                 notices: ["Copyright (C) Jonas Schievink <jonasschievink@gmail.com>"]),
            rust("anyhow", by: "David Tolnay", at: "https://github.com/dtolnay/anyhow"),
            rust("bimap", by: "Billy Rieger", at: "https://github.com/billyrieger/bimap-rs"),
            rust("bitflags", by: "The Rust Project Developers", at: "https://github.com/bitflags/bitflags",
                 notices: ["Copyright (c) 2014 The Rust Project Developers"]),
            rust("cfg-if", by: "Alex Crichton", at: "https://github.com/rust-lang/cfg-if",
                 notices: ["Copyright (c) 2014 Alex Crichton"]),
            rust("crc32fast", by: "Sam Rijs and Alex Crichton", at: "https://github.com/srijs/rust-crc32fast",
                 notices: ["Copyright (c) 2018 Sam Rijs, Alex Crichton and contributors"]),
            rust("either", by: "rayon-rs", at: "https://github.com/rayon-rs/either",
                 notices: ["Copyright (c) 2015"]),
            rust("generic-array", by: "Bartłomiej Kamiński and Aaron Trent", at: "https://github.com/fizyk20/generic-array",
                 license: .mit, notices: ["Copyright (c) 2015 Bartłomiej Kamiński"]),
            rust("getrandom", by: "The Rand Project Developers", at: "https://github.com/rust-random/getrandom",
                 notices: ["Copyright (c) 2018-2025 The rust-random Project Developers", "Copyright (c) 2014 The Rust Project Developers"]),
            rust("itertools", by: "bluss", at: "https://github.com/rust-itertools/itertools",
                 notices: ["Copyright (c) 2015"]),
            rust("lazy_static", by: "Marvin Löbel", at: "https://github.com/rust-lang-nursery/lazy-static.rs",
                 notices: ["Copyright (c) 2010 The Rust Project Developers"]),
            rust("libc", by: "The Rust Project Developers", at: "https://github.com/rust-lang/libc",
                 notices: ["Copyright (c) The Rust Project Developers"]),
            rust("memchr", by: "Andrew Gallant and bluss", at: "https://github.com/BurntSushi/memchr",
                 license: .mit, notices: ["Copyright (c) 2015 Andrew Gallant"]),
            rust("minimal-lexical", by: "Alex Huszagh", at: "https://github.com/Alexhuszagh/minimal-lexical"),
            rust("miniz_oxide", by: "Frommi, oyvindln, and Rich Geldreich", at: "https://github.com/Frommi/miniz_oxide",
                 notices: [
                     "Copyright 2013-2014 RAD Game Tools and Valve Software",
                     "Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC",
                     "Copyright (c) 2017 Frommi",
                     "Copyright (c) 2017-2024 oyvindln",
                 ]),
            rust("nom", by: "Geoffroy Couprie", at: "https://github.com/rust-bakery/nom",
                 license: .mit, notices: ["Copyright (c) 2014-2019 Geoffroy Couprie"]),
            rust("num-traits", by: "The Rust Project Developers", at: "https://github.com/rust-num/num-traits",
                 notices: ["Copyright (c) 2014 The Rust Project Developers"]),
            rust("ordered-float", by: "Jonathan Reem and Matt Brubeck", at: "https://github.com/reem/rust-ordered-float",
                 license: .mit, notices: ["Copyright (c) 2015 Jonathan Reem"]),
            rust("ppv-lite86", by: "The CryptoCorrosion Contributors", at: "https://github.com/cryptocorrosion/cryptocorrosion",
                 notices: ["Copyright (c) 2019 The CryptoCorrosion Contributors"]),
            rust("rand", by: "The Rand Project Developers", at: "https://github.com/rust-random/rand",
                 notices: Self.randNotices),
            rust("rand_chacha", by: "The Rand Project Developers", at: "https://github.com/rust-random/rand",
                 notices: Self.randNotices),
            rust("rand_core", by: "The Rand Project Developers", at: "https://github.com/rust-random/rand",
                 notices: Self.randNotices),
            rust("serde", by: "Erick Tryzelaar and David Tolnay", at: "https://github.com/serde-rs/serde"),
            rust("serde_core", by: "Erick Tryzelaar and David Tolnay", at: "https://github.com/serde-rs/serde"),
            rust("simd-adler32", by: "Marvin Countryman", at: "https://github.com/mcountryman/simd-adler32",
                 license: .mit, notices: ["Copyright (c) [2021] [Marvin Countryman]"]),
            rust("superslice", by: "Alkis Evlogimenos", at: "https://github.com/alkis/superslice-rs"),
            rust("typenum", by: "Paho Lurie-Gregg", at: "https://github.com/paholg/typenum",
                 notices: ["Copyright (c) 2014 Paho Lurie-Gregg"]),
            rust("zerocopy", by: "Joshua Liebow-Feeser and Jack Wrenn", at: "https://github.com/google/zerocopy",
                 notices: ["Copyright 2023 The Fuchsia Authors"]),
        ]
    )

    /// The Rand crates' copyright lines.
    private static let randNotices = [
        "Copyright 2018 Developers of the Rand project",
        "Copyright (c) 2014 The Rust Project Developers",
    ]

    /// A Rust library, credited under Apache 2.0 unless it's offered only
    /// under another license.
    private static func rust(
        _ name: String,
        by author: String,
        at url: String,
        license: License = .apache2,
        notices: [String] = []
    ) -> Credit {
        Credit(name: name, author: author, license: license, url: URL(string: url)!, notices: notices)
    }

    // MARK: - Fonts

    static let fonts = Group(
        title: "Fonts",
        summary: "Bundled with Strobe for reading, titles, and covers.",
        credits: [
            Credit(
                name: "Fraunces",
                author: "Undercase Type",
                license: .ofl,
                url: URL(string: "https://github.com/undercasetype/Fraunces")!,
                notices: ["Copyright 2020 The Fraunces Project Authors (github.com/undercasetype/Fraunces)"]
            ),
            Credit(
                name: "Inter",
                author: "Rasmus Andersson",
                license: .ofl,
                url: URL(string: "https://github.com/rsms/inter")!,
                notices: ["Copyright 2020 The Inter Project Authors (https://github.com/rsms/inter)"]
            ),
            Credit(
                name: "JetBrains Mono",
                author: "JetBrains",
                license: .ofl,
                url: URL(string: "https://github.com/JetBrains/JetBrainsMono")!,
                notices: ["Copyright 2020 The JetBrains Mono Project Authors (https://github.com/JetBrains/JetBrainsMono)"]
            ),
            Credit(
                name: "PT Mono",
                author: "ParaType",
                license: .paraType,
                url: URL(string: "https://www.paratype.com/fonts/pt/pt-mono")!,
                notices: ["Copyright © 2010 ParaType Inc., ParaType Ltd. All rights reserved."]
            ),
            Credit(
                name: "PT Sans",
                author: "ParaType",
                license: .paraType,
                url: URL(string: "https://www.paratype.com/fonts/pt/pt-sans")!,
                notices: ["Copyright © 2009 ParaType Ltd. All rights reserved."]
            ),
            Credit(
                name: "PT Serif",
                author: "ParaType",
                license: .paraType,
                url: URL(string: "https://www.paratype.com/fonts/pt/pt-serif")!,
                notices: ["Copyright © 2010 ParaType Ltd. All rights reserved."]
            ),
            Credit(
                name: "Space Grotesk",
                author: "Florian Karsten",
                license: .ofl,
                url: URL(string: "https://github.com/floriankarsten/space-grotesk")!,
                notices: ["Copyright 2020 The Space Grotesk Project Authors (https://github.com/floriankarsten/space-grotesk)"]
            ),
        ]
    )
}
