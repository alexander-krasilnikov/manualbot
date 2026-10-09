import Foundation
import Ports
import Testing
@testable import Core

@Suite struct SyncPolicyTests {
    private let fleet = SyncPolicy.fleetModel
    private let other = EmbeddingModelIdentity(id: "other-embedder", version: "1", dimensions: 768)

    private func decide(
        enabled: Bool = true, active: EmbeddingModelIdentity? = nil, name: String = "EmbeddingGemma 2", outdated: Int = 0
    ) -> SyncDecision {
        SyncPolicy.decide(enabled: enabled, activeModel: active ?? fleet, activeModelName: name, outdatedDocuments: outdated)
    }

    @Test func theFleetModelIsTheAppsDefaultEmbedder() {
        #expect(SyncPolicy.fleetModel == EmbedderProfile.embeddingGemma2.identity)
    }

    @Test func fleetModelWithNothingToRedoRuns() {
        #expect(decide() == .run)
    }

    @Test func anotherEmbedderPausesAndNamesBothModels() {
        #expect(decide(active: other, name: "Other 768") == .pause(.otherEmbedder(active: "Other 768", fleet: "EmbeddingGemma 2")))
    }

    @Test func theFleetModelWithDocumentsStillToReindexStaysPaused() {
        #expect(decide(outdated: 3) == .pause(.reindexing(remaining: 3, fleet: "EmbeddingGemma 2")))
    }

    @Test func syncResumesWhenTheLastDocumentIsReindexed() {
        #expect(decide(outdated: 1) != .run)
        #expect(decide(outdated: 0) == .run)
    }

    @Test func theModelInUseDecidesBeforeTheOutdatedCount() {
        // Every document is outdated the moment another model is chosen; the reason is the model, not the count.
        #expect(decide(active: other, name: "Other 768", outdated: 12) == .pause(.otherEmbedder(active: "Other 768", fleet: "EmbeddingGemma 2")))
    }

    @Test func aDisabledSyncIsOffWhateverTheModel() {
        #expect(decide(enabled: false) == .off)
        #expect(decide(enabled: false, active: other, name: "Other 768", outdated: 5) == .off)
    }

    @Test func aModelOfTheSameNameButAnotherVersionIsNotTheFleetModel() {
        let newer = EmbeddingModelIdentity(id: fleet.id, version: "2", dimensions: fleet.dimensions)
        #expect(decide(active: newer) == .pause(.otherEmbedder(active: "EmbeddingGemma 2", fleet: "EmbeddingGemma 2")))
    }
}
