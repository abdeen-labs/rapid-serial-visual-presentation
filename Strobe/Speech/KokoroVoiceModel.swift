import FluidAudio
import Foundation
import Observation
import os

/// The voice model that reads aloud: Kokoro-82M (Apache-2.0), run on the
/// device through FluidAudio. It isn't in the app. It downloads once, about
/// ``downloadSize`` bytes, into Application Support, and compiles for this
/// device the first time it loads. FluidAudio's original runtime, which it
/// uses, and the models it downloads need iOS 17 or macOS 14, as the app
/// does; only a device with too little memory goes without
/// (``isSupported``).
///
/// The files live in two folders, both kept out of backups since they can
/// always be downloaded again:
///
/// - `Voices` in Application Support holds the model's seven stages and a
///   voice pack for each voice offered (``KokoroVoices/all``), so every one
///   reads offline. Another Kokoro voice's pack downloads the first time it
///   reads.
/// - FluidAudio keeps the English text frontend (a pronunciation lexicon
///   and a small spelling-to-sound model) in its own folder whatever the
///   model's folder is: `fluidaudio` in Application Support on iOS, and in
///   `~/.cache` on macOS.
///
/// Loading is shared: callers that stop waiting, as a reader does on every
/// pause, leave it running for the next.
@Observable
final class KokoroVoiceModel {
    static let shared = KokoroVoiceModel()

    /// Whether this device can run the model, and so offers reading aloud.
    /// Reading takes about 300 MB, and FluidAudio reports a 3 GB iPhone
    /// being killed for its memory while loading the model, so an iPhone or
    /// iPad needs about 4 GB. Every Mac that runs the app has enough.
    nonisolated static var isSupported: Bool {
        #if os(iOS)
        ProcessInfo.processInfo.physicalMemory >= 3_500_000_000
        #else
        true
        #endif
    }

    enum State: Equatable {
        /// Not downloaded.
        case notInstalled
        /// Downloading: the fraction done, when known.
        case downloading(fraction: Double?)
        /// On disk, not loaded.
        case installed
        /// Loading, including the first load's compile for this device.
        case preparing
        /// Loaded and ready to render.
        case ready
        /// The last download or load failed.
        case failed(message: String)
    }

    enum ModelError: LocalizedError {
        /// The model isn't downloaded.
        case notInstalled
        /// The model was removed after the renderer was made.
        case removed

        var errorDescription: String? {
            switch self {
            case .notInstalled: "The voice isn't downloaded."
            case .removed: "The voice was removed."
            }
        }
    }

    private(set) var state: State = .notInstalled

    /// Roughly what the download takes, in bytes, to say before it starts:
    /// ``filesDownloadSize`` and a voice pack for each of the other voices
    /// offered (``KokoroVoices/all``), as measured.
    nonisolated static let downloadSize: Int64 =
        filesDownloadSize + Int64(KokoroVoices.all.count - 1) * voicePackDownloadSize

    /// The model with its default voice (82.8 MB) and the text frontend
    /// (42.1 MB).
    nonisolated static let filesDownloadSize: Int64 = 124_900_000

    /// One more voice: about 2.7 MB of text, kept as 0.5 MB.
    nonisolated static let voicePackDownloadSize: Int64 = 2_670_000

    /// What the downloaded files take on disk, in bytes; nil when not
    /// installed. Core ML also keeps what it compiled for the device's
    /// processors in the app's caches, where the system can clear it.
    private(set) var installedSize: Int64?

    /// The folder the model goes in.
    @ObservationIgnored let directory: URL
    @ObservationIgnored private let version: KokoroAneVersion
    @ObservationIgnored private var manager: KokoroAneManager
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, any Error>?
    /// Voice packs being made ready, by voice.
    @ObservationIgnored private var voiceTasks: [String: Task<Void, any Error>] = [:]
    /// Count installs and loads, so a finished one clears only its own task.
    @ObservationIgnored private var installCount = 0
    @ObservationIgnored private var loadCount = 0
    @ObservationIgnored private var vocabulary: KokoroAneVocab?
    /// Changes whenever the files are removed, so a renderer made before
    /// can tell it mustn't load them again.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hasLoggedAdvisory = false

