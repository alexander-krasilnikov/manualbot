import Foundation
import Ports

/// Word-based estimate, used until the embedding model's own tokenizer is wired in.
public struct ApproximateTokenCounter: TokenCounting {
    public init() {}

    public func count(_ text: String) -> Int {
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { _, _, _, _ in words += 1 }
        return max(1, Int((Double(words) * 1.35).rounded(.up)))
    }
}

public struct ChunkDraft: Sendable, Equatable {
    public var ordinal: Int
    public var page: Int?
    public var heading: String?
    public var text: String
    /// Set on the chunk that stands for an image.
    public var imageId: String?
}

public struct ChunkerConfiguration: Sendable, Equatable, Codable {
    /// Aim for chunks of about this many tokens.
    public var targetTokens: Int
    /// No chunk may exceed this (the embedding model's input limit).
    public var maxTokens: Int
    /// Tokens repeated from the end of one chunk at the start of the next (within a page).
    public var overlapTokens: Int
    /// A trailing chunk with fewer new tokens than this is merged into the previous chunk.
    public var minTailTokens: Int

    public init(targetTokens: Int = 350, maxTokens: Int = 480, overlapTokens: Int = 52, minTailTokens: Int = 70) {
        self.targetTokens = targetTokens
        self.maxTokens = maxTokens
        self.overlapTokens = overlapTokens
        self.minTailTokens = minTailTokens
    }
}

extension ChunkerConfiguration {
    /// Sizes for EmbeddingGemma 2, which takes up to 512 tokens (`LiteRTEmbedder`). Chosen on the evaluation documents
    /// (`RealEvalTests.comparesChunkSizes`, recall@6 was 100% at every size): the shorter the chunk, the wider the gap
    /// between the worst answerable question and the nearest off-topic one, because a long chunk dilutes the sentence
    /// that answers. Gap by target size: 80 → 0.080, 100 → 0.080, 130 → 0.083, 150 → 0.065, 180 → 0.024, 220 → 0.029,
    /// 300 → 0.029, 400 → 0.029. 130 tokens keeps the room of the smaller sizes and still gives the language model whole
    /// paragraphs. The counter is approximate (the runtime has no token count) and over-counts English prose by about 6%,
    /// so a 180-token chunk is about 170 real tokens, far inside the 512-token input even with the template and title.
    /// Text full of codes can use more; the embedder then shortens that chunk instead of failing.
    public static let embeddingGemma2 = ChunkerConfiguration(targetTokens: 130, maxTokens: 180, overlapTokens: 22, minTailTokens: 35)
}

extension ChunkerConfiguration {
    /// Sizes for an embedding model whose text input is `limit` tokens, used when nothing was tuned for it. The 512-token
    /// sizes are EmbeddingGemma 2's; shorter inputs get proportionally shorter chunks.
    public static func sized(forInputLength limit: Int) -> ChunkerConfiguration {
        switch limit {
        case 512...: .embeddingGemma2
        case 256...: ChunkerConfiguration(targetTokens: 80, maxTokens: 120, overlapTokens: 15, minTailTokens: 25)
        default: ChunkerConfiguration(targetTokens: 40, maxTokens: 60, overlapTokens: 8, minTailTokens: 12)
        }
    }
}

/// Splits extracted blocks into overlapping chunks. Splits on sentence boundaries, never
/// crosses a page, and carries the nearest heading along as provenance.
public struct Chunker: Sendable {
    public let configuration: ChunkerConfiguration
    private let counter: any TokenCounting

    public init(configuration: ChunkerConfiguration = .init(), counter: any TokenCounting = ApproximateTokenCounter()) {
        self.configuration = configuration
        self.counter = counter
    }

    private struct Unit {
        var text: String
        var tokens: Int
        var heading: String?
        var isHeading: Bool
    }

    private struct Pending {
        var units: [Unit] = []
        var overlapCount = 0   // leading units repeated from the previous chunk
        var tokens: Int { units.reduce(0) { $0 + $1.tokens } }
        var newTokens: Int { units.dropFirst(overlapCount).reduce(0) { $0 + $1.tokens } }
        var hasNew: Bool { units.count > overlapCount }
    }

