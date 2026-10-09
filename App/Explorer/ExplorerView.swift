import Ports
import SwiftUI

/// The database explorer, full screen: collections and indexes on the left, the IDs or the SQL++ console in the
/// middle, the document, result row, index or plan on the right. Strictly read-only.
struct ExplorerView: View {
    @Bindable var explorer: ExplorerModel
    let xray: XrayModel
    let target: ExplorerTarget
    @State private var visibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            ExplorerSidebar(explorer: explorer)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } content: {
            ExplorerContent(explorer: explorer)
                .navigationSplitViewColumnWidth(min: 320, ideal: 420)
        } detail: {
            ExplorerDetail(explorer: explorer)
        }
        .dynamicTypeSize(xray.textSize)
        .task { await explorer.open(target) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explorer")
    }
}

private struct ExplorerSidebar: View {
    @Bindable var explorer: ExplorerModel

    var body: some View {
        List(selection: Binding(get: { explorer.selection }, set: { selection in Task { await explorer.select(selection) } })) {
            Section {
                Label("Query", systemImage: "terminal")
                    .tag(ExplorerSelection.query)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("explorerQuery")
            }
            Section("Replicated") { ForEach(explorer.replicated) { row($0) } }
            Section("Local only") { ForEach(explorer.localOnly) { row($0) } }
            Section {
                Label("Indexes (\(explorer.indexes.count))", systemImage: "list.bullet.indent")
                    .tag(ExplorerSelection.indexes)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("explorerIndexes")
            }
        }
        .navigationTitle("Database")
        .safeAreaInset(edge: .bottom) {
            if let error = explorer.loadError {
                Text(error).font(.caption).foregroundStyle(.orange).padding(8).accessibilityIdentifier("explorerError")
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { explorer.presented = nil }.accessibilityIdentifier("explorerDone")
            }
            ToolbarItem(placement: .primaryAction) {
                if explorer.isRefreshing {
                    ProgressView()
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await explorer.refresh() } }
                        .accessibilityIdentifier("explorerRefresh")
                }
            }
        }
    }

    private func row(_ collection: CollectionSummary) -> some View {
        HStack {
            Label(collection.name, systemImage: collection.localOnly ? "iphone" : "tablecells")
            Spacer()
            Text(collection.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
        }
        .tag(ExplorerSelection.collection(collection.name))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("explorerCollection-\(collection.name)")
    }
}

private struct ExplorerContent: View {
    @Bindable var explorer: ExplorerModel

    var body: some View {
        switch explorer.selection {
        case .collection(let name): DocumentIDList(explorer: explorer, collection: name)
        case .query: ConsoleView(explorer: explorer)
        case .indexes: IndexList(explorer: explorer)
        case nil: ContentUnavailableView("Select a collection", systemImage: "tablecells")
        }
    }
}

private struct DocumentIDList: View {
    @Bindable var explorer: ExplorerModel
    let collection: String

    var body: some View {
        List {
            ForEach(explorer.ids, id: \.self) { id in
                Button {
                    explorer.path = [.document(collection: collection, id: id)]
                } label: {
                    Text(id).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
                .listRowBackground(isOpen(id) ? Color.accentColor.opacity(0.15) : nil)
                .accessibilityIdentifier("explorerDoc-\(id)")
            }
            if explorer.hasMore {
                Button("Load more") { Task { await explorer.loadMore() } }
                    .accessibilityIdentifier("explorerLoadMore")
            }
        }
        .listStyle(.plain)
        .overlay {
            if explorer.ids.isEmpty && !explorer.isLoadingIDs {
                if explorer.filter.isEmpty {
                    ContentUnavailableView("This collection is empty", systemImage: "tray")
                        .accessibilityIdentifier("explorerEmpty")
                } else {
                    ContentUnavailableView.search(text: explorer.filter)
                }
            } else if explorer.ids.isEmpty {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .searchable(
            text: Binding(get: { explorer.filter }, set: { text in Task { await explorer.setFilter(text) } }),
            prompt: "Filter by ID")
    }

    private var title: String {
        let count = explorer.collections.first { $0.name == collection }?.count
        return count.map { "\(collection) (\($0.formatted()))" } ?? collection
    }

    private func isOpen(_ id: String) -> Bool {
        explorer.path.first == .document(collection: collection, id: id)
    }
}

private struct IndexList: View {
    @Bindable var explorer: ExplorerModel

    var body: some View {
        List {
            ForEach(explorer.indexes) { index in
                Button { explorer.show(index: index) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(index.name).font(.system(.callout, design: .monospaced))
                        Text("\(index.settings.map { Self.label($0.kind) } ?? "index") · \(index.collection)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("explorerIndex-\(index.name)")
            }
        }
        .listStyle(.plain)
        .overlay { if explorer.indexes.isEmpty { ContentUnavailableView("No indexes", systemImage: "list.bullet.indent") } }
        .navigationTitle("Indexes")
    }

    static func label(_ kind: IndexSummary.Kind) -> String {
        switch kind {
        case .vector: "vector index"
        case .fullText: "full-text index"
        case .value: "value index"
        }
    }
}

/// The right-hand column. The first stop is its root; each reference followed is pushed on top, so Back returns.
private struct ExplorerDetail: View {
    @Bindable var explorer: ExplorerModel

    var body: some View {
        NavigationStack(
            path: Binding(
                get: { Array(explorer.path.dropFirst()) },
                set: { explorer.path = Array(explorer.path.prefix(1)) + $0 })
        ) {
            Group {
                if let first = explorer.path.first {
                    destination(first).id(first)
                } else {
                    ContentUnavailableView(
                        "Nothing selected", systemImage: "doc.text.magnifyingglass",
                        description: Text("Pick a document, a result row or an index."))
                }
            }
            .navigationDestination(for: ExplorerDestination.self) { destination($0) }
        }
    }

    @ViewBuilder private func destination(_ destination: ExplorerDestination) -> some View {
        switch destination {
        case .document(let collection, let id): DocumentView(explorer: explorer, collection: collection, id: id)
        case .index(let id): IndexDetailView(explorer: explorer, indexID: id)
        case .resultRow(let row): ResultRowView(console: explorer.console, row: row)
        case .plan: PlanView(console: explorer.console)
        }
    }
}

private struct IndexDetailView: View {
    let explorer: ExplorerModel
    let indexID: String

    var body: some View {
        if let index = explorer.indexes.first(where: { $0.id == indexID }) {
            List {
                fact("Name", index.name)
                fact("Collection", index.collection)
                if let settings = index.settings {
                    fact("Kind", IndexList.label(settings.kind))
                    fact("Indexed", settings.expression)
                    if let dimensions = settings.dimensions { fact("Dimensions", String(dimensions)) }
                    if let metric = settings.metric { fact("Distance metric", metric) }
                    if let centroids = settings.centroids { fact("Centroids", String(centroids)) }
                    if let encoding = settings.encoding { fact("Encoding", encoding) }
                } else {
                    Text("The app does not define this index, so its settings are not known.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle(index.name)
            .accessibilityIdentifier("explorerIndexDetail")
        } else {
            ContentUnavailableView("This index no longer exists", systemImage: "list.bullet.indent")
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            .accessibilityIdentifier("explorerFact-\(title)")
    }
}
