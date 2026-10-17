import SwiftUI

/// Asks whether to sync the library with iCloud: once for someone who used
/// Strobe before sync, and when this device signs in to a different iCloud
/// account than the one the library synced with (see ``SyncPrompt``). Sync
/// stays off until the answer is yes, and closing the sheet any other way
/// counts as Not Now.
struct SyncPromptView: View {
    let prompt: SyncPrompt
    @AppStorage(ReaderSettings.Keys.iCloudSyncEnabled) private var iCloudSyncEnabled = ReaderSettings.Defaults.iCloudSyncEnabled
    @AppStorage(ReaderSettings.Keys.iCloudSyncPrompt) private var pendingPrompt: SyncPrompt?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Image(systemName: "icloud")
                        .font(.system(size: 60))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary)
                        .padding(.top, 40)
                        .accessibilityHidden(true)

                    Text(headline)
                        .font(StrobeTheme.displayFont(size: 34, relativeTo: .largeTitle))
                        .multilineTextAlignment(.center)
                        .padding(.top, 20)

                    Text(summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(features) { feature in
                            WelcomeFeatureRow(feature: feature)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 36)
                    .padding(.bottom, 24)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 4) {
                Button {
                    answer(turnOn: true)
                    dismiss()
                } label: {
                    Text(turnOnTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                // Neutral: red is for the one primary action.
                Button {
                    answer(turnOn: false)
                    dismiss()
                } label: {
                    Text("Not Now")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .tint(.primary)
                .keyboardShortcut(.cancelAction)
            }
            .frame(maxWidth: 464)
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .background { StrobeTheme.background.ignoresSafeArea() }
        .onDisappear {
            // Closed without an answer: the same as Not Now.
            if pendingPrompt != nil {
                answer(turnOn: false)
            }
        }
    }

    /// Either answer clears the question first, so the sheet closing
    /// afterwards doesn't answer again, and other windows stop asking.
    private func answer(turnOn: Bool) {
        pendingPrompt = nil
        iCloudSyncEnabled = turnOn
        if turnOn {
            LibrarySync.shared.updateEnabled()
        }
    }

    private var headline: String {
        switch prompt {
        case .returningUser: "Sync with iCloud"
        case .newAccount: "A Different iCloud Account"
        }
    }

    private var summary: String {
        switch prompt {
        case .returningUser:
            "Keep your library and reading positions the same on your iPhone, iPad, and Mac."
        case .newAccount:
            "This device is signed in to a different iCloud account than the one your library synced with. Sync is off until you choose."
        }
    }

    private var turnOnTitle: String {
        switch prompt {
        case .returningUser: "Turn On iCloud Sync"
        case .newAccount: "Sync with This Account"
        }
    }

    private var features: [WelcomeFeature] {
        switch prompt {
        case .returningUser:
            [
                WelcomeFeature(
                    symbol: "books.vertical",
                    title: "Your Library Everywhere",
                    detail: "Books you add on one device show up on the others."
                ),
                WelcomeFeature(
                    symbol: "bookmark",
                    title: "Pick Up Where You Left Off",
                    detail: "Your place in each book follows you from device to device."
                ),
                WelcomeFeature(
                    symbol: "lock.icloud",
                    title: "Private to You",
                    detail: "Everything stays in your private iCloud. You can change this in Settings."
                ),
            ]
        case .newAccount:
            [
                WelcomeFeature(
                    symbol: "books.vertical",
                    title: "Your Library Stays",
                    detail: "The books on this device stay here either way."
                ),
                WelcomeFeature(
                    symbol: "arrow.triangle.2.circlepath.icloud",
                    title: "Sync with This Account",
                    detail: "Your library and reading positions sync with this account, and its books come to this device."
                ),
                WelcomeFeature(
                    symbol: "gearshape",
                    title: "Decide Later",
                    detail: "You can turn sync on in Settings at any time."
                ),
            ]
        }
    }
}

extension View {
    /// Asks a waiting sync question (``SyncPrompt``) in a sheet once
    /// `canAsk` says nothing else is on screen. With the library open in
    /// several windows, only one asks.
    func syncPrompt(canAsk: Bool) -> some View {
        modifier(SyncPromptPresenter(canAsk: canAsk))
    }
}

private struct SyncPromptPresenter: ViewModifier {
    let canAsk: Bool
    @AppStorage(ReaderSettings.Keys.iCloudSyncPrompt) private var pendingPrompt: SyncPrompt?
    @Environment(\.scenePhase) private var scenePhase
    @State private var presentedPrompt: SyncPrompt?
    @State private var window = UUID()

    /// The question to ask in this window now: one is waiting, nothing else
    /// is on screen, and the window is in front.
    private var promptToAsk: SyncPrompt? {
        guard canAsk, scenePhase == .active else { return nil }
        return pendingPrompt
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $presentedPrompt) { prompt in
                SyncPromptView(prompt: prompt)
                    #if os(macOS)
                    .frame(width: 480, height: 640)
                    #endif
            }
            .onChange(of: promptToAsk, initial: true) { _, prompt in
                guard let prompt, presentedPrompt == nil, SyncPromptWindow.claim(window) else { return }
                presentedPrompt = prompt
            }
            .onChange(of: pendingPrompt) { _, pending in
                // Answered here, in another window, or in Settings.
                guard pending == nil else { return }
                presentedPrompt = nil
                SyncPromptWindow.release(window)
            }
            .onDisappear {
                SyncPromptWindow.release(window)
            }
    }
}

/// The window asking a sync question, so a library open in several windows
/// asks once.
private enum SyncPromptWindow {
    private static var asking: UUID?

    /// Whether `window` may ask: no other window is asking.
    static func claim(_ window: UUID) -> Bool {
        if let asking, asking != window { return false }
        asking = window
        return true
    }

    static func release(_ window: UUID) {
        if asking == window { asking = nil }
    }
}
