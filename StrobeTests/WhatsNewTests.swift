import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import Strobe

struct WhatsNewTests {

    private typealias Version = WhatsNew.Version

    // MARK: - Versions

    @Test func versionsCompareAsNumbers() throws {
        let pairs = [("2.10", "2.9"), ("3.0", "2.13"), ("3.2.1", "3.2"), ("3.0.1", "3"), ("10", "9.9.9")]
        for (newer, older) in pairs {
            let newerVersion = try #require(Version(newer))
            let olderVersion = try #require(Version(older))
            #expect(newerVersion > olderVersion, "\(newer) > \(older)")
        }
    }

    @Test func trailingZerosDoNotCount() {
        #expect(Version("3.2") == Version("3.2.0"))
        #expect(Version("3") == Version("3.0.0"))
        #expect(Version("0.0") == Version("0"))
    }

    @Test func onlyNumbersJoinedByDotsAreVersions() {
        for garbage in ["", " ", "abc", "3.", ".3", "3..2", "v3.2", "3.2-beta", "3.2b", "-3", "+3", "3,2", "٣.٢"] {
            #expect(Version(garbage) == nil, "\(garbage)")
        }
        #expect(Version(" 3.2 ") == Version("3.2"))
    }

    // MARK: - When it shows

    private static func release(_ version: String, items: [WhatsNew.Item]? = nil) -> WhatsNew.Release {
        WhatsNew.Release(
            version: version,
            items: items ?? [WhatsNew.Item(symbol: "star", title: "In \(version)", detail: "Something new.")]
        )
    }

    /// Newest first, as the real catalog is, with a two-digit minor version.
    private static let catalog = [
        release("3.0"),
        release("2.10"),
        release("2.9"),
        release("2.8"),
    ]

    private static func versionsShown(
        running current: String,
        lastSeen: String?,
        isFreshInstall: Bool = false,
        in catalog: [WhatsNew.Release] = catalog,
        meets: (WhatsNew.Requirement) -> Bool = { _ in true }
    ) -> [String] {
        WhatsNew.releasesToShow(
            currentVersion: current,
            lastSeen: lastSeen,
            isFreshInstall: isFreshInstall,
            in: catalog,
            meets: meets
        ).map(\.version)
    }

    @Test func showsTheNewReleaseAfterAnUpdate() {
        #expect(Self.versionsShown(running: "3.0", lastSeen: "2.10") == ["3.0"])
    }

    @Test func showsNothingOnceSeen() {
        #expect(Self.versionsShown(running: "3.0", lastSeen: "3.0").isEmpty)
        #expect(Self.versionsShown(running: "3.0", lastSeen: "3.0.0").isEmpty)
    }

    @Test func tenComesAfterNine() {
        #expect(Self.versionsShown(running: "2.10", lastSeen: "2.9") == ["2.10"])
        #expect(Self.versionsShown(running: "2.10", lastSeen: "2.10").isEmpty)
    }

    @Test func neverOnAFreshInstall() {
        #expect(Self.versionsShown(running: "3.0", lastSeen: nil, isFreshInstall: true).isEmpty)
        // Even with a value left behind by an earlier install.
        #expect(Self.versionsShown(running: "3.0", lastSeen: "2.8", isFreshInstall: true).isEmpty)
    }

    @Test func aFreshInstallMarkedSeenShowsNothingAfterTheWelcome() {
        let marked = WhatsNew.lastSeen(afterShowing: "3.0", over: nil)
        #expect(marked == "3.0")
        // The welcome closes: no longer a fresh install.
        #expect(Self.versionsShown(running: "3.0", lastSeen: marked).isEmpty)
        // The next update with an entry shows it.
        let next = [Self.release("3.1")] + Self.catalog
        #expect(Self.versionsShown(running: "3.1", lastSeen: marked, in: next) == ["3.1"])
    }

    @Test func skippedReleasesAllShowNewestFirst() {
        #expect(Self.versionsShown(running: "3.0", lastSeen: "2.8") == ["3.0", "2.10", "2.9"])
    }

    @Test func catalogOrderDoesNotMatter() {
        let shuffled = [Self.release("2.9"), Self.release("3.0"), Self.release("2.10")]
        #expect(Self.versionsShown(running: "3.0", lastSeen: "2.8", in: shuffled) == ["3.0", "2.10", "2.9"])
    }

    @Test func someoneFromBeforeWhatsNewSeesEveryReleaseUpToTheirs() {
        // Updated from a version that never stored a value.
        #expect(Self.versionsShown(running: "2.10", lastSeen: nil) == ["2.10", "2.9", "2.8"])
    }

    @Test func aStoredValueThatIsNotAVersionCountsAsNothingSeen() {
        for garbage in ["", "banana", "3.0-beta", "v2.9"] {
            #expect(Self.versionsShown(running: "2.10", lastSeen: garbage) == ["2.10", "2.9", "2.8"], "\(garbage)")
        }
    }

    @Test func aStoredVersionWithoutAnEntryComparesByNumber() {
        #expect(Self.versionsShown(running: "3.0", lastSeen: "2.9.5") == ["3.0", "2.10"])
        #expect(Self.versionsShown(running: "3.0", lastSeen: "2.11") == ["3.0"])
    }

    @Test func aRunningVersionWithoutAnEntryShowsNothingNew() {
        #expect(Self.versionsShown(running: "3.0.1", lastSeen: "3.0").isEmpty)
        #expect(Self.versionsShown(running: "3.1", lastSeen: "3.0").isEmpty)
    }

    @Test func aRunningVersionWithoutAnEntryStillShowsWhatWasMissed() {
        #expect(Self.versionsShown(running: "3.0.1", lastSeen: "2.10") == ["3.0"])
    }

