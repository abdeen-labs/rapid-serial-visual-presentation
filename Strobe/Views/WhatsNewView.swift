import SwiftUI

/// What's new in Strobe: the releases from ``WhatsNew``, newest first, in
/// rows like the welcome's. Shown once after an update, and from Settings.
/// Closing it marks the running version seen.
struct WhatsNewView: View {
    /// Newest first. The headline names the first; any older ones follow
    /// under their own version.
    let releases: [WhatsNew.Release]
    @AppStorage(ReaderSettings.Keys.lastSeenWhatsNewVersion) private var lastSeenVersion: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 60))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary)
                        .padding(.top, 40)
                        .accessibilityHidden(true)

                    Text(headline)
                        .font(StrobeTheme.displayFont(size: 34, relativeTo: .largeTitle))
                        .multilineTextAlignment(.center)
                        .padding(.top, 20)
                        .accessibilityAddTraits(.isHeader)

                    ForEach(releases) { release in
                        VStack(alignment: .leading, spacing: 24) {
                            if release.id != releases.first?.id {
                                Text("Strobe \(release.version)")
                                    .font(.title3.weight(.semibold))
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(release.items, id: \.self) { item in
                                WelcomeFeatureRow(feature: WelcomeFeature(
                                    symbol: item.symbol,
                                    title: item.title,
                                    detail: item.detail
                                ))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 36)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)

            Button {
                markSeen()
                dismiss()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .frame(maxWidth: 464)
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background { StrobeTheme.background.ignoresSafeArea() }
        .onDisappear {
            // Closed any other way, it still counts as seen.
            markSeen()
        }
    }

    private var headline: String {
        guard let newest = releases.first else { return "What's New in Strobe" }
        return "What's New in Strobe \(newest.version)"
    }

    private func markSeen() {
        lastSeenVersion = WhatsNew.lastSeen(afterShowing: WhatsNew.appVersion, over: lastSeenVersion)
    }
}

extension WhatsNew.Requirement {
    /// Whether this device has it.
    nonisolated var isMetOnThisDevice: Bool {
        switch self {
        case .readAloud: KokoroVoiceModel.isSupported
        }
    }
}

extension View {
    /// Shows What's New once after an update (``WhatsNew/releasesToShow``)
    /// when `canShow` says nothing else is on screen. With the library open
    /// in several windows, only one shows it. On a fresh install it marks
    /// the running version seen instead, since the welcome introduces it.
    func whatsNewAfterUpdate(canShow: Bool) -> some View {
        modifier(WhatsNewPresenter(canShow: canShow))
    }

    /// Shows What's New for the running version, as Settings ▸ About does.
    func whatsNewSheet(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            WhatsNewView(releases: WhatsNew.runningRelease.map { [$0] } ?? [])
                #if os(macOS)
                .frame(width: 480, height: 640)
                #endif
        }
    }
}

extension WhatsNew {
    /// The release Settings shows, as this device shows it; nil when the
    /// running version has none, before or at it.
    static var runningRelease: Release? {
        currentRelease(for: appVersion, meets: \.isMetOnThisDevice)
    }
}

private struct WhatsNewPresenter: ViewModifier {
    let canShow: Bool
    @AppStorage(ReaderSettings.Keys.hasSeenTutorial) private var hasSeenTutorial = false
    @AppStorage(ReaderSettings.Keys.lastSeenWhatsNewVersion) private var lastSeenVersion: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var shown: ShownReleases?
    @State private var window = UUID()

    /// What to show in this window now: releases not seen yet, with nothing
    /// else on screen and the window in front.
    private var releasesToShow: [WhatsNew.Release] {
        guard canShow, scenePhase == .active else { return [] }
        return WhatsNew.releasesToShow(
            currentVersion: WhatsNew.appVersion,
            lastSeen: lastSeenVersion,
            isFreshInstall: !hasSeenTutorial,
            meets: \.isMetOnThisDevice
        )
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $shown, onDismiss: { WhatsNewWindow.release(window) }) { shown in
                WhatsNewView(releases: shown.releases)
                    #if os(macOS)
                    .frame(width: 480, height: 640)
                    #endif
            }
            // Restarts, and so stops waiting, whenever what can show changes.
            .task(id: releasesToShow.map(\.id)) {
                let releases = releasesToShow
                guard !releases.isEmpty, shown == nil else { return }
                // Lets a sheet closing first, the welcome or a sync
                // question, finish before this one comes up.
                try? await Task.sleep(for: .seconds(0.6))
                guard !Task.isCancelled, WhatsNewWindow.claim(window) else { return }
                shown = ShownReleases(releases: releases)
            }
            .onChange(of: hasSeenTutorial, initial: true) { _, seen in
                // A fresh install: the welcome stands in for this version's
                // What's New, so it never shows after the welcome.
                guard !seen else { return }
                lastSeenVersion = WhatsNew.lastSeen(afterShowing: WhatsNew.appVersion, over: lastSeenVersion)
            }
            .onDisappear {
                WhatsNewWindow.release(window)
            }
    }
}

/// The releases one What's New sheet shows.
private struct ShownReleases: Identifiable {
    let releases: [WhatsNew.Release]
    let id = UUID()
}

/// The window showing What's New, so a library open in several windows
/// shows it once.
private enum WhatsNewWindow {
    private static var showing: UUID?

    /// Whether `window` may show it: no other window is.
    static func claim(_ window: UUID) -> Bool {
        if let showing, showing != window { return false }
        showing = window
        return true
    }

    static func release(_ window: UUID) {
        if showing == window { showing = nil }
    }
}
