import CloudKit
import Foundation
import Testing
@testable import Strobe

struct SyncConsentTests {

    // MARK: - Launch choice

    @Test func storedChoiceStands() {
        var asked = false
        let choice = SyncConsent.launchChoice(isStored: true, hasSeenTutorial: true) {
            asked = true
            return true
        }
        #expect(choice == nil)
        #expect(!asked)
    }

    @Test func freshInstallTurnsSyncOn() {
        let choice = SyncConsent.launchChoice(isStored: false, hasSeenTutorial: false) { false }
        #expect(choice == .turnOn)
    }

    @Test func someoneWhoSawTheWelcomeIsAsked() {
        var asked = false
        let choice = SyncConsent.launchChoice(isStored: false, hasSeenTutorial: true) {
            asked = true
            return false
        }
        #expect(choice == .ask)
        // Decided without counting the library.
        #expect(!asked)
    }

    @Test func aLibraryWithoutTheWelcomeIsAsked() {
        // From before the welcome existed, or the welcome never finished.
        let choice = SyncConsent.launchChoice(isStored: false, hasSeenTutorial: false) { true }
        #expect(choice == .ask)
    }

    @Test func freshInstallStoresSyncOnAndKeepsItAfterTheWelcome() throws {
        let suite = "SyncConsentTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        SyncConsent.storeLaunchChoice(in: defaults) { false }
        #expect(defaults.object(forKey: ReaderSettings.Keys.iCloudSyncEnabled) as? Bool == true)
        #expect(defaults.string(forKey: ReaderSettings.Keys.iCloudSyncPrompt) == nil)

        // The next launch, with the welcome seen and books added, isn't
        // mistaken for a returning user.
        defaults.set(true, forKey: ReaderSettings.Keys.hasSeenTutorial)
        SyncConsent.storeLaunchChoice(in: defaults) { true }
        #expect(defaults.object(forKey: ReaderSettings.Keys.iCloudSyncEnabled) as? Bool == true)
        #expect(defaults.string(forKey: ReaderSettings.Keys.iCloudSyncPrompt) == nil)
    }

    @Test func returningUserStoresSyncOffAndAQuestion() throws {
        let suite = "SyncConsentTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ReaderSettings.Keys.hasSeenTutorial)

        SyncConsent.storeLaunchChoice(in: defaults) { true }
        #expect(defaults.object(forKey: ReaderSettings.Keys.iCloudSyncEnabled) as? Bool == false)
        #expect(defaults.string(forKey: ReaderSettings.Keys.iCloudSyncPrompt) == SyncPrompt.returningUser.rawValue)

        // Answered Not Now: the next launch doesn't ask again.
        defaults.removeObject(forKey: ReaderSettings.Keys.iCloudSyncPrompt)
        SyncConsent.storeLaunchChoice(in: defaults) { true }
        #expect(defaults.object(forKey: ReaderSettings.Keys.iCloudSyncEnabled) as? Bool == false)
        #expect(defaults.string(forKey: ReaderSettings.Keys.iCloudSyncPrompt) == nil)
    }

    @Test func syncIsOffUntilAChoiceIsStored() {
        #expect(!ReaderSettings.Defaults.iCloudSyncEnabled)
    }

    // MARK: - Accounts

    private func decision(
        signedIn account: String,
        ledger: String? = nil,
        askedAbout: String? = nil,
        setAside: String? = nil
    ) -> SyncConsent.AccountDecision {
        SyncConsent.accountDecision(
            signedIn: account,
            ledgerAccount: ledger,
            accountAskedAbout: askedAbout,
            setAsideAccount: setAside
        )
    }

    @Test func theLedgersOwnAccountGoesOn() {
        #expect(decision(signedIn: "A", ledger: "A") == .proceed)
    }

    @Test func anotherAccountThanTheLedgersIsAskedAbout() {
        #expect(decision(signedIn: "B", ledger: "A") == .ask)
    }

    @Test func firstSyncGoesOnWithAnyAccount() {
        #expect(decision(signedIn: "A") == .proceed)
    }

    @Test func signingBackInRestoresTheSetAsideLedger() {
        #expect(decision(signedIn: "A", setAside: "A") == .restoreSetAside)
    }

