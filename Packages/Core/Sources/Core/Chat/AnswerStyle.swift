import Foundation

/// How readily the app answers, set with one slider in Settings. The slider is a distance offset from the embedding
/// model's tuned relevance distance; the named stop follows from where the offset falls, so the two can never disagree.
/// The offset (not the absolute distance) is what is stored, so another embedding model's scale keeps the same meaning.
public struct AnswerStyle: Sendable, Equatable, Hashable {
    public enum Stop: String, Sendable, CaseIterable {
        /// A tighter cutoff; questions the documents do not answer get the not-found reply.
        case strict
        /// The tuned cutoff, give or take; the not-found reply as before the setting existed.
        case balanced
        /// A looser cutoff; questions the documents do not answer get a short reply that is not from them.
        case conversational
        /// The loosest cutoff; questions the documents do not answer get an answer from general knowledge.
        case open

        /// Offsets in hundredths, inclusive at both ends. Every step of `range` belongs to exactly one stop.
        public var steps: ClosedRange<Int> {
            switch self {
            case .strict: -6 ... -3
            case .balanced: -2...2
            case .conversational: 3...6
            case .open: 7...10
            }
        }

        public var name: String {
            switch self {
            case .strict: "Strict"
            case .balanced: "Balanced"
            case .conversational: "Conversational"
            case .open: "Open"
            }
        }

        /// Whether a question the documents do not answer gets a reply from the model instead of the not-found reply.
        public var repliesWithoutDocuments: Bool { self == .conversational || self == .open }
    }

    /// The slider's whole range, as an offset from the tuned distance.
    public static let range: ClosedRange<Double> = -0.06...0.10
    public static let step = 0.01
    /// Today's behaviour: the tuned distance, and the not-found reply.
    public static let balanced = AnswerStyle(offset: 0)

    /// Clamped to `range` and rounded to `step`.
    public let offset: Double

    public init(offset: Double) {
        let hundredths = (offset * 100).rounded()
        self.offset = min(max(hundredths / 100, Self.range.lowerBound), Self.range.upperBound)
    }

    public var stop: Stop {
        let step = Int((offset * 100).rounded())
        return Stop.allCases.first { $0.steps.contains(step) } ?? .balanced
    }

    /// The relevance cutoff for typed questions, given the embedding model's tuned distance.
    public func maxDistance(tuned: Double) -> Double {
        ((tuned + offset) * 100).rounded() / 100
    }
}
