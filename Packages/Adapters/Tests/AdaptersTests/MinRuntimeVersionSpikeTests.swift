import Foundation
import LiteRTLM
import Testing

/// Spike for `add-model-settings` task 3.4: can the minimum LiteRT-LM runtime version be read from the file?
/// Run with `RUN_SPIKES=1 GENERATOR_MODEL_PATH=… EMBEDDER_MODEL_PATH=… swift test --filter MinRuntimeVersionSpikeTests`.
/// Result: recorded in design D5 of the change.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RUN_SPIKES"] == "1"))
struct MinRuntimeVersionSpikeTests {
    @Test func minimumRuntimeVersionOfTheLocalFiles() {
        let env = ProcessInfo.processInfo.environment
        for key in ["GENERATOR_MODEL_PATH", "EMBEDDER_MODEL_PATH"] {
            guard let path = env[key], let info = ModelInfo(modelPath: path) else {
                Issue.record("\(key) is not readable")
                continue
            }
            print("SPIKE \(key) minRuntimeVersion=\(info.minRuntimeVersion ?? "nil") type=\(info.modelType()) "
                  + "maxContextTokens=\(info.maxContextTokens()) vision=\(info.inputModalities.vision)")
        }
    }
}
