import Testing
@testable import Strobe

/// What the reader's Read Aloud button shows and does as the setting, the
/// document's language, and the voice model's download and load change.
struct ReadAloudAvailabilityTests {

    private typealias Availability = ReadAloudAvailability
    private typealias ModelState = ReadAloudAvailability.ModelState

    private static let allModelStates: [ModelState] = [
        .notInstalled, .downloading(fraction: 0.4), .downloading(fraction: nil),
        .installed, .preparing, .ready, .failed(message: "No connection"),
    ]

    private func availability(
        isEnabled: Bool = true,
        canReadDocument: Bool = true,
        model: ModelState,
        isReadingAloud: Bool = false,
        readerFailure: String? = nil
    ) -> Availability {
        Availability(
            isEnabled: isEnabled,
            canReadDocument: canReadDocument,
            model: model,
            isReadingAloud: isReadingAloud,
            readerFailure: readerFailure
        )
    }

    // MARK: - Off

    @Test func offShowsOffWhateverTheModel() {
        for model in Self.allModelStates {
            #expect(availability(isEnabled: false, model: model).status == .off, "\(model)")
        }
    }

    @Test func turningOnWithoutTheVoiceAsksToDownload() {
        #expect(availability(isEnabled: false, model: .notInstalled).tap == .offerDownload)
    }

    @Test func turningOnWithTheVoiceTurnsOn() {
        #expect(availability(isEnabled: false, model: .installed).tap == .turnOn)
        #expect(availability(isEnabled: false, model: .ready).tap == .turnOn)
        #expect(availability(isEnabled: false, model: .preparing).tap == .turnOn)
        // A download under way since read aloud turned off shows again.
        #expect(availability(isEnabled: false, model: .downloading(fraction: 0.4)).tap == .turnOn)
    }

    /// The download was agreed to before it failed.
    @Test func turningOnAfterAFailureTriesAgain() {
        #expect(availability(isEnabled: false, model: .failed(message: "No connection")).tap == .retry)
    }

    // MARK: - On, before a voice reads

    @Test func onWithoutTheVoiceAsksToDownload() {
        let notInstalled = availability(model: .notInstalled)
        #expect(notInstalled.status == .needsDownload)
        #expect(notInstalled.tap == .offerDownload)
    }

    @Test func downloadingShowsHowFar() {
        #expect(availability(model: .downloading(fraction: 0.4)).status == .downloading(fraction: 0.4))
        #expect(availability(model: .downloading(fraction: nil)).status == .downloading(fraction: nil))
    }

    /// Installed and loaded alike: until the reader has its voice, it's on
    /// its way.
    @Test func onTheWayToReadingIsPreparing() {
        #expect(availability(model: .installed).status == .preparing)
        #expect(availability(model: .preparing).status == .preparing)
        #expect(availability(model: .ready).status == .preparing)
    }

    /// Tapping while the voice downloads or loads turns reading aloud off;
    /// the download goes on.
    @Test func tappingOnTheWayTurnsOff() {
        #expect(availability(model: .downloading(fraction: 0.4)).tap == .turnOff)
        #expect(availability(model: .downloading(fraction: nil)).tap == .turnOff)
        #expect(availability(model: .preparing).tap == .turnOff)
        #expect(availability(model: .installed).tap == .turnOff)
    }

    // MARK: - Reading

    @Test func aVoiceReading() {
        let reading = availability(model: .ready, isReadingAloud: true)
        #expect(reading.status == .reading)
        #expect(reading.tap == .turnOff)
    }

    // MARK: - Failures

    @Test func aFailedDownloadOrLoadExplains() {
        let failed = availability(model: .failed(message: "No connection"))
        #expect(failed.status == .failed(message: "No connection"))
        #expect(failed.tap == .explainFailure(message: "No connection"))
    }

    /// The model loaded, but the reader couldn't get its voice.
    @Test func theReadersOwnFailureExplains() {
        let failed = availability(model: .ready, readerFailure: "The voice wouldn't load")
        #expect(failed.status == .failed(message: "The voice wouldn't load"))
        #expect(failed.tap == .explainFailure(message: "The voice wouldn't load"))
    }

    @Test func offHidesAFailure() {
        #expect(availability(isEnabled: false, model: .ready, readerFailure: "The voice wouldn't load").status == .off)
    }

    // MARK: - Documents not in English

    @Test func otherLanguagesAreExplainedWhateverTheSetting() {
        for isEnabled in [true, false] {
            for model in Self.allModelStates {
                let other = availability(isEnabled: isEnabled, canReadDocument: false, model: model)
                #expect(other.status == .englishOnly, "\(model)")
                #expect(other.tap == .explainEnglishOnly, "\(model)")
            }
        }
    }

    // MARK: - Model state

    @Test func onlyAModelOnDiskCanRead() {
        #expect(ModelState.installed.isOnDisk)
        #expect(ModelState.preparing.isOnDisk)
        #expect(ModelState.ready.isOnDisk)
        #expect(!ModelState.notInstalled.isOnDisk)
        #expect(!ModelState.downloading(fraction: 0.99).isOnDisk)
        // A failed load waits for Try Again.
        #expect(!ModelState.failed(message: "No connection").isOnDisk)
    }
}