    /// - Parameters:
    ///   - directory: Where the model goes; `Voices` in Application Support
    ///     unless a test says otherwise.
    ///   - version: FluidAudio's Kokoro runtime. ``KokoroAneVersion/v3``
    ///     needs iOS 18 or macOS 15 and isn't used: on macOS 27.0.1 with an
    ///     M3 Pro, every chunk of 5 seconds or less (200 or fewer acoustic
    ///     frames, its fast path) aborts the app in its GPU source generator,
    ///     `MPSRuntime.mm:1519: failed assertion 'shape for TensorData is not
    ///     static'`, with `'mps.expand_dims' op invalid axis` logged before
    ///     it. FluidAudio pins that stage to the GPU. Longer chunks read, but
    ///     slower than with the original runtime. The original keeps Metal out
    ///     of Core ML on OS 27.
    init(directory: URL = KokoroVoiceModel.defaultDirectory, version: KokoroAneVersion = .legacy) {
        self.directory = directory
        self.version = version
        ModelRegistry.revisionOverrides[Self.modelRepository] = Self.modelRevision
        manager = KokoroAneManager(variant: .english, directory: directory, version: version)
        if let installation = Self.installation(in: directory) {
            state = .installed
            installedSize = Self.measuredSize(of: directory, sharesWeights: installation.sharesCompiledWeights)
        }
    }

    /// The Hugging Face repository the model downloads from.
    nonisolated static let modelRepository = "FluidInference/kokoro-82m-coreml"

    /// The repository's commit the model's stages download from, the one
    /// they were measured with, so a change to its `main` can't replace them
    /// under a released app. FluidAudio applies it only to the model's
    /// stages: the text frontend and the voice packs still come from `main`.
    nonisolated static let modelRevision = "e61d9ee79a01ad4ebf6b3d8bcfe2a03f6b8da105"

