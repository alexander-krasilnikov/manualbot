import Foundation
import Observation
import Ports

/// What the sidebar has selected.
enum ExplorerSelection: Hashable {
    case query
    case indexes
    case collection(String)
}

/// Where the explorer opens: the overview, a collection, or one document.
struct ExplorerTarget: Identifiable, Equatable {
    let id = UUID()
    var collection: String?
    var documentID: String?

    init(collection: String? = nil, documentID: String? = nil) {
        self.collection = collection
        self.documentID = documentID
    }
}

/// What the detail column's stack can show.
enum ExplorerDestination: Hashable {
    case document(collection: String, id: String)
    case index(String)
    case resultRow(Int)
    case plan
}

enum DocumentState: Equatable {
    case found(String)
    case gone
    case failed(String)
}

/// Everything the database explorer shows, read on demand through the inspector. Nothing it does writes to the database.
@MainActor @Observable
final class ExplorerModel {
    static let pageSize = 50

    /// Set once the database is open.
    var inspector: (any TraceInspector)? {
        didSet { console.inspector = inspector }
    }
    let console = ExplorerConsole()

    private(set) var collections: [CollectionSummary] = []
    private(set) var indexes: [IndexSummary] = []
    private(set) var loadError: String?
    private(set) var isRefreshing = false
    private(set) var firstDocumentID: String?

    private(set) var selection: ExplorerSelection?
    private(set) var ids: [String] = []
    private(set) var hasMore = false
    private(set) var isLoadingIDs = false
    private(set) var filter = ""
    /// The detail column's stack: the document, result row, index or plan on show, and where it came from.
    var path: [ExplorerDestination] = []

    /// What the workspace presents full screen; `nil` while the explorer is closed.
    var presented: ExplorerTarget?

    @ObservationIgnored private var listGeneration = 0

    var syncReady: [CollectionSummary] { collections.filter { !$0.localOnly } }
    var localOnly: [CollectionSummary] { collections.filter(\.localOnly) }
    var starters: [StarterQuery] { StarterQuery.all(firstDocumentID: firstDocumentID) }

    // MARK: Opening

    func present(_ target: ExplorerTarget = ExplorerTarget()) { presented = target }

    /// Reads the counts and indexes again and shows `target`. Called whenever the explorer opens.
    func open(_ target: ExplorerTarget = ExplorerTarget()) async {
        path = []
        await readOverview()
        if let collection = target.collection {
            filter = ""
            await select(.collection(collection))
            if let id = target.documentID { path = [.document(collection: collection, id: id)] }
        } else if let current = selection {
            await select(current)
        } else if let first = collections.first {
            await select(.collection(first.name))
        }
    }

    /// Reads the counts and indexes again, and the current list from its first page.
    func refresh() async {
        await readOverview()
        await reloadList()
    }

    private func readOverview() async {
        guard let inspector else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            collections = try await inspector.collectionSummaries()
            indexes = try await inspector.indexes()
            firstDocumentID = try await inspector.documentIDs(
                collection: "documents", after: nil, containing: nil, limit: 1).first
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Lists

    func select(_ selection: ExplorerSelection?) async {
        self.selection = selection
        path = []
        filter = ""
        await reloadList()
    }

    func setFilter(_ text: String) async {
        guard text != filter else { return }
        filter = text
        await reloadList()
    }

    func loadMore() async {
        guard hasMore, !isLoadingIDs, case .collection(let name) = selection else { return }
        await loadPage(of: name, after: ids.last)
    }

    private func reloadList() async {
        listGeneration += 1
        ids = []
        hasMore = false
        isLoadingIDs = false
        guard case .collection(let name) = selection else { return }
        await loadPage(of: name, after: nil)
    }

    private func loadPage(of collection: String, after: String?) async {
        guard let inspector else { return }
        let generation = listGeneration
        isLoadingIDs = true
        do {
            // One more than a page, to know whether another page follows.
            let page = try await inspector.documentIDs(
                collection: collection, after: after, containing: filter.isEmpty ? nil : filter, limit: Self.pageSize + 1)
            guard generation == listGeneration else { return }
            ids += page.prefix(Self.pageSize)
            hasMore = page.count > Self.pageSize
            loadError = nil
        } catch {
            guard generation == listGeneration else { return }
            loadError = error.localizedDescription
        }
        isLoadingIDs = false
    }

    // MARK: Documents

    func document(collection: String, id: String, fullVectors: Bool = false) async -> DocumentState {
        guard let inspector else { return .gone }
        do {
            guard let json = try await inspector.storedDocument(collection: collection, id: id, fullVectors: fullVectors) else {
                return .gone
            }
            return .found(json)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func blob(collection: String, id: String, key: String) async -> BlobContent? {
        try? await inspector?.blob(collection: collection, id: id, key: key)
    }

    func children(of documentID: String) async -> DocumentChildren {
        (try? await inspector?.children(documentID: documentID)) ?? DocumentChildren()
    }

    /// The collection a field points into, for the fields that hold another document's ID.
    nonisolated static func collection(referencedBy key: String) -> String? {
        switch key {
        case "docId": CollectionNames.documents
        case "chatId": CollectionNames.chats
        case "imageId": CollectionNames.images
        default: nil
        }
    }

    func follow(collection: String, id: String) {
        path.append(.document(collection: collection, id: id))
    }

    func show(index: IndexSummary) { path = [.index(index.id)] }

    func showRow(_ row: Int) { path = [.resultRow(row)] }

    func showPlan() async {
        path = [.plan]
        await console.loadPlan()
    }
}

/// The collection names the explorer links between.
enum CollectionNames {
    static let documents = "documents"
    static let chunks = "chunks"
    static let images = "images"
    static let chats = "chats"
    static let messages = "messages"
}