    @Test func anotherAccountAfterASignOutIsAskedAbout() {
        #expect(decision(signedIn: "B", setAside: "A") == .ask)
    }

    @Test func anAccountAgreedToGoesOn() {
        #expect(decision(signedIn: "B", askedAbout: "B", setAside: "A") == .proceed)
    }

    @Test func agreeingToOneAccountDoesNotCoverAnother() {
        // Switched again after the question was asked.
        #expect(decision(signedIn: "C", askedAbout: "B", setAside: "A") == .ask)
    }

    @Test func theOriginalAccountStillRestoresAfterTheQuestion() {
        #expect(decision(signedIn: "A", askedAbout: "B", setAside: "A") == .restoreSetAside)
    }

    // MARK: - Ledgers

    @Test func startingOverKeepsTheStoreAndAccount() {
        var ledger = CloudSyncLedger()
        ledger.storeIdentifier = "store"
        ledger.userRecordName = "A"
        ledger.accountAskedAbout = "B"
        ledger.hasFetchedEverything = true
        ledger.entries[UUID().uuidString] = CloudSyncLedger.Entry()
        ledger.pendingDeletes = [UUID().uuidString]

        let fresh = ledger.startingOver()
        #expect(fresh.storeIdentifier == "store")
        #expect(fresh.userRecordName == "A")
        #expect(fresh.accountAskedAbout == "B")
        #expect(!fresh.hasFetchedEverything)
        #expect(fresh.entries.isEmpty)
        #expect(fresh.pendingDeletes.isEmpty)
        #expect(fresh.engineState == nil)
    }

    @Test func ledgerWithoutAnAccountStillDecodes() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SyncConsentTests-\(UUID().uuidString)/Ledger.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Nil fields aren't written, so this is the file an earlier build
        // wrote.
        var ledger = CloudSyncLedger()
        ledger.storeIdentifier = "store"
        ledger.pendingDeletes = [UUID().uuidString]
        try ledger.save(to: url)

        let loaded = CloudSyncLedger.load(from: url)
        #expect(loaded.storeIdentifier == "store")
        #expect(loaded.pendingDeletes == ledger.pendingDeletes)
        #expect(loaded.userRecordName == nil)
        #expect(loaded.accountAskedAbout == nil)
    }

    @Test func setAsideLedgerRoundTripsThroughItsFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SyncConsentTests-\(UUID().uuidString)/SetAside.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = CloudSyncLedger()
        ledger.storeIdentifier = "store"
        ledger.userRecordName = "A"
        ledger.hasFetchedEverything = true
        ledger.entries[UUID().uuidString] = CloudSyncLedger.Entry()
        // A deletion iCloud hadn't confirmed when the account signed out.
        ledger.pendingDeletes = [UUID().uuidString]
        try ledger.save(to: url)

        let loaded = try #require(CloudSyncLedger.loadSetAside(from: url))
        #expect(loaded.userRecordName == "A")
        #expect(loaded.storeIdentifier == "store")
        #expect(loaded.hasFetchedEverything)
        #expect(loaded.entries == ledger.entries)
        #expect(loaded.pendingDeletes == ledger.pendingDeletes)

        CloudSyncLedger.removeSetAside(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(CloudSyncLedger.loadSetAside(from: url) == nil)
    }

    @Test func setAsideLedgerWithoutAnAccountIsIgnored() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SyncConsentTests-\(UUID().uuidString)/SetAside.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = CloudSyncLedger()
        ledger.pendingDeletes = [UUID().uuidString]
        try ledger.save(to: url)

        #expect(CloudSyncLedger.loadSetAside(from: url) == nil)
    }

    @Test func unreadableSetAsideLedgerIsIgnoredAndKeptForDiagnosis() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SyncConsentTests-\(UUID().uuidString)/SetAside.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a ledger".utf8).write(to: url)

        #expect(CloudSyncLedger.loadSetAside(from: url) == nil)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable").path(percentEncoded: false)))
    }

    @Test func setAsideLedgerSitsBesideTheLedger() {
        #expect(CloudSyncLedger.setAsideFileURL.deletingLastPathComponent() == CloudSyncLedger.fileURL.deletingLastPathComponent())
        #expect(CloudSyncLedger.setAsideFileURL != CloudSyncLedger.fileURL)
    }
}
