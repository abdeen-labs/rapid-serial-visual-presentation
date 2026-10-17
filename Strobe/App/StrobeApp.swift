import SwiftUI
import SwiftData
import os

/// The app entry point. Bootstraps the SwiftData model container
/// and displays a diagnostic error view if persistence initialization fails.
@main
struct StrobeApp: App {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.abdeen.strobe",
        category: "ModelContainer"
    )
    private static let diagnosticsKey = "last_model_container_bootstrap_diagnostics"

    /// The library's container, made once per launch. App Intents share it:
    /// they run in the app's process, sometimes before any window opens.
    static let sharedBootstrap = bootstrapModelContainer()

    private var bootstrapResult: BootstrapResult { Self.sharedBootstrap }
    /// Adds articles and text shared from other apps to the library.
    private let shareInboxImporter: ShareInboxImporter?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container = Self.sharedBootstrap.container
        shareInboxImporter = container.map { ShareInboxImporter(container: $0) }
        if let container {
            LibraryObserver.start(container: container)
            // Before sync starts, which reads the choice.
            SyncConsent.storeLaunchChoice(hasDocuments: {
                // A library that can't be counted counts as one, so sync
                // waits for a yes.
                guard let count = try? container.mainContext.fetchCount(FetchDescriptor<Document>()) else { return true }
                return count > 0
            })
            // Started here rather than from a view so iCloud sync also runs
            // when the system launches the app in the background.
            LibrarySync.shared.start(container: container)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let container = bootstrapResult.container {
                ContentView()
                    .modelContainer(container)
                    .libraryCloudSync(container)
                    .preferredColorScheme(.dark)
                    .tint(StrobeTheme.accent)
                    #if os(macOS)
                    .frame(minWidth: 720, minHeight: 540)
                    #endif
            } else {
                StartupFailureView(diagnostics: bootstrapResult.diagnostics)
            }
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 740)
        #endif
        .onChange(of: scenePhase, initial: true) { _, phase in
            shareInboxImporter?.scenePhaseChanged(to: phase)
        }
        .commands {
            LibraryCommands()
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
                .tint(StrobeTheme.accent)
        }
        #endif
    }

    struct BootstrapResult {
        let container: ModelContainer?
        let diagnostics: String
    }

    private static func bootstrapModelContainer() -> BootstrapResult {
        let schema = Schema([Document.self])
        var diagnostics: [String] = []

        func append(_ message: String) {
            diagnostics.append(message)
            logger.error("\(message, privacy: .public)")
        }

        do {
            let container = try makePersistentContainer(schema: schema)
            return BootstrapResult(container: container, diagnostics: "")
        } catch {
            append("Persistent init failed: \(describe(error: error))")
        }

        let summary = diagnostics.joined(separator: "\n")
        UserDefaults.standard.set(summary, forKey: diagnosticsKey)
        return BootstrapResult(container: nil, diagnostics: summary)
    }

    private static func makePersistentContainer(schema: Schema) throws -> ModelContainer {
        // `.none`, never the default `.automatic`: with the app's iCloud
        // entitlement, `.automatic` turns on SwiftData's own CloudKit
        // mirroring, which this schema doesn't support (the store then fails
        // to load). iCloud sync runs beside the store; see `LibrarySync`.
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [modelConfiguration])
    }

    private static func describe(error: Error) -> String {
        let nsError = error as NSError
        var components: [String] = [
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "description=\(nsError.localizedDescription)"
        ]

        if !nsError.userInfo.isEmpty {
            components.append("userInfo=\(nsError.userInfo)")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            components.append("underlying=\(underlying.domain)(\(underlying.code)): \(underlying.localizedDescription)")
        }

        return components.joined(separator: " | ")
    }
}

private struct StartupFailureView: View {
    let diagnostics: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Startup Error")
                    .font(.title2.weight(.semibold))

                Text("SwiftData failed to initialize. The app is blocked to prevent data loss.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                Text("Please share the diagnostics below.")
                    .font(.body)

                Text(diagnostics.isEmpty ? "No diagnostics available." : diagnostics)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(20)
        }
    }
}
