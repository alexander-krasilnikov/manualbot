import Core
import Foundation

/// The embedder profile the real-model evaluations use: EmbeddingGemma 2's, or the one in the JSON file that
/// `EMBEDDER_PROFILE_PATH` names. Point it at another profile to evaluate another prompt set, another model, or both
/// (with `EMBEDDER_MODEL_PATH` at that model's file). `EvalTests` and `ImageEvalTests` read it.
enum EvalProfile {
    static var current: EmbedderProfile {
        guard let path = ProcessInfo.processInfo.environment["EMBEDDER_PROFILE_PATH"] else { return .embeddingGemma2 }
        do {
            return try JSONDecoder().decode(EmbedderProfile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            fatalError("EMBEDDER_PROFILE_PATH \(path) is not an embedder profile: \(error)")
        }
    }
}
