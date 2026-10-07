import Ports
import SwiftUI

/// Library, chat and source side by side on a wide iPad; collapses to a stack in narrow windows.
struct WorkspaceView: View {
    let app: AppModel
    @State private var visibility = NavigationSplitViewVisibility.all
    @State private var compactColumn = NavigationSplitViewColumn.content
    @State private var detailTab = DetailTab.source

    var body: some View {
        if let library = app.library, let chat = app.chat, let source = app.source {
            NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $compactColumn) {
                LibraryView(
                    library: library,
                    onOpenExplorer: { app.demo.explorer.present() }
                ) { id in show { await source.openDocument(id) } }
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
            } content: {
                ChatView(chat: chat, models: app.models, samplePhoto: SampleDocuments.x200Nameplate) { citation in
                    show { await source.open(citation) }
                }
                    .navigationSplitViewColumnWidth(min: 380, ideal: 520)
            } detail: {
                DetailColumn(source: source, demo: app.demo, tab: $detailTab)
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
