import SwiftUI

/// Reading aloud on or off, and the voice that reads: downloading it,
/// choosing one, hearing it, and removing it. The voice is the Kokoro model
/// (``KokoroVoiceModel``), which runs on the device and downloads once.
struct ReadAloudSettingsSections: View {
    @AppStorage(ReaderSettings.Keys.readAloudEnabled) private var readAloudEnabled: Bool = ReaderSettings.Defaults.readAloudEnabled
    @AppStorage(ReaderSettings.Keys.readAloudVoice) private var readAloudVoice: String = ReaderSettings.Defaults.readAloudVoice
    @State private var sampler = VoiceSampler()
    @State private var confirmsRemoval = false
    private let model = KokoroVoiceModel.shared

    private static let speedCap = Int(ReaderSettings.readAloudWPMRange.upperBound)

    var body: some View {
        Section {
            Toggle(isOn: $readAloudEnabled) {
                Text("Read Aloud")
                Text("A voice reads the words as they show")
            }
        } footer: {
            Text("Speed is capped at \(Self.speedCap) wpm while reading aloud. For now, only documents in English are read aloud.")
        }

        Section {
            voiceRows
        } header: {
            Text("Voice")
        } footer: {
            if let voiceFooter {
                Text(voiceFooter)
            }
        }

        if let size = removableSize {
            Section {
                Button("Remove Voice (\(Self.formatted(size)))", role: .destructive) {
                    confirmsRemoval = true
                }
                .confirmationDialog("Remove Voice?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
                    Button("Remove Voice", role: .destructive) {
                        remove()
                    }
                } message: {
                    Text("This frees \(Self.formatted(size)). Reading aloud turns off until you download the voice again.")
                }
            }
        }
    }

    // MARK: - Voice

    @ViewBuilder
    private var voiceRows: some View {
        switch model.state {
        case .notInstalled:
            Button("Download Voice") {
                VoiceModelUse.install()
            }
            .tint(.primary)
        case .downloading(let fraction):
            downloadProgress(fraction)
            Button("Cancel Download") {
                model.cancelInstall()
            }
            .tint(.primary)
        case .installed, .preparing, .ready:
            voicePicker
            sampleButton
        case .failed(let message):
            Text(message)
                .foregroundStyle(.secondary)
            Button("Try Again") {
                VoiceModelUse.install()
            }
            .tint(.primary)
        }
    }

    @ViewBuilder
    private func downloadProgress(_ fraction: Double?) -> some View {
        if let fraction {
            ProgressView(value: fraction) {
                Text("Downloading Voice…")
            } currentValueLabel: {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            .tint(.primary)
        } else {
            HStack {
                Text("Downloading Voice…")
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    /// The chosen voice, as one the catalog offers: a name stored from
    /// before shows as the voice that reads for it.
    private var voice: Binding<String> {
        Binding(
            get: { KokoroVoices.chosen(readAloudVoice).id },
            set: { readAloudVoice = $0 }
        )
    }

    private var voicePicker: some View {
        Picker("Voice", selection: voice) {
            ForEach(KokoroVoices.groups) { group in
                Section(Self.title(for: group.accent)) {
                    ForEach(group.voices) { voice in
                        Self.label(for: voice)
                            .tag(voice.id)
                    }
                }
            }
        }
        #if os(iOS)
        .pickerStyle(.navigationLink)
        #endif
        .onChange(of: readAloudVoice) {
            sampler.stop()
        }
    }

    private static func title(for accent: KokoroVoices.Accent) -> String {
        switch accent {
        case .american: "American English"
        case .british: "British English"
        }
    }

    /// The voice's name, then whose voice it is.
    private static func label(for voice: KokoroVoices.Voice) -> Text {
        let gender = switch voice.gender {
        case .female: "Female"
        case .male: "Male"
        }
        let detail = Text(gender).foregroundStyle(.secondary)
        return Text("\(voice.name)  \(detail)")
    }

    /// Play Sample, or while the model loads, which takes a while the
    /// first time, a note that it's getting ready. A sample asked for
    /// meanwhile plays once it is, unless it's tapped again.
    private var sampleButton: some View {
        let isPreparing = model.state == .preparing
        return Button {
            if sampler.isPlaying {
                sampler.stop()
            } else {
                sampler.play(KokoroVoices.chosen(readAloudVoice))
            }
        } label: {
            if isPreparing {
                HStack {
                    Text("Preparing Voice…")
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
                Text(sampler.isPlaying ? "Stop Sample" : "Play Sample")
            }
        }
        .tint(.primary)
        .disabled(isPreparing && !sampler.isPlaying)
        .onDisappear {
            sampler.stop()
        }
    }

    private var voiceFooter: String? {
        let size = Self.formatted(KokoroVoiceModel.downloadSize)
        switch model.state {
        case .notInstalled:
            return "Reads with a natural voice that runs on this device. It downloads once, about \(size)."
        case .downloading:
            return "The voice downloads once, about \(size), and runs on this device."
        case .preparing:
            return "Getting the voice ready for this device. The first time takes a little while."
        case .installed, .ready:
            if let failure = sampler.failure {
                return "The sample couldn't play. \(failure)"
            }
            // Only the default voice comes with the model; the rest
            // download their own small part when they first read.
            return "The voice runs on this device, so what you read stays on it. Voices other than \(KokoroVoices.defaultVoice.name) download a little more the first time they read."
        case .failed:
            return nil
        }
    }

    // MARK: - Removing

    /// What removing the voice frees, when it's on disk and nothing is
    /// downloading or loading it.
    private var removableSize: Int64? {
        switch model.state {
        case .installed, .ready, .failed: model.installedSize
        case .notInstalled, .downloading, .preparing: nil
        }
    }

    private func remove() {
        sampler.stop()
        readAloudEnabled = false
        Task {
            await model.remove()
        }
    }

    private static func formatted(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// Plays a short line in a voice, for choosing one: rendered by the model
/// and played the way reading aloud plays its words.
@Observable
private final class VoiceSampler {
    /// Whether a sample is on its way or playing.
    private(set) var isPlaying = false
    /// Why the last sample didn't play, as when a voice's pack, which
    /// downloads the first time it reads, couldn't download.
    private(set) var failure: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var player: SpeechPlayer?
    /// Made for the first sample: the view this belongs to is made often.
    @ObservationIgnored private var session: ReadAloudAudioSession?

    func play(_ voice: KokoroVoices.Voice) {
        stop()
        isPlaying = true
        failure = nil
        task = Task { [weak self] in
            do {
                let renderer = try await KokoroVoiceModel.shared.renderer(voice: voice.id)
                let words = KokoroVoices.sample(for: voice).split(separator: " ").map(String.init)
                let speech = try await renderer.render(SpeechScript(words: words, range: words.indices), speed: 1)
                guard let self, !Task.isCancelled else { return }
                let session = self.session ?? ReadAloudAudioSession()
                self.session = session
                try await session.activate()
                guard !Task.isCancelled else { return }
                let player = SpeechPlayer()
                player.onChunkFinished = { [weak self] _ in
                    self?.stop()
                }
                player.enqueue(speech, id: 0)
                try player.play()
                self.player = player
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.stop()
                self.failure = error.localizedDescription
            }
        }
    }

    func stop() {
        failure = nil
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        session?.deactivate()
        isPlaying = false
    }
}
