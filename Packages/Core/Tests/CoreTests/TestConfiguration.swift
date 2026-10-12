@testable import Core

extension RetrievalConfiguration {
    /// The scale of the stand-in distances these tests script (`FakeChunkSearch` hits between 0.2 and 0.95). The shipped
    /// default is tuned to the real model, whose distances sit far lower (see `RetrievalConfiguration.maxDistance`).
    static let standIn = RetrievalConfiguration(maxDistance: 0.76, textToImageMaxDistance: 0.25)
}
