import Core
import Foundation
import Observation

/// The answer style chosen on the Answer style page: how readily the app answers, and what it says when the documents do
/// not. Remembered across launches as an offset from the embedding model's tuned distance, so it keeps its meaning when
/// the embedding model changes. Balanced at the tuned distance until the user moves the slider.
@MainActor @Observable
final class AnswerSettings {
    var offset: Double { didSet { defaults.set(offset, forKey: Keys.offset) } }
    /// The embedding model's tuned relevance distance, which the offset is relative to. Set when the library opens.
    var tunedDistance: Double = RetrievalConfiguration().maxDistance

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let offset = "answers.offset"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        offset = AnswerStyle(offset: defaults.double(forKey: Keys.offset)).offset
    }

    var style: AnswerStyle { AnswerStyle(offset: offset) }
    var distance: Double { style.maxDistance(tuned: tunedDistance) }

    func reset() { offset = AnswerStyle.balanced.offset }
}
