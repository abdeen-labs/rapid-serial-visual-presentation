import Foundation
import Testing
@testable import Strobe

struct AcknowledgementsTests {

    private static let credits = Acknowledgements.groups.flatMap(\.credits)

    /// Rows and their pages are identified by name.
    @Test func namesAreUnique() {
        let names = Self.credits.map(\.name)
        #expect(Set(names).count == names.count)
    }

    /// MIT and BSD licenses ask for the copyright notice along with the
    /// license text.
    @Test func mitAndBSDCreditsCarryTheirCopyrightLines() {
        for credit in Self.credits where credit.license == .mit || credit.license == .bsd2 {
            #expect(!credit.notices.isEmpty, "\(credit.name)")
        }
    }

    @Test func everyCreditLinksOverHTTPS() {
        for credit in Self.credits {
            #expect(credit.url.scheme == "https", "\(credit.name)")
            #expect(!credit.author.isEmpty, "\(credit.name)")
        }
    }

    @Test func groupsAreNotEmpty() {
        for group in Acknowledgements.groups {
            #expect(!group.credits.isEmpty, "\(group.title)")
        }
    }

    // MARK: - License texts

    /// Each text is the whole license, from its title or first clause to
    /// its last.
    @Test func licenseTextsAreWhole() {
        let ends: [(Acknowledgements.License, first: String, last: String)] = [
            (.apache2, "Apache License\nVersion 2.0, January 2004", "END OF TERMS AND CONDITIONS"),
            (.mit, "Permission is hereby granted, free of charge", "OTHER DEALINGS IN THE SOFTWARE."),
            (.bsd2, "Redistribution and use in source and binary forms", "EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE."),
            (.ofl, "SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007", "OTHER DEALINGS IN THE FONT SOFTWARE."),
            (.paraType, "ParaType Free Font Licensing Agreement", "DEALINGS IN THE FONT SOFTWARE."),
        ]
        for (license, first, last) in ends {
            #expect(license.text.hasPrefix(first), "\(license)")
            #expect(license.text.hasSuffix(last), "\(license)")
        }
    }

    /// Paragraphs are single lines, so the text wraps to the screen rather
    /// than at the upstream file's 70-odd columns.
    @Test func licenseParagraphsAreNotHardWrapped() {
        for license in [Acknowledgements.License.apache2, .mit, .bsd2, .ofl, .paraType] {
            let longest = license.text.split(separator: "\n").map(\.count).max() ?? 0
            #expect(longest > 200, "\(license)")
            #expect(!license.text.contains("\n\n\n"), "\(license)")
        }
    }

    // MARK: - What the app ships

    /// Every font in the app has a credit, named as its file is (without
    /// spaces): `JetBrainsMono-Bold.ttf` is JetBrains Mono.
    @Test func everyBundledFontIsCredited() throws {
        let fonts = ["ttf", "ttc", "otf"].flatMap { Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
        try #require(!fonts.isEmpty)
        let credited = Set(Acknowledgements.fonts.credits.map { $0.name.replacingOccurrences(of: " ", with: "") })
        for font in fonts {
            let family = font.deletingPathExtension().lastPathComponent
                .split(separator: "-").first.map(String.init) ?? ""
            #expect(credited.contains(family), "\(font.lastPathComponent)")
        }
    }

    /// The build strips FluidAudio's LuxTTS lexicon, which is derived from
    /// espeak-ng and which Strobe never reads, from the package's resource
    /// bundle.
    @Test func fluidAudioResourcesLeaveOutTheLuxTTSLexicon() throws {
        let bundleURL = try #require(Bundle.main.url(forResource: "FluidAudio_FluidAudio", withExtension: "bundle"))
        let files = try #require(FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: nil))
            .compactMap { ($0 as? URL)?.lastPathComponent }
        #expect(!files.isEmpty)
        #expect(!files.contains { $0.hasPrefix("luxtts_") }, "\(files)")
    }
}
