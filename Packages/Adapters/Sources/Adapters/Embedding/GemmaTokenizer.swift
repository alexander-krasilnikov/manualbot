import Foundation
import Ports
import Tokenizers

/// EmbeddingGemma's SentencePiece tokenizer, loaded from the model's `tokenizer.json`.
public final class GemmaTokenizer: @unchecked Sendable, TokenCounting {
    static let bos = 2, eos = 1, pad = 0

    private let tokenizer: any Tokenizer

    /// - Parameter folder: a directory containing `tokenizer.json` and `tokenizer_config.json`.
    public init(folder: URL) async throws {
        tokenizer = try await AutoTokenizer.from(modelFolder: folder)
    }

    /// Token IDs including `<bos>` and `<eos>`, cut to `limit` with the final `<eos>` kept.
    func encode(_ text: String, limit: Int) -> [Int] {
        let ids = tokenizer.encode(text: text)
        guard ids.count > limit else { return ids }
        return Array(ids.prefix(limit - 1)) + [Self.eos]
    }

    /// Tokens the model will see for `text` (without the two special tokens the model adds itself).
    public func count(_ text: String) -> Int {
        max(1, tokenizer.encode(text: text).count - 2)
    }
}
