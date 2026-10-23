import SwiftUI

/// The reader's Read Aloud button: on or off, the voice's download and first
/// load while they run, and what keeps a voice from reading. Tapping it does
/// what ``ReadAloudAvailability/tap`` says, through `action`. Reads the
/// model's state, so it redraws as a download moves and the reader doesn't.
struct ReadAloudButton: View {
    let controller: ReadAloudController
    let isEnabled: Bool
    let action: (ReadAloudAvailability.Tap) -> Void

    var body: some View {
        let availability = controller.availability(isEnabled: isEnabled)
        Button {
            action(availability.tap)
        } label: {
            icon(for: availability.status)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(ReaderGlassButtonStyle(shape: Circle()))
        .accessibilityLabel("Read Aloud")
        .accessibilityValue(Self.accessibilityValue(for: availability.status))
        .accessibilityAddTraits(.isToggle)
    }

    @ViewBuilder
    private func icon(for status: ReadAloudAvailability.Status) -> some View {
        switch status {
        case .off, .englishOnly, .needsDownload:
            symbol("speaker.slash")
        case .reading:
            symbol("speaker.wave.2")
        case .failed:
            symbol("speaker.badge.exclamationmark")
        case .downloading(let fraction?):
            DownloadRing(fraction: fraction)
        case .downloading(nil), .preparing:
            ProgressView()
                .controlSize(.small)
                .tint(.primary)
        }
    }

    /// The icon as ``ReaderGlassButton`` draws it.
    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
    }

    private static func accessibilityValue(for status: ReadAloudAvailability.Status) -> String {
        switch status {
        case .off: "Off"
        case .englishOnly: "English documents only"
        case .needsDownload: "Off, voice not downloaded"
        case .downloading(let fraction?):
            "Downloading voice, \(fraction.formatted(.percent.precision(.fractionLength(0))))"
        case .downloading(nil): "Downloading voice"
        case .preparing: "Preparing voice"
        case .reading: "On"
        case .failed: "Voice unavailable"
        }
    }
}

/// How far the voice's download has come, as a ring filling around a
/// download arrow. Neutral, as the reader's controls are: red is for
/// reading progress.
private struct DownloadRing: View {
    let fraction: Double
    private let lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.5), lineWidth: lineWidth)
            Circle()
                // A sliver at the start, so it reads as a ring under way.
                .trim(from: 0, to: min(max(fraction, 0.02), 1))
                .stroke(.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "arrow.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.primary)
        }
        .frame(width: 22, height: 22)
        .animation(.linear(duration: 0.2), value: fraction)
    }
}

/// A question or note the Read Aloud button raises.
enum ReadAloudPrompt: Equatable {
    /// Download the voice, turning reading aloud on?
    case download
    /// Only English documents are read aloud for now.
    case englishOnly
    /// The voice couldn't get ready: try again?
    case failure(message: String)
}

extension View {
    /// The alerts for `prompt`. Not Now leaves reading aloud off.
    @ViewBuilder
    func readAloudPrompts(
        _ prompt: Binding<ReadAloudPrompt?>,
        isEnabled: Binding<Bool>,
        controller: ReadAloudController
    ) -> some View {
        if KokoroVoiceModel.isSupported {
            modifier(ReadAloudPrompts(prompt: prompt, isEnabled: isEnabled, controller: controller))
        } else {
            self
        }
    }
}

private struct ReadAloudPrompts: ViewModifier {
    @Binding var prompt: ReadAloudPrompt?
    @Binding var isEnabled: Bool
    let controller: ReadAloudController

    func body(content: Content) -> some View {
        content
            .alert("Download Voice?", isPresented: isShowing(.download)) {
                Button("Download") {
                    isEnabled = true
                    VoiceModelUse.install()
                }
                Button("Not Now", role: .cancel) {
                    isEnabled = false
                }
            } message: {
                Text("Reading aloud uses a natural voice that runs on this device. It's a one-time download of about \(Self.downloadSize).")
            }
            .alert("English Only for Now", isPresented: isShowing(.englishOnly)) {
                Button("OK") {}
            } message: {
                Text(englishOnlyMessage)
            }
            .alert("Voice Unavailable", isPresented: isShowingFailure, presenting: failureMessage) { _ in
                Button("Try Again") {
                    isEnabled = true
                    controller.retry()
                }
                Button("Not Now", role: .cancel) {
                    isEnabled = false
                }
            } message: { message in
                Text(message)
            }
    }

    private static var downloadSize: String {
        ByteCountFormatter.string(fromByteCount: KokoroVoiceModel.downloadSize, countStyle: .file)
    }

    /// Names the document's language where it's known.
    private var englishOnlyMessage: String {
        if let code = controller.documentLanguage,
           let language = Locale.current.localizedString(forLanguageCode: code) {
            return "Reading aloud reads documents in English for now, and this one seems to be in \(language)."
        }
        return "Reading aloud reads documents in English for now, and this one seems to be in another language."
    }

    private var failureMessage: String? {
        if case .failure(let message) = prompt { message } else { nil }
    }

    private func isShowing(_ shown: ReadAloudPrompt) -> Binding<Bool> {
        Binding(
            get: { prompt == shown },
            set: { if !$0, prompt == shown { prompt = nil } }
        )
    }

    private var isShowingFailure: Binding<Bool> {
        Binding(
            get: { failureMessage != nil },
            set: { if !$0, failureMessage != nil { prompt = nil } }
        )
    }
}
