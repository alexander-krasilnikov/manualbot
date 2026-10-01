import Foundation
import Ports

/// Reciprocal Rank Fusion: each list contributes 1 / (k + rank) for every item it contains, so an item
/// found by several lists outranks one found by a single list at a comparable position.
public enum RankFusion {
    public struct Fused: Equatable {
        public var id: String
        public var score: Double
        /// Zero-based position in each input list, `nil` where the list did not contain the item.
        public var ranks: [Int?]
    }

    public static func fuse(_ lists: [[String]], k: Double = 60, limit: Int) -> [Fused] {
        var scores: [String: Double] = [:]
        var ranks: [String: [Int?]] = [:]
        for (listIndex, list) in lists.enumerated() {
            var seen = Set<String>()
            for (position, id) in list.enumerated() where seen.insert(id).inserted {
                scores[id, default: 0] += 1 / (k + Double(position + 1))
                var r = ranks[id] ?? Array(repeating: nil, count: lists.count)
                r[listIndex] = position
                ranks[id] = r
            }
        }
        return scores
            .map { Fused(id: $0.key, score: $0.value, ranks: ranks[$0.key]!) }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                let (ra, rb) = (a.ranks.compactMap { $0 }.min() ?? .max, b.ranks.compactMap { $0 }.min() ?? .max)
                if ra != rb { return ra < rb }
                // Still tied: prefer the item the earlier list (the semantic one) found, then id, so order is stable.
                let (la, lb) = (a.ranks.firstIndex { $0 != nil } ?? .max, b.ranks.firstIndex { $0 != nil } ?? .max)
                return la != lb ? la < lb : a.id < b.id
            }
            .prefix(limit)
            .map { $0 }
    }
}
