import Ports
import SwiftUI

/// Library, chat and source side by side on a wide iPad; collapses to a stack in narrow windows.
struct WorkspaceView: View {
    let app: AppModel
    @State private var visibility = NavigationSplitViewVisibility.all
    @State private var compactColumn = NavigationSplitViewColumn.content
    @State private var detailTab = DetailTab.source
    /// The contents list whose chunk or image is being previewed; the preview's Previous, Next and Show chunk act on it.
    @State private var activeContents: DocumentContentsModel?

    var body: some View {
        if let library = app.library, let chat = app.chat, let source = app.source {
            NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $compactColumn) {
                LibraryView(
                    library: library,
                    onOpenExplorer: { app.demo.explorer.present() },
                    onOpenSettings: { app.showingSettings = true },
                    settings: app.settings,
                    makeContents: { item in contents(for: item) },
                    onContentsDeleted: { model in
                        if source.previewedDocument == model.docId { source.showDeleted(title: model.title) }
                        if activeContents === model { activeContents = nil }
                    }
                ) { id in show { await source.openDocument(id) } }
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
            } content: {
                ChatView(chat: chat, models: app.models, samplePhoto: SampleDocuments.x200Nameplate) { citation in
                    show { await source.open(citation) }
                }
                    .navigationSplitViewColumnWidth(min: 380, ideal: 520)
            } detail: {
                DetailColumn(source: source, demo: app.demo, tab: $detailTab, previewActions: previewActions)
            }
            .task { await library.observe() }
            .fullScreenCover(item: Bindable(app.demo.explorer).presented) { target in
                ExplorerView(explorer: app.demo.explorer, xray: app.demo.xray, target: target)
            }
            .onChange(of: library.items) { _, items in chat.updateDocuments(items) }
            .task { chat.updateDocuments(library.items) }
        } else {
            PreparingView(preparation: app.preparation)
        }
    }

    private func contents(for item: LibraryViewModel.Item) -> DocumentContentsModel? {
        guard let source = app.source, let model = app.makeContents(for: item) else { return nil }
        model.onSelect = { model in
            activeContents = model
            show { await source.preview(model) }
        }
        // A reload keeps the user where they are: only the preview's content is brought up to date.
        model.onRefresh = { model in Task { await source.preview(model) } }
        return model
    }

    private var previewActions: PreviewActions {
        PreviewActions(
            step: { activeContents?.step(by: $0) },
            showChunk: {
                if let contents = activeContents, let image = contents.selectedImage { contents.showChunk(of: image) }
            },
            showInDocument: { citation in
                guard let source = app.source else { return }
                show { await source.open(citation) }
            },
            openInDatabase: { record in
                app.demo.explorer.present(ExplorerTarget(collection: record.collection, documentID: record.id))
            })
    }

    private func show(_ open: @escaping () async -> Void) {
        detailTab = .source
        Task {
            await open()
            withAnimation { compactColumn = .detail }
        }
    }
}

struct PreparingView: View {
    let preparation: AppModel.Preparation

    var body: some View {
        VStack(spacing: 16) {
            switch preparation {
            case .failed(let message):
                ContentUnavailableView("Cannot start", systemImage: "exclamationmark.triangle", description: Text(message))
                    .accessibilityIdentifier("preparationFailed")
            case .preparing(let message):
                ProgressView().controlSize(.large)
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary).accessibilityIdentifier("preparingMessage")
            default:
                ProgressView().controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
