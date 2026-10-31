import CoreML
import Foundation
import Testing
@testable import Strobe

/// Where the voice reads on with the app in the background: iOS refuses an
/// app GPU work there, so only where none of the model's stages run on it.
struct ReadAloudBackgroundTests {

    @Test func aStageOnTheGPUKeepsTheVoiceOutOfTheBackground() {
        #expect(!KokoroVoiceModel.runsInBackground([.cpuAndNeuralEngine, .cpuAndGPU, .cpuOnly]))
        // Core ML can put any stage on the GPU.
        #expect(!KokoroVoiceModel.runsInBackground([.cpuAndNeuralEngine, .all]))
    }

    @Test func theCPUAndTheNeuralEngineRunInTheBackground() {
        #expect(KokoroVoiceModel.runsInBackground([.cpuAndNeuralEngine, .cpuOnly, .cpuAndNeuralEngine]))
    }

    /// FluidAudio moves its last two stages off the GPU from iOS 27 on, and
    /// the Mac doesn't keep apps in the background from it.
    @Test func theVoiceReadsInTheBackgroundFromiOS27On() {
        #if os(iOS)
        if #available(iOS 27.0, *) {
            #expect(KokoroVoiceModel.rendersInBackground)
        } else {
            #expect(!KokoroVoiceModel.rendersInBackground)
        }
        #else
        #expect(KokoroVoiceModel.rendersInBackground)
        #endif
    }
}
