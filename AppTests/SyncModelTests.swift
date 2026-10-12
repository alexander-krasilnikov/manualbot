import Core
import Foundation
import Ports
import PortsTesting
import Testing
@testable import ManualBot

/// Running sync under the user's settings and the fleet-model rule (library-sync spec), on a scripted replicator.
@MainActor @Suite struct SyncModelTests {
    private let fleet = EmbeddingModelIdentity(id: "fleet", version: "1", dimensions: 32)
    private let other = EmbeddingModelIdentity(id: "other", version: "1", dimensions: 32)

    private struct Rig {
        let model: SyncModel
        let sync: ScriptedLibrarySync
        let repo: InMemoryDocumentRepository
        let ingestion: IngestionService
    }

    private func settings(enabled: Bool = true, address: String = "localhost:4984", username: String = "ipad1") -> SyncSettings {
        let name = "sync-model-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = SyncSettings(defaults: defaults, secrets: InMemorySecretStore())
        settings.address = address
        settings.username = username
        settings.password = "pw"
        settings.isEnabled = enabled
        return settings
    }

    private let chunker = Chunker(configuration: ChunkerConfiguration(targetTokens: 40, maxTokens: 70, overlapTokens: 10, minTailTokens: 15))

    private func text(_ tag: String) -> ExtractedDocument {
        ExtractedDocument(
            blocks: [Block(text: (0..<10).map { "\(tag)\($0) " + (0..<8).map { "w\($0)" }.joined(separator: " ") + "." }.joined(separator: " "), page: 1)],
            pageCount: 1)
    }

    private func service(_ repo: InMemoryDocumentRepository, model: EmbeddingModelIdentity, extractor: FakeExtractor) -> IngestionService {
        IngestionService(
            extractor: extractor, embedder: FakeEmbedder(identity: model), repository: repo, jobs: repo, chunker: chunker,
            batchSize: 4, supportedType: { ["txt": DocumentType.text][$0.pathExtension.lowercased()] })
    }

    /// A library on the embedding model `active`, with `outdated` documents that were indexed with another model.
    private func attach(
        active: EmbeddingModelIdentity? = nil, outdated: Int = 0, settings: SyncSettings? = nil, sync: ScriptedLibrarySync = ScriptedLibrarySync()
    ) async throws -> Rig {
        let repo = InMemoryDocumentRepository()
        let embedding = active ?? fleet
        let names = (0..<outdated).map { "doc\($0).txt" }
        let extractor = FakeExtractor(results: Dictionary(uniqueKeysWithValues: names.map { ($0, .success(text($0))) }))
        if outdated > 0 {
            let before = service(repo, model: other, extractor: extractor)
            for name in names { try await before.enqueue(fileURL: URL(fileURLWithPath: "/in/\(name)")) }
            await before.run()
        }
        let ingestion = service(repo, model: embedding, extractor: extractor)
        let model = SyncModel(settings: settings ?? self.settings())
        await model.attach(SyncModel.Library(
            sync: sync, ingestion: ingestion, embedding: embedding, embeddingName: embedding.id == fleet.id ? "Fleet Model" : "Other Model",
            fleet: FleetModel(identity: fleet, name: "Fleet Model")))
        return Rig(model: model, sync: sync, repo: repo, ingestion: ingestion)
    }

    @Test func syncStaysOffUntilTheUserTurnsItOn() async throws {
        let rig = try await attach(settings: settings(enabled: false))
        #expect(rig.model.state == .off)
        #expect(await rig.sync.configurations.isEmpty)
    }

    @Test func turnedOnOnTheFleetModelItStartsWithTheUsersServerAndAccount() async throws {
        let rig = try await attach()
        #expect(await eventually { rig.model.state == .upToDate })
        let configuration = try #require(await rig.sync.configurations.first)
        #expect(configuration.endpoint.absoluteString == "ws://localhost:4984/manualbot")
        #expect(configuration.username == "ipad1" && configuration.password == "pw")
    }

    @Test func theStateFollowsWhatTheReplicatorReports() async throws {
        let rig = try await attach(sync: ScriptedLibrarySync(onStart: [.connecting, .syncing]))
        #expect(await eventually { rig.model.state == .syncing })
        await rig.sync.emit(.upToDate, sent: 3, received: 5)
        #expect(await eventually { rig.model.state == .upToDate })
        #expect(rig.model.status.sent == 3 && rig.model.status.received == 5 && rig.model.status.lastSync != nil)
        await rig.sync.emit(.error(.unreachable))
        #expect(await eventually { rig.model.state == .error(.unreachable) })
    }

    @Test func withoutAnAddressTheStateSaysWhatIsMissingAndNothingStarts() async throws {
        let rig = try await attach(settings: settings(address: ""))
        guard case .error(.other(let message)) = rig.model.state else { Issue.record("expected an error, got \(rig.model.state)"); return }
        #expect(message.contains("server address"))
        #expect(await rig.sync.configurations.isEmpty)
    }

