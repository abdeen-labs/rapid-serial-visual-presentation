import SwiftUI

/// iCloud sync on or off, and what it's doing.
struct SyncSettingsSection: View {
    @AppStorage(ReaderSettings.Keys.iCloudSyncEnabled) private var iCloudSyncEnabled = ReaderSettings.Defaults.iCloudSyncEnabled
    @AppStorage(ReaderSettings.Keys.iCloudSyncPrompt) private var pendingSyncPrompt: SyncPrompt?
    private let sync = LibrarySync.shared
    #if DEBUG
    @State private var isCreatingSchema = false
    @State private var schemaResult: String?
    #endif

    /// Turning sync on or off here also answers a sync question waiting in
    /// the library. Only the user's own changes go through this; sync
    /// turning itself off doesn't clear the question it just asked.
    private var syncEnabled: Binding<Bool> {
        Binding(
            get: { iCloudSyncEnabled },
            set: {
                pendingSyncPrompt = nil
                iCloudSyncEnabled = $0
            }
        )
    }

    var body: some View {
        Section {
            Toggle(isOn: syncEnabled) {
                Text("iCloud Sync")
                Text("Your library and reading positions on all your devices")
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text(footer)
        }
        .onChange(of: iCloudSyncEnabled) {
            sync.updateEnabled()
        }

        #if DEBUG
        Section {
            Button(isCreatingSchema ? "Creating iCloud Schema…" : "Create iCloud Schema") {
                createSchema()
            }
            .tint(.primary)
            .disabled(isCreatingSchema || !LibrarySync.isCloudKitAvailable)
        } header: {
            Text("Developer")
        } footer: {
            Text(schemaResult ?? "Debug builds only. Creates every iCloud record type and field in the Development environment, to deploy to Production before a TestFlight or App Store build.")
        }
        #endif
    }

    #if DEBUG
    private func createSchema() {
        isCreatingSchema = true
        schemaResult = nil
        Task {
            do {
                try await sync.createDevelopmentSchema()
                schemaResult = "Created. Deploy the schema to Production in the CloudKit Console."
            } catch {
                schemaResult = "Couldn't create the schema: \(error.localizedDescription)"
            }
            isCreatingSchema = false
        }
    }
    #endif

    private var footer: String {
        switch sync.status {
        case .off:
            "Books and reading positions stay on this device."
        case .offAfterICloudDeletion:
            "Strobe's data was deleted from iCloud, so sync turned off. Your library is still on this device. Turn sync on to upload it again."
        case .offForNewAccount:
            "This device is signed in to a different iCloud account than the one your library synced with, so sync turned off. Your library is still on this device. Turn sync on to sync it with this account."
        case .unavailable:
            "iCloud sync isn't available in this build."
        case .signedOut:
            signedOutFooter
        case .restricted:
            "iCloud is restricted on this device."
        case .temporarilyUnavailable:
            "iCloud isn't available right now. Changes will sync when it's back."
        case .storageFull:
            "Your iCloud storage is full, so new books aren't uploading."
        case .syncing:
            "Syncing…"
        case .upToDate:
            "Up to date."
        }
    }

    private var signedOutFooter: String {
        #if os(macOS)
        "Sign in to iCloud in System Settings to sync your library."
        #else
        "Sign in to iCloud in the Settings app to sync your library."
        #endif
    }
}
