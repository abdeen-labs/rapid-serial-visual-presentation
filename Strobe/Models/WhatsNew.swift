import Foundation

/// What's new in each release: shown once after an update (`WhatsNewView`)
/// and again from Settings ▸ About.
///
/// To announce a release, add one ``Release`` at the top of ``releases``,
/// with the version in `MARKETING_VERSION` and a few items. Nothing else
/// changes. Anyone who updates to that version or later sees it once; a
/// fresh install never does, since the welcome comes first. A version with
/// no entry shows nothing, and an entry for a version that hasn't shipped
/// waits for it.
nonisolated enum WhatsNew {

    /// One change: an SF Symbol, a short title, and a sentence or two.
    struct Item: Hashable, Sendable {
        let symbol: String
        let title: String
        let detail: String
        /// What a device needs to show this item; nil for every device.
        var requirement: Requirement?
    }

    /// Something only some devices have.
    enum Requirement: Hashable, Sendable {
        /// Reading aloud runs here (`KokoroVoiceModel.isSupported`).
        case readAloud
    }

    struct Release: Hashable, Sendable, Identifiable {
        /// The app version it shipped in, as in `MARKETING_VERSION`.
        let version: String
        let items: [Item]

        var id: String { version }

        /// This release with only the items a device that `meets` the given
        /// requirements shows, or nil if that leaves none.
        func shown(where meets: (Requirement) -> Bool) -> Release? {
            let shownItems = items.filter { item in
                item.requirement.map(meets) ?? true
            }
            return shownItems.isEmpty ? nil : Release(version: version, items: shownItems)
        }
    }

    /// Every release, newest first.
    static let releases: [Release] = [
        Release(version: "3.3", items: [
            Item(
                symbol: "speaker.wave.2",
                title: "Read Aloud",
                detail: "A natural voice reads along as the words show, at up to 450 wpm. It downloads once and runs on this device, with 15 English voices to choose from.",
                requirement: .readAloud
            ),
            Item(
                symbol: "captions.bubble",
                title: "Pop Words In",
                detail: "Each word springs in as it appears, like video captions. Turn it on in Settings, under Reading."
            ),
        ]),
    ]

    /// The running app's version.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    // MARK: - When it shows

    /// The releases to show after an update, newest first: each one newer
    /// than the last version seen and no newer than the running one, with
    /// the items a device that `meets` the given requirements shows.
    ///
    /// Every unseen release shows, not just the newest, since someone who
    /// skipped an update missed its changes too. A stored value that isn't a
    /// version counts as nothing seen. None show on a fresh install, or when
    /// the running version can't be read.
    static func releasesToShow(
        currentVersion: String,
        lastSeen: String?,
        isFreshInstall: Bool,
        in catalog: [Release] = releases,
        meets: (Requirement) -> Bool = { _ in true }
    ) -> [Release] {
        guard !isFreshInstall, let current = Version(currentVersion) else { return [] }
        let seen = lastSeen.flatMap(Version.init)
        return newestFirst(catalog, upTo: current)
            .filter { entry in seen.map { entry.version > $0 } ?? true }
            .compactMap { $0.release.shown(where: meets) }
    }

    /// The release Settings shows: the newest one no newer than the running
    /// version that has something for this device.
    static func currentRelease(
        for currentVersion: String,
        in catalog: [Release] = releases,
        meets: (Requirement) -> Bool = { _ in true }
    ) -> Release? {
        guard let current = Version(currentVersion) else { return nil }
        return newestFirst(catalog, upTo: current).compactMap { $0.release.shown(where: meets) }.first
    }

    /// What to store as the last version seen once What's New has shown in
    /// `currentVersion`, or on a fresh install, where the welcome stands in
    /// for it. Never moves back, as after going back to an older build.
    static func lastSeen(afterShowing currentVersion: String, over stored: String?) -> String? {
        guard let current = Version(currentVersion) else { return stored }
        if let seen = stored.flatMap(Version.init), seen >= current { return stored }
        return currentVersion
    }

    /// The releases with a readable version no newer than `current`, newest
    /// first.
    private static func newestFirst(
        _ catalog: [Release],
        upTo current: Version
    ) -> [(release: Release, version: Version)] {
        catalog
            .compactMap { release in Version(release.version).map { (release: release, version: $0) } }
            .filter { $0.version <= current }
            .sorted { $0.version > $1.version }
    }

    // MARK: - Versions

    /// A version string read as numbers, so 2.10 comes after 2.9, and 3.2
    /// is the same as 3.2.0.
    struct Version: Comparable, Sendable {
        /// Without trailing zeros.
        let components: [Int]

        /// Nil unless `string` is numbers joined by dots, such as "3.2" or
        /// "3.2.1".
        init?(_ string: String) {
            let parts = string.trimmingCharacters(in: .whitespaces)
                .split(separator: ".", omittingEmptySubsequences: false)
            var numbers: [Int] = []
            for part in parts {
                guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let number = Int(part) else { return nil }
                numbers.append(number)
            }
            while numbers.count > 1, numbers.last == 0 {
                numbers.removeLast()
            }
            components = numbers
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            lhs.components.lexicographicallyPrecedes(rhs.components)
        }
    }
}