    public func chunk(_ blocks: [Block]) -> [ChunkDraft] {
        var drafts: [ChunkDraft] = []
        for segment in segments(of: blocks) {
            drafts += chunkSegment(segment.blocks, page: segment.page, startingAt: drafts.count)
        }
        return drafts
    }

    // MARK: Segments (one per page; page-less sources form a single segment)

    private func segments(of blocks: [Block]) -> [(page: Int?, blocks: [Block])] {
        var result: [(page: Int?, blocks: [Block])] = []
        for block in blocks where !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let last = result.last, last.page == block.page {
                result[result.count - 1].blocks.append(block)
            } else {
                result.append((block.page, [block]))
            }
        }
        return result
    }

    // MARK: Chunking within a segment

    private func chunkSegment(_ blocks: [Block], page: Int?, startingAt start: Int) -> [ChunkDraft] {
        let units = blocks.flatMap(units(from:))
        var drafts: [ChunkDraft] = []
        var current = Pending()

        func emit(_ pending: Pending) {
            let text = pending.units.map(\.text).joined(separator: " ")
            let heading = pending.units.dropFirst(pending.overlapCount).first?.heading ?? pending.units.first?.heading
            drafts.append(ChunkDraft(ordinal: start + drafts.count, page: page, heading: heading, text: text))
        }

        for unit in units {
            // A new heading starts a new chunk once the current one has some substance.
            if unit.isHeading, current.hasNew, current.newTokens >= configuration.targetTokens / 3 {
                emit(current)
                current = Pending()
            }
            if current.hasNew, current.tokens + unit.tokens > configuration.targetTokens {
                emit(current)
                current = startNext(after: current, incoming: unit)
            }
            current.units.append(unit)
        }
        if current.hasNew {
            if current.newTokens < configuration.minTailTokens, !drafts.isEmpty, merge(tail: current, into: &drafts) {
                // merged
            } else {
                emit(current)
            }
        }
        return drafts
    }

    /// The next chunk begins with the trailing sentences of the previous one, within the overlap budget.
    private func startNext(after previous: Pending, incoming: Unit) -> Pending {
        var overlap: [Unit] = []
        var budget = configuration.overlapTokens
        for unit in previous.units.reversed() where !unit.isHeading {
            guard unit.tokens <= budget, unit.tokens + incoming.tokens <= configuration.maxTokens else { break }
            overlap.insert(unit, at: 0)
            budget -= unit.tokens
        }
        return Pending(units: overlap, overlapCount: overlap.count)
    }

    private func merge(tail: Pending, into drafts: inout [ChunkDraft]) -> Bool {
        let addition = tail.units.dropFirst(tail.overlapCount).map(\.text).joined(separator: " ")
        let merged = drafts[drafts.count - 1].text + " " + addition
        guard counter.count(merged) <= configuration.maxTokens else { return false }
        drafts[drafts.count - 1].text = merged
        return true
    }

    // MARK: Units (sentences, hard-split when a sentence alone is too long)

    private func units(from block: Block) -> [Unit] {
        let isHeading = block.kind == .heading
        let heading = isHeading ? block.text.trimmingCharacters(in: .whitespacesAndNewlines) : block.heading
        var sentences: [String] = []
        if isHeading || block.kind == .table {
            sentences = [block.text]
        } else {
            block.text.enumerateSubstrings(in: block.text.startIndex..., options: .bySentences) { s, _, _, _ in
                if let s { sentences.append(s) }
            }
            if sentences.isEmpty { sentences = [block.text] }
        }
        return sentences
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .flatMap(splitIfTooLong)
            .map { Unit(text: $0, tokens: counter.count($0), heading: heading, isHeading: isHeading) }
    }

    private func splitIfTooLong(_ sentence: String) -> [String] {
        guard counter.count(sentence) > configuration.maxTokens else { return [sentence] }
        var pieces: [String] = []
        var line: [Substring] = []
        for word in sentence.split(separator: " ", omittingEmptySubsequences: true) {
            line.append(word)
            if counter.count(line.joined(separator: " ")) >= configuration.targetTokens {
                pieces.append(line.joined(separator: " "))
                line = []
            }
        }
        if !line.isEmpty { pieces.append(line.joined(separator: " ")) }
        return pieces
    }
}
