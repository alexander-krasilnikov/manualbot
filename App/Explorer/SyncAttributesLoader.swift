import Foundation
import Observation
import Ports

/// One document view's lazy local metadata read. Results and in-flight requests never cross document identities.
@MainActor @Observable
final class SyncAttributesLoader {
    enum State: Equatable {
        case idle
        case loading
        case loaded(DocumentSyncAttributes)
        case missing
        case failed(String)
    }

    let collection: String
    let id: String
    private(set) var state: State = .idle

    @ObservationIgnored private var requestID = UUID()

    init(collection: String, id: String) {
        self.collection = collection
        self.id = id
    }

    func loadIfNeeded(using explorer: ExplorerModel) async {
        guard case .idle = state else { return }
        await read(using: explorer)
    }

    func retry(using explorer: ExplorerModel) async {
        guard case .failed = state else { return }
        await read(using: explorer)
    }

    func cancel() {
        requestID = UUID()
        if case .loading = state { state = .idle }
    }

    private func read(using explorer: ExplorerModel) async {
        let request = UUID()
        requestID = request
        state = .loading
        do {
            let attributes = try await explorer.syncAttributes(collection: collection, id: id)
            guard requestID == request else { return }
            state = attributes.map(State.loaded) ?? .missing
        } catch {
            guard requestID == request else { return }
            state = .failed(error.localizedDescription)
        }
    }
}