    nonisolated static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Voices", directoryHint: .isDirectory)
    }

    // MARK: - Installing

    /// Downloads the model if it isn't on disk, then loads it. Cancelling
    /// the caller stops it waiting, not the download: ``cancelInstall()``
    /// does that.
    func install() async {
        if installTask == nil {
            switch state {
            case .ready:
                return
            case .preparing:
                try? await load()
                return
            case .notInstalled, .downloading, .installed, .failed:
                startInstall()
            }
        }
        if let installTask {
            _ = try? await waitLeavingRunning(for: installTask)
        }
    }

    /// Stops a download under way. What it downloaded is deleted.
    func cancelInstall() {
        guard let installTask else { return }
        installTask.cancel()
        // FluidAudio downloads the model in a task of its own, which only
        // its cleanup cancels.
        let manager = manager
        Task { await manager.cleanup() }
    }

    private func startInstall() {
        installCount += 1
        let number = installCount
        installTask = Task {
            await performInstall()
            if installCount == number {
                installTask = nil
            }
        }
    }

    private func performInstall() async {
        let wasInstalled = Self.installation(in: directory) != nil
        state = wasInstalled ? .preparing : .downloading(fraction: 0)
        let progress = wasInstalled ? nil : Task { await followDownload() }
        defer { progress?.cancel() }
        logAdvisory()
        let voices = KokoroVoices.all.map(\.id)
        do {
            try Self.prepareFolders(directory)
            // Everything downloads before the compile, so the state only
            // moves forward: the frontend, the model, then the voices.
            try await manager.prepareEnglishFrontend()
            try Task.checkCancellation()
            if version == .legacy {
                try await KokoroAneResourceDownloader.ensureModels(variant: .english, directory: directory)
                progress?.cancel()
                try await downloadVoicePacks(voices)
                state = .preparing
                try await Self.loadAndWarmUp(manager)
            } else {
                // The v3 runtime downloads and compiles in one call; the
                // progress estimate sees where one ends.
                try await Self.loadAndWarmUp(manager)
                try Task.checkCancellation()
                progress?.cancel()
                try await manager.initialize(preloadVoices: Set(voices))
            }
            try Task.checkCancellation()
            progress?.cancel()
            state = .preparing
            let directory = directory
            let shares = await Self.tidyUp(directory)
            try Self.writeInstallation(Installation(sharesCompiledWeights: shares), in: directory)
            vocabulary = try Self.loadVocabulary(in: directory)
            installedSize = await Self.measuredSizeOffMain(of: directory, sharesWeights: shares)
            state = .ready
        } catch {
            if Task.isCancelled {
                await manager.cleanup()
                if wasInstalled {
                    state = .installed
                } else {
                    await deleteFiles()
                    state = .notInstalled
                }
            } else {
                Self.logger.error("Installing the voice failed: \(error)")
                state = .failed(message: error.localizedDescription)
            }
        }
    }

    /// Downloads the packs of `voices` that aren't on disk, so every voice
    /// offered reads offline, moving the progress on after each. The
    /// default voice comes with the model.
    private func downloadVoicePacks(_ voices: [String]) async throws {
        let repository = directory.appending(path: Repo.kokoroAne.folderName)
        var done = Self.filesDownloadSize
        for voice in voices where voice != KokoroAneConstants.defaultVoice {
            try Task.checkCancellation()
            _ = try await KokoroAneResourceDownloader.ensureVoicePack(voice, repoDirectory: repository)
            done += Self.voicePackDownloadSize
            if case .downloading(let fraction) = state {
                state = .downloading(fraction: max(fraction ?? 0, min(0.99, Double(done) / Double(Self.downloadSize))))
            }
        }
    }

    /// Estimates the download's progress from the bytes on disk and those
    /// on their way, about four times a second, until cancelled.
    private func followDownload() async {
        let directory = directory
        var fraction = 0.0
        while !Task.isCancelled {
            let onDisk = await Self.downloadedBytes(in: directory)
            let tasks = await ModelHub.session.allTasks
            let receiving = tasks.reduce(Int64(0)) { total, task in
                total + (task.state == .running ? max(0, task.countOfBytesReceived) : 0)
            }
            guard !Task.isCancelled, case .downloading = state else { return }
            if onDisk.hasManifest {
                // The v3 runtime compiles for the device next.
                state = .preparing
                return
            }
            let files = Double(Self.filesDownloadSize) / Double(Self.downloadSize)
            fraction = max(fraction, min(files, Double(onDisk.bytes + receiving) / Double(Self.downloadSize)))
            state = .downloading(fraction: fraction)
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: - Loading

    /// A renderer reading with `voice`, a Kokoro voice name such as
    /// `af_heart`, loading the model first if needed. Waits for a download
    /// under way. Throws if the model isn't installed or won't load, or if
    /// the voice's pack isn't on disk and can't be downloaded. A cancelled
    /// caller stops waiting at once and leaves the load running.
    func renderer(voice: String) async throws -> any SpeechRendering {
        if let installTask {
            try await waitLeavingRunning(for: installTask)
        }
        let generation = generation
        let manager = try await loadedManager(for: generation)
        try await prepareVoice(voice, with: manager)
        guard generation == self.generation else { throw ModelError.removed }
        let vocabulary = try self.vocabulary ?? Self.loadVocabulary(in: directory)
        self.vocabulary = vocabulary
        return KokoroSpeechRenderer(model: self, generation: generation, voice: voice, vocabulary: vocabulary)
    }

    /// The loaded model's manager for a renderer made at `generation`,
    /// loading it again if it was unloaded since. A cancelled caller stops
    /// waiting at once and leaves the load running.
    func loadedManager(for generation: Int) async throws -> KokoroAneManager {
        guard generation == self.generation else { throw ModelError.removed }
        try await load()
        guard generation == self.generation else { throw ModelError.removed }
        return manager
    }

    /// Loads the model from disk if it isn't loaded, in a task that outlasts
    /// its callers: the ``State/preparing`` state. The first load compiles
    /// the model for the device's processors, which took 8.5 seconds on an
    /// M3 Pro (FluidAudio measured about 20 on an M1), and again whenever the
    /// system clears that from the caches. A load after that took 0.8
    /// seconds, warming up included.
    private func load() async throws {
        if let installTask {
            try await waitLeavingRunning(for: installTask)
        }
        if loadTask == nil {
            switch state {
            case .ready:
                return
            case .notInstalled, .downloading:
                throw ModelError.notInstalled
            case .installed, .preparing, .failed:
                guard Self.installation(in: directory) != nil else { throw ModelError.notInstalled }
            }
            startLoading()
        }
        if let loadTask {
            try await waitLeavingRunning(for: loadTask)
        }
    }

    private func startLoading() {
        logAdvisory()
        loadCount += 1
        let number = loadCount
        let generation = generation
        let manager = manager
        state = .preparing
        loadTask = Task {
            defer {
                if loadCount == number { loadTask = nil }
            }
            do {
                try await Self.loadAndWarmUp(manager)
                if generation == self.generation {
                    state = .ready
                }
            } catch {
                if generation == self.generation {
                    Self.logger.error("Loading the voice failed: \(error)")
                    state = .failed(message: error.localizedDescription)
                }
                throw error
            }
        }
    }

    /// Loads the model, then warms it up, so the first chunk read renders as
    /// fast as the rest: the first phonemizing reads in the pronunciation
    /// lexicon, which took 0.67 seconds, and the first render sets up Core
    /// ML's predictions.
    nonisolated private static func loadAndWarmUp(_ manager: KokoroAneManager) async throws {
        try await manager.initialize()
        _ = try? await manager.englishPhonemes(for: "Hello.")
        _ = try await manager.synthesizeFromPhonemesDetailed("həlˈO.")
    }

    /// Makes sure `voice`'s pack is on disk and loaded, downloading it the
    /// first time the voice reads, in a task that outlasts its callers.
    private func prepareVoice(_ voice: String, with manager: KokoroAneManager) async throws {
        let task = voiceTasks[voice] ?? {
            let task = Task {
                defer { voiceTasks[voice] = nil }
                try await manager.initialize(preloadVoices: [voice])
            }
            voiceTasks[voice] = task
            return task
        }()
        try await waitLeavingRunning(for: task)
    }

    /// Frees the loaded model's memory, for when no reader reads aloud.
    func unload() async {
        guard state == .ready, loadTask == nil, installTask == nil else { return }
        await manager.cleanup()
        if state == .ready {
            state = .installed
        }
    }

    // MARK: - Removing

    /// Deletes the downloaded files, unloading the model first.
    func remove() async {
        if let installTask {
            cancelInstall()
            await installTask.value
        }
        if let loadTask {
            _ = try? await loadTask.value
        }
        for task in voiceTasks.values {
            task.cancel()
            _ = try? await task.value
        }
        await manager.cleanup()
        await deleteFiles()
        state = .notInstalled
    }

    /// Deletes every file the model downloaded or compiled, and starts over
    /// with a new manager, which downloads the frontend again too.
    private func deleteFiles() async {
        generation += 1
        manager = KokoroAneManager(variant: .english, directory: directory, version: version)
        vocabulary = nil
        installedSize = nil
        let directory = directory
        await Self.deleteFiles(in: directory)
    }

    // MARK: - System advisory

    /// FluidAudio's warning for this system, when it has one: since iOS
    /// 26.4, Core ML has crashed Kokoro now and then, in ways the app can't
    /// catch, and FluidAudio knows of no setup shown safe for long sessions
    /// on iOS 27. On macOS, only 26.4 and 26.5 are affected.
    private static var systemAdvisory: String? {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        guard version.majorVersion == 26, (4...5).contains(version.minorVersion) else { return nil }
        #else
        guard version.majorVersion > 26 || (version.majorVersion == 26 && version.minorVersion >= 4) else { return nil }
        #endif
        return "FluidAudio reports that Core ML can crash Kokoro on this system "
            + "(\(ProcessInfo.processInfo.operatingSystemVersionString)); "
            + "see https://github.com/FluidInference/FluidAudio/issues/889"
    }

    private func logAdvisory() {
        guard !hasLoggedAdvisory, let advisory = Self.systemAdvisory else { return }
        hasLoggedAdvisory = true
        Self.logger.warning("\(advisory, privacy: .public)")
    }

    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.abdeen.strobe",
        category: "ReadAloud"
    )
}