    @Test func anotherEmbedderPausesSyncAndNamesBothModels() async throws {
        let rig = try await attach(active: other)
        #expect(rig.model.state == .paused(.otherEmbedder(active: "Other Model", fleet: "Fleet Model")))
        #expect(await rig.sync.configurations.isEmpty, "nothing is sent or received")
    }

    @Test func documentsStillToReindexKeepSyncPausedAndTheLastOneEndsIt() async throws {
        let rig = try await attach(outdated: 2)
        #expect(rig.model.state == .paused(.reindexing(remaining: 2, fleet: "Fleet Model")))
        #expect(await rig.sync.configurations.isEmpty, "nothing is sent while documents hold the other model's vectors")

        // As after a switch back to the fleet model: the documents are queued, and indexed one by one.
        #expect(try await rig.ingestion.reindexOutdated(for: fleet) == 2)
        await rig.ingestion.run()

        #expect(await eventually { rig.model.state == .upToDate }, "the last document ended the pause on its own: \(rig.model.state)")
        #expect(await rig.sync.configurations.count == 1)
        #expect(try await rig.ingestion.outdatedDocuments(for: fleet).isEmpty)
    }

    @Test func turningSyncOffStopsItAndOnStartsItAgain() async throws {
        let settings = settings()
        let rig = try await attach(settings: settings)
        #expect(await eventually { rig.model.state == .upToDate })

        settings.isEnabled = false
        await rig.model.apply()
        #expect(rig.model.state == .off)
        #expect(await rig.sync.stopCount == 1)

        settings.isEnabled = true
        await rig.model.apply()
        #expect(await rig.sync.configurations.count == 2)
    }

    @Test func aChangedServerRestartsTheReplicatorAndNothingElseDoes() async throws {
        let settings = settings()
        let rig = try await attach(settings: settings)
        await rig.model.apply()
        await rig.model.apply()
        #expect(await rig.sync.configurations.count == 1, "applying the same settings does not restart it")

        settings.address = "192.168.1.20:4984"
        await rig.model.apply()
        #expect(await rig.sync.configurations.count == 2)
        #expect(await rig.sync.configurations.last?.endpoint.absoluteString == "ws://192.168.1.20:4984/manualbot")

        await rig.model.apply(restart: true)
        #expect(await rig.sync.configurations.count == 3, "asking to restart restarts it")
    }

    @Test func editingTheServerRestartsTheReplicatorOnlyOnceTheEditingHasStopped() async throws {
        let settings = settings()
        let rig = try await attach(settings: settings)
        #expect(await rig.sync.configurations.count == 1)

        // An address typed letter by letter: no restart per letter.
        for address in ["1", "19", "192.168.1.2", "192.168.1.20:4984"] {
            settings.address = address
            rig.model.settingsEdited(after: .milliseconds(150))
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(await rig.sync.configurations.count == 1, "still typing")
        #expect(await eventually { await rig.sync.configurations.count == 2 })
        #expect(await rig.sync.configurations.last?.endpoint.absoluteString == "ws://192.168.1.20:4984/manualbot")
    }

    @Test func newCredentialsAfterARefusalAreTriedWithoutTurningSyncOffAndOn() async throws {
        let settings = settings()
        let rig = try await attach(settings: settings, sync: ScriptedLibrarySync(onStart: [.connecting, .error(.credentialsRefused)]))
        #expect(await eventually { rig.model.state == .error(.credentialsRefused) })

        settings.password = "the-right-one"
        rig.model.settingsEdited(after: .milliseconds(50))
        #expect(await eventually { await rig.sync.configurations.count == 2 }, "sync starts again by itself")
        #expect(await rig.sync.configurations.last?.password == "the-right-one")
    }

    @Test func detachingStopsTheReplicatorBeforeTheLibraryCloses() async throws {
        let rig = try await attach()
        #expect(await eventually { rig.model.state == .upToDate })
        await rig.model.detach()
        #expect(await rig.sync.stopCount == 1)
        #expect(rig.model.state != .upToDate)
    }

    @Test func theLibraryIsToldWhenDocumentsMove() async throws {
        let rig = try await attach(sync: ScriptedLibrarySync(onStart: [.syncing]))
        var told = 0
        rig.model.onActivity = { told += 1 }
        #expect(await eventually { rig.model.state == .syncing })
        let before = told
        await rig.sync.emit(.syncing, received: 4)
        #expect(await eventually { told > before })
    }

    @Test func documentsThatAreTooLargeAreListed() async throws {
        let large = UnsharedDocument(id: "d1", title: "Big manual", bytes: 35 * 1024 * 1024)
        let rig = try await attach(sync: ScriptedLibrarySync(unshared: [large]))
        #expect(rig.model.unshared == [large])
    }
}
