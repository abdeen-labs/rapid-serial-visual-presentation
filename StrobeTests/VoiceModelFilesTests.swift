import Foundation
import Testing
@testable import Strobe

/// What the voice model keeps on disk: the record of a finished install and
/// the model's commit it holds, the voice packs it's missing, what a
/// download that didn't finish left, and how a failed download is told.
struct VoiceModelFilesTests {

    private typealias Installation = KokoroVoiceModel.Installation

    /// A folder of its own, made empty.
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "VoiceModelFilesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Installed.json

    /// What the first builds wrote, with no commit: they all downloaded the
    /// first one pinned.
    @Test func anInstallFromBeforeRevisionsCameFromTheFirstPin() throws {
        let data = Data(#"{"sharesCompiledWeights":true}"#.utf8)
        let installation = try JSONDecoder().decode(Installation.self, from: data)
        #expect(installation.sharesCompiledWeights)
        #expect(installation.modelRevision == KokoroVoiceModel.firstModelRevision)
    }

    /// Written out rather than taken from the current pin, so moving the
    /// pin on still updates those installs.
    @Test func theFirstPinStaysPut() {
        #expect(KokoroVoiceModel.firstModelRevision == "e61d9ee79a01ad4ebf6b3d8bcfe2a03f6b8da105")
    }

    @Test func aNewInstallRecordsThisBuildsCommit() throws {
        let data = try JSONEncoder().encode(Installation(sharesCompiledWeights: false))
        let installation = try JSONDecoder().decode(Installation.self, from: data)
        #expect(installation == Installation(sharesCompiledWeights: false, modelRevision: KokoroVoiceModel.modelRevision))
        #expect(installation.isCurrent)
    }

    @Test func anInstallFromAnotherCommitIsOutdated() throws {
        let data = Data(#"{"sharesCompiledWeights":true,"modelRevision":"0123456789abcdef0123456789abcdef01234567"}"#.utf8)
        let installation = try JSONDecoder().decode(Installation.self, from: data)
        #expect(!installation.isCurrent)
    }

    @Test func theRecordIsKeptInTheModelsFolder() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(KokoroVoiceModel.installation(in: folder) == nil)

        try KokoroVoiceModel.writeInstallation(Installation(sharesCompiledWeights: true), in: folder)
        #expect(KokoroVoiceModel.installation(in: folder) == Installation(sharesCompiledWeights: true))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: KokoroVoiceModel.installationFileName).path))
    }

    // MARK: - Voice packs

    @Test func anEmptyFolderMissesEveryPack() throws {
        let repository = try makeFolder()
        defer { try? FileManager.default.removeItem(at: repository) }
        #expect(KokoroVoiceModel.missingVoicePacks(in: repository) == KokoroVoices.all.map(\.id))
    }

    /// As when a build offers voices the install didn't download.
    @Test func onlyPacksNotOnDiskAreMissing() throws {
        let repository = try makeFolder()
        defer { try? FileManager.default.removeItem(at: repository) }
        let onDisk = KokoroVoices.all.dropLast(2)
        for voice in onDisk {
            try Data(count: 16).write(to: repository.appending(path: "\(voice.id).bin"))
        }
        #expect(KokoroVoiceModel.missingVoicePacks(in: repository) == KokoroVoices.all.suffix(2).map(\.id))
    }

    /// FluidAudio keeps the stages and packs a level down, in the
    /// repository's own folders.
    @Test func packsAreInTheRepositoryFolder() {
        let folder = URL(filePath: "/Voices", directoryHint: .isDirectory)
        #expect(KokoroVoiceModel.repositoryDirectory(in: folder).path == "/Voices/kokoro-82m-coreml/ANE")
    }

    // MARK: - Unfinished downloads

    /// Nothing to remove, and nothing made by looking.
    @Test func noDownloadLeavesNothing() async {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "VoiceModelFilesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        #expect(await KokoroVoiceModel.unfinishedDownloadSize(in: folder) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func whatADownloadLeftCanBeRemoved() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let stage = KokoroVoiceModel.repositoryDirectory(in: folder).appending(path: "KokoroAlbert.mlmodelc/weights")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data((0..<100_000).map { UInt8($0 % 251) }).write(to: stage.appending(path: "weight.bin"))

        let size = try #require(await KokoroVoiceModel.unfinishedDownloadSize(in: folder))
        #expect(size >= 100_000)
    }

    // MARK: - Failures

    @Test func aFailedDownloadSaysToCheckTheConnection() {
        let message = KokoroVoiceModel.ModelError.downloadFailed.localizedDescription
        for error in [URLError(.notConnectedToInternet), URLError(.timedOut), URLError(.networkConnectionLost)] {
            #expect(KokoroVoiceModel.isDownloadFailure(error), "\(error.code)")
            #expect(KokoroVoiceModel.failureMessage(for: error) == message)
        }
        #expect(message.contains("internet connection"))
    }

    @Test func otherFailuresKeepTheirOwnWords() {
        let error = KokoroVoiceModel.ModelError.notInstalled
        #expect(!KokoroVoiceModel.isDownloadFailure(error))
        #expect(KokoroVoiceModel.failureMessage(for: error) == error.localizedDescription)
        #expect(!KokoroVoiceModel.isDownloadFailure(CancellationError()))
    }
}