// MARK: - Files

extension KokoroVoiceModel {

    /// What a finished install records, in ``installationFileName``.
    nonisolated struct Installation: Codable {
        /// Whether each source package's weights share their storage with
        /// the compiled copy's (``shareCompiledWeights(in:)``).
        var sharesCompiledWeights: Bool
    }

    nonisolated static let installationFileName = "Installed.json"

    /// Frontend files FluidAudio downloads with the ones English needs but
    /// never reads for English: other languages' lexicons and word lists.
    /// It checks only for the files it reads, so these stay deleted.
    nonisolated static let unusedFrontendFiles = [
        "es_lexicon_cache.json", "fr_lexicon_cache.json",
        "gb_gold.json", "gb_silver.json", "us_gold.json", "us_silver.json",
    ]

    /// The folder FluidAudio keeps the text frontend in, and its other
    /// caches.
    nonisolated static func frontendDirectory() throws -> URL {
        try TtsCacheDirectory.ensure()
    }

    nonisolated static func installation(in directory: URL) -> Installation? {
        let url = directory.appending(path: installationFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Installation.self, from: data)
    }

    nonisolated static func writeInstallation(_ installation: Installation, in directory: URL) throws {
        let data = try JSONEncoder().encode(installation)
        try data.write(to: directory.appending(path: installationFileName), options: .atomic)
    }