    @Test func anEntryWaitsForItsVersion() {
        // Written before MARKETING_VERSION was raised.
        let next = [Self.release("3.1")] + Self.catalog
        #expect(Self.versionsShown(running: "3.0", lastSeen: "2.10", in: next) == ["3.0"])
    }

    @Test func nothingShowsAfterGoingBackToAnOlderBuild() {
        #expect(Self.versionsShown(running: "2.10", lastSeen: "3.0").isEmpty)
    }

    @Test func anUnreadableRunningVersionShowsNothing() {
        #expect(Self.versionsShown(running: "", lastSeen: "2.8").isEmpty)
        #expect(Self.versionsShown(running: "x.x", lastSeen: nil).isEmpty)
    }

    @Test func anEntryWithAnUnreadableVersionNeverShows() {
        let broken = [Self.release("3.0 beta")] + Self.catalog
        #expect(Self.versionsShown(running: "3.0", lastSeen: "2.10", in: broken) == ["3.0"])
    }

    // MARK: - Devices

    private static let readAloud = WhatsNew.Item(symbol: "speaker.wave.2", title: "Read Aloud", detail: "A voice.", requirement: .readAloud)
    private static let everywhere = WhatsNew.Item(symbol: "star", title: "Everywhere", detail: "For all.")

    @Test func itemsADeviceCannotUseAreLeftOut() {
        let catalog = [Self.release("3.0", items: [Self.readAloud, Self.everywhere])]
        let withoutReadAloud = WhatsNew.releasesToShow(
            currentVersion: "3.0", lastSeen: "2.0", isFreshInstall: false, in: catalog, meets: { _ in false }
        )
        #expect(withoutReadAloud.map(\.items) == [[Self.everywhere]])
        let withReadAloud = WhatsNew.releasesToShow(
            currentVersion: "3.0", lastSeen: "2.0", isFreshInstall: false, in: catalog, meets: { $0 == .readAloud }
        )
        #expect(withReadAloud.map(\.items) == [[Self.readAloud, Self.everywhere]])
    }

    @Test func aReleaseWithNothingForTheDeviceIsSkipped() {
        let catalog = [Self.release("3.1", items: [Self.readAloud]), Self.release("3.0")]
        #expect(Self.versionsShown(running: "3.1", lastSeen: "2.0", in: catalog, meets: { _ in false }) == ["3.0"])
        #expect(WhatsNew.currentRelease(for: "3.1", in: catalog, meets: { _ in false })?.version == "3.0")
    }

    // MARK: - Seen

    @Test func showingMarksTheRunningVersionSeen() {
        #expect(WhatsNew.lastSeen(afterShowing: "3.0", over: "2.9") == "3.0")
        #expect(WhatsNew.lastSeen(afterShowing: "3.0.1", over: "3.0") == "3.0.1")
    }

    @Test func theVersionSeenNeverMovesBack() {
        #expect(WhatsNew.lastSeen(afterShowing: "2.10", over: "3.0") == "3.0")
        #expect(WhatsNew.lastSeen(afterShowing: "3.0", over: "3.0.0") == "3.0.0")
    }

    @Test func aValueThatIsNotAVersionIsReplaced() {
        #expect(WhatsNew.lastSeen(afterShowing: "3.0", over: "banana") == "3.0")
    }

    @Test func anUnreadableRunningVersionKeepsTheStoredOne() {
        #expect(WhatsNew.lastSeen(afterShowing: "", over: "2.9") == "2.9")
        #expect(WhatsNew.lastSeen(afterShowing: "", over: nil) == nil)
    }

    // MARK: - Settings

    @Test func settingsShowsTheNewestReleaseUpToTheRunningVersion() {
        #expect(WhatsNew.currentRelease(for: "3.0", in: Self.catalog)?.version == "3.0")
        #expect(WhatsNew.currentRelease(for: "3.0.2", in: Self.catalog)?.version == "3.0")
        #expect(WhatsNew.currentRelease(for: "2.9.1", in: Self.catalog)?.version == "2.9")
        #expect(WhatsNew.currentRelease(for: "2.7", in: Self.catalog) == nil)
        #expect(WhatsNew.currentRelease(for: "", in: Self.catalog) == nil)
    }

    // MARK: - The catalog

    @Test func catalogIsNewestFirstWithReadableDistinctVersions() throws {
        let versions = try WhatsNew.releases.map { try #require(Version($0.version), "\($0.version)") }
        #expect(!versions.isEmpty)
        #expect(versions == versions.sorted(by: >))
        #expect(Set(versions.map(\.components)).count == versions.count)
    }

    @Test func everyReleaseHasCompleteItems() {
        for release in WhatsNew.releases {
            #expect(!release.items.isEmpty, "\(release.version)")
            #expect(Set(release.items.map(\.title)).count == release.items.count, "\(release.version)")
            for item in release.items {
                #expect(!item.symbol.isEmpty, "\(item.title)")
                #expect(!item.title.isEmpty, "\(release.version)")
                #expect(item.detail.hasSuffix("."), "\(item.title)")
            }
        }
    }

    @Test func everySymbolExists() {
        for item in WhatsNew.releases.flatMap(\.items) {
            #if canImport(UIKit)
            #expect(UIImage(systemName: item.symbol) != nil, "\(item.symbol)")
            #else
            #expect(NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) != nil, "\(item.symbol)")
            #endif
        }
    }

    @Test func readingAloudOnlyShowsWhereItRuns() throws {
        let readAloud = try #require(WhatsNew.releases.flatMap(\.items).first { $0.title == "Read Aloud" })
        #expect(readAloud.requirement == .readAloud)
    }
}
