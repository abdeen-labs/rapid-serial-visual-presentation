import Foundation

/// A question about iCloud sync waiting for an answer, kept under
/// `ReaderSettings.Keys.iCloudSyncPrompt` and asked over the library by
/// `SyncPromptView`. Sync stays off until the answer is yes.
nonisolated enum SyncPrompt: String, Identifiable {
    /// Someone who used Strobe before this version, whose library has never
    /// synced.
    case returningUser
    /// This device signed in to a different iCloud account than the one the
    /// library last synced with.
    case newAccount

    var id: String { rawValue }
}

/// When iCloud sync may start and with which account: the decisions, apart
/// from `LibrarySync` so they can be tested.
nonisolated enum SyncConsent {
    /// The sync setting a launch stores when none has ever been stored.
    enum LaunchChoice: Equatable {
        /// A fresh install: sync starts on.
        case turnOn
        /// Someone who used Strobe before this version: sync stays off until
        /// they say yes.
        case ask
    }

    /// Nil once a choice is stored; it stands from then on. A choice is
    /// stored either way, so a fresh install isn't mistaken for a returning
    /// user on its next launch, once the welcome has been seen.
    static func launchChoice(isStored: Bool, hasSeenTutorial: Bool, hasDocuments: () -> Bool) -> LaunchChoice? {
        guard !isStored else { return nil }
        if hasSeenTutorial { return .ask }
        return hasDocuments() ? .ask : .turnOn
    }

    /// Stores the launch choice if there isn't one yet. Runs before sync
    /// starts, which reads it. `hasDocuments` is only asked when nothing
    /// else decides.
    static func storeLaunchChoice(in defaults: UserDefaults = .standard, hasDocuments: () -> Bool) {
        let choice = launchChoice(
            isStored: defaults.object(forKey: ReaderSettings.Keys.iCloudSyncEnabled) != nil,
            hasSeenTutorial: defaults.bool(forKey: ReaderSettings.Keys.hasSeenTutorial),
            hasDocuments: hasDocuments
        )
        switch choice {
        case .turnOn:
            defaults.set(true, forKey: ReaderSettings.Keys.iCloudSyncEnabled)
        case .ask:
            defaults.set(false, forKey: ReaderSettings.Keys.iCloudSyncEnabled)
            defaults.set(SyncPrompt.returningUser.rawValue, forKey: ReaderSettings.Keys.iCloudSyncPrompt)
        case nil:
            break
        }
    }

    /// What sync does on learning which iCloud account is signed in, before
    /// it merges anything with that account.
    enum AccountDecision: Equatable {
        /// Sync with it: it's the ledger's own account, the library has
        /// never synced with any account, or the user agreed to this one.
        case proceed
        /// Bring back the ledger set aside when this account signed out.
        case restoreSetAside
        /// Turn sync off and ask first: the library last synced with another
        /// account.
        case ask
    }

    /// - Parameters:
    ///   - account: The signed-in account's user record name.
    ///   - ledgerAccount: The account the current ledger belongs to, if it
    ///     has learned it.
    ///   - accountAskedAbout: The account sync last turned off for and asked
    ///     about. A ledger that has one only runs again once the user turns
    ///     sync back on, which agrees to that account.
    ///   - setAsideAccount: The account whose ledger was set aside at a
    ///     sign-out: the one the library last synced with.
    static func accountDecision(
        signedIn account: String,
        ledgerAccount: String?,
        accountAskedAbout: String?,
        setAsideAccount: String?
    ) -> AccountDecision {
        if let ledgerAccount {
            return ledgerAccount == account ? .proceed : .ask
        }
        guard let setAsideAccount else { return .proceed }
        if setAsideAccount == account { return .restoreSetAside }
        return accountAskedAbout == account ? .proceed : .ask
    }
}