    /// Creates both folders, out of backups.
    nonisolated static func prepareFolders(_ directory: URL) throws {
        for var folder in [directory, try frontendDirectory()] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
        }
    }

    /// The model's vocabulary, which says what phoneme symbols it reads:
    /// the newest `vocab.json` FluidAudio downloaded.
    nonisolated static func loadVocabulary(in directory: URL) throws -> KokoroAneVocab {
        let files = regularFiles(in: directory).filter { $0.url.lastPathComponent == "vocab.json" }
        guard let newest = files.max(by: { $0.modified < $1.modified }) else {
            throw ModelError.notInstalled
        }
        return try KokoroAneVocab.load(from: newest.url)
    }

    /// The bytes downloaded so far, in both folders, and whether the v3
    /// runtime's download is complete: FluidAudio writes its manifest last.
    @concurrent
    nonisolated static func downloadedBytes(in directory: URL) async -> (bytes: Int64, hasManifest: Bool) {
        var bytes: Int64 = 0
        var hasManifest = false
        for file in regularFiles(in: directory) {
            bytes += file.size
            if file.url.lastPathComponent == "manifest.json" {
                hasManifest = true
            }
        }
        if let frontend = try? frontendDirectory() {
            bytes += regularFiles(in: frontend).reduce(0) { $0 + $1.size }
        }
        return (bytes, hasManifest)
    }

    @concurrent
    nonisolated static func measuredSizeOffMain(of directory: URL, sharesWeights: Bool) async -> Int64 {
        measuredSize(of: directory, sharesWeights: sharesWeights)
    }

    /// What the files in both folders take on disk. Package weights that
    /// share their storage with a compiled copy count once.
    nonisolated static func measuredSize(of directory: URL, sharesWeights: Bool) -> Int64 {
        var total: Int64 = 0
        let shared = sharesWeights ? Set(weightPairs(in: directory).map(\.source.path)) : []
        for file in regularFiles(in: directory) where !shared.contains(file.url.path) {
            total += file.allocated
        }
        if let frontend = try? frontendDirectory() {
            total += regularFiles(in: frontend).reduce(0) { $0 + $1.allocated }
        }
        return total
    }

    /// After the first load: deletes the frontend files English never
    /// reads, and shares the weights of any source packages with their
    /// compiled copies.
    /// - Returns: Whether every source package's weights now share their
    ///   storage; true when there are none.
    @concurrent
    nonisolated static func tidyUp(_ directory: URL) async -> Bool {
        if let frontend = try? frontendDirectory() {
            let kokoro = frontend
                .appending(path: KokoroAneResourceDownloader.modelsSubdirectory)
                .appending(path: Repo.kokoro.folderName)
            for name in unusedFrontendFiles {
                try? FileManager.default.removeItem(at: kokoro.appending(path: name))
            }
        }
        return shareCompiledWeights(in: directory)
    }

    /// For the v3 runtime, which downloads its stages as source packages and
    /// compiles them on the device: makes each package's weights a clone of
    /// its compiled copy's, which holds the same bytes, so the two share
    /// their storage, about 190 MB. The packages can't simply be deleted:
    /// FluidAudio checks every downloaded file against its checksum each
    /// time the model loads, and downloads any that's missing again. Each
    /// file is replaced in one step, and only when the bytes match, so the
    /// package still passes the check. The package is replaced rather than
    /// the compiled copy, which the loaded model may be reading.
    /// - Returns: Whether every pair now shares its storage.
    nonisolated static func shareCompiledWeights(in directory: URL) -> Bool {
        var sharesAll = true
        for pair in weightPairs(in: directory) {
            guard let source = try? Data(contentsOf: pair.source, options: .alwaysMapped),
                  let compiled = try? Data(contentsOf: pair.compiled, options: .alwaysMapped),
                  source == compiled else {
                sharesAll = false
                continue
            }
            let clone = pair.source.deletingLastPathComponent().appending(path: "weight.bin.clone")
            try? FileManager.default.removeItem(at: clone)
            guard clonefile(pair.compiled.path, clone.path, 0) == 0 else {
                sharesAll = false
                continue
            }
            if rename(clone.path, pair.source.path) != 0 {
                try? FileManager.default.removeItem(at: clone)
                sharesAll = false
            }
        }
        return sharesAll
    }

    /// Each downloaded source package's weights with those of its compiled
    /// copy beside it.
    nonisolated static func weightPairs(in directory: URL) -> [(source: URL, compiled: URL)] {
        let packages = regularFiles(in: directory)
            .map(\.url)
            .filter { $0.lastPathComponent == "weight.bin" && $0.path.contains(".mlpackage/") }
        return packages.compactMap { source in
            var package = source
            while package.pathExtension != "mlpackage", package.pathComponents.count > 1 {
                package = package.deletingLastPathComponent()
            }
            let compiled = package.deletingPathExtension().appendingPathExtension("mlmodelc")
                .appending(path: "weights/weight.bin")
            guard FileManager.default.fileExists(atPath: compiled.path) else { return nil }
            return (source, compiled)
        }
    }

    /// Deletes the model's folder, the frontend's, and what Core ML compiled
    /// from them for the device's processors, which nothing else in the app
    /// uses enough to miss: the system would clear it in time anyway.
    @concurrent
    nonisolated static func deleteFiles(in directory: URL) async {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        if let frontend = try? frontendDirectory() {
            try? fileManager.removeItem(at: frontend)
        }
        if let bundleID = Bundle.main.bundleIdentifier {
            let compiled = URL.cachesDirectory
                .appending(path: bundleID)
                .appending(path: "com.apple.e5rt.e5bundlecache")
            try? fileManager.removeItem(at: compiled)
        }
    }

    nonisolated private static func regularFiles(in directory: URL) -> [(url: URL, size: Int64, allocated: Int64, modified: Date)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return []
        }
        var files: [(url: URL, size: Int64, allocated: Int64, modified: Date)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            files.append((url, size, Int64(values.totalFileAllocatedSize ?? Int(size)), values.contentModificationDate ?? .distantPast))
        }
        return files
    }
}

