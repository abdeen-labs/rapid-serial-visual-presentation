import SwiftUI

/// The first-launch welcome: a live word display showing how Strobe reads,
/// three things to know, and a button to start. Settings can show it again.
struct WelcomeView: View {
    @AppStorage(ReaderSettings.Keys.hasSeenTutorial) private var hasSeenTutorial = false
    @AppStorage(ReaderSettings.Keys.holdToReadEnabled) private var holdToReadEnabled: Bool = ReaderSettings.Defaults.holdToReadEnabled
    @AppStorage(ReaderSettings.Keys.holdSpeedAdjustEnabled) private var holdSpeedAdjustEnabled: Bool = ReaderSettings.Defaults.holdSpeedAdjustEnabled
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    WelcomeWordDemo()
                        .padding(.top, 36)

                    Text("Welcome to Strobe")
                        .font(StrobeTheme.displayFont(size: 34, relativeTo: .largeTitle))
                        .multilineTextAlignment(.center)
                        .padding(.top, 32)

                    Text("Read one word at a time, at the speed you choose.")
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

            Button {
                hasSeenTutorial = true
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
            hasSeenTutorial = true
        }
    }

    private var features: [WelcomeFeature] {
        let bringReading = WelcomeFeature(
            symbol: "books.vertical",
            title: "Bring Your Reading",
            detail: "Import EPUB, PDF, and text files, or paste text."
        )
        #if os(macOS)
        return [
            bringReading,
            WelcomeFeature(
                symbol: "keyboard",
                title: "Press Space to Read",
                detail: "Space starts and pauses. The arrow keys step through words."
            ),
            WelcomeFeature(
                symbol: "gauge.with.dots.needle.67percent",
                title: "Set Your Pace",
                detail: holdSpeedAdjustEnabled
                    ? "Click and drag up or down while you read to change speed. Pauses and timing are in Settings."
                    : "Change speed with the slider while paused. Pauses and timing are in Settings."
            ),
        ]
        #else
        return [
            bringReading,
            holdToReadEnabled
                ? WelcomeFeature(
                    symbol: "hand.tap",
                    title: "Hold to Read",
                    detail: "Let go to pause. Tap with two fingers to read hands-free. Swipe sideways to step through words."
                )
                : WelcomeFeature(
                    symbol: "hand.tap",
                    title: "Tap to Read",
                    detail: "Tap again to pause. Swipe sideways to step through words."
                ),
            WelcomeFeature(
                symbol: "gauge.with.dots.needle.67percent",
                title: "Set Your Pace",
                detail: holdToReadEnabled && holdSpeedAdjustEnabled
                    ? "Drag up or down while you hold to change speed. Pauses and timing are in Settings."
                    : "Change speed with the slider while paused. Pauses and timing are in Settings."
            ),
        ]
        #endif
    }
}

/// A row on the welcome screen, and on the sync prompt and What's New, which
/// are modeled on it.
struct WelcomeFeature: Identifiable {
    let symbol: String
    let title: String
    let detail: String

    var id: String { symbol }
}

struct WelcomeFeatureRow: View {
    let feature: WelcomeFeature

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: feature.symbol)
                .font(.title2)
                .foregroundStyle(StrobeTheme.accent)
                .frame(width: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.headline)
                Text(feature.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Plays a short sentence through the reader's own word display, in the
/// reader's font and colors. Shows a single word under Reduce Motion.
private struct WelcomeWordDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0

    private static let words = [
        "Read", "one", "word", "at", "a", "time,",
        "right", "where", "your", "eyes", "already", "are.",
    ]

    var body: some View {
        WordView(word: reduceMotion ? "Strobe" : Self.words[index], fontSize: 40)
            .background { ReaderBackdrop() }
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
            .task(id: reduceMotion) {
                guard !reduceMotion else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(Self.displayTime(for: index)))
                    guard !Task.isCancelled else { return }
                    index = (index + 1) % Self.words.count
                }
            }
    }

    /// About 250 wpm, longer after punctuation, with a rest before the
    /// sentence repeats.
    private static func displayTime(for index: Int) -> Int {
        if index == words.count - 1 { return 1400 }
        if let last = words[index].last, ",.;:".contains(last) { return 420 }
        return 240
    }
}

extension View {
    /// Presents the welcome screen as a sheet.
    func welcomeSheet(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            WelcomeView()
                #if os(macOS)
                .frame(width: 480, height: 640)
                #endif
        }
    }
}
