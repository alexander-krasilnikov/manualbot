import Foundation
import Ports

/// What sync should be doing right now.
public enum SyncDecision: Sendable, Equatable {
    case off
    case run
    case pause(SyncPauseReason)
}

/// Decides whether the replicator runs. Every iPad that shares a library uses one embedding model, the fleet model:
/// vectors from another model are useless to the others, and chunk and image IDs do not say which model made them, so
/// a device on another model could overwrite the shared ones. Sync therefore pauses while the model in use is another
/// one, and, after the fleet model is back in use, until every document holds vectors of the fleet model again: what a
/// device re-indexed while it was away (new generations, and removals of the fleet's chunks) must not be sent.
public enum SyncPolicy {
    /// The model every iPad shares: the app's default embedder.
    public static let fleetModel = EmbedderProfile.embeddingGemma2.identity
    /// How the fleet model is named to the user.
    public static let fleetModelName = "EmbeddingGemma 2"

    /// - Parameters:
    ///   - enabled: the user turned sync on.
    ///   - activeModel: the embedding model in use, and `activeModelName` how it is named to the user.
    ///   - outdatedDocuments: how many searchable documents hold vectors from a model other than the active one
    ///     (`IngestionService.outdatedDocuments(for:)`), which is how many are still to be re-indexed after a switch.
    ///   - fleet: the model every iPad shares; the app's default, which only tests and stand-ins change.
    public static func decide(
        enabled: Bool, activeModel: EmbeddingModelIdentity, activeModelName: String, outdatedDocuments: Int,
        fleet: EmbeddingModelIdentity = SyncPolicy.fleetModel, fleetName: String = SyncPolicy.fleetModelName
    ) -> SyncDecision {
        guard enabled else { return .off }
        guard activeModel == fleet else {
            return .pause(.otherEmbedder(active: activeModelName, fleet: fleetName))
        }
        guard outdatedDocuments == 0 else {
            return .pause(.reindexing(remaining: outdatedDocuments, fleet: fleetName))
        }
        return .run
    }
}