// MARK: - Waiting

/// `task`'s value, or `CancellationError` as soon as the calling task is
/// cancelled, which leaves `task` running for whoever waits next.
nonisolated func waitLeavingRunning<Success: Sendable, Failure: Error>(
    for task: Task<Success, Failure>
) async throws -> Success {
    let waiter = Waiter<Success>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            waiter.attach(continuation)
            Task {
                let result = await task.result
                waiter.finish(result.mapError { $0 as any Error })
            }
        }
    } onCancel: {
        waiter.finish(.failure(CancellationError()))
    }
}

/// Resumes one waiting continuation once, with whichever comes first: the
/// task's result or the waiter's cancellation.
nonisolated private final class Waiter<Success: Sendable>: Sendable {
    private struct Box: Sendable {
        var continuation: CheckedContinuation<Success, any Error>?
        var outcome: Result<Success, any Error>?
        var isFinished = false
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    func attach(_ continuation: CheckedContinuation<Success, any Error>) {
        let outcome = box.withLock { box -> Result<Success, any Error>? in
            guard box.isFinished else {
                box.continuation = continuation
                return nil
            }
            return box.outcome
        }
        if let outcome {
            continuation.resume(with: outcome)
        }
    }

    func finish(_ outcome: Result<Success, any Error>) {
        let continuation = box.withLock { box -> CheckedContinuation<Success, any Error>? in
            guard !box.isFinished else { return nil }
            box.isFinished = true
            box.outcome = outcome
            defer { box.continuation = nil }
            return box.continuation
        }
        continuation?.resume(with: outcome)
    }
}
