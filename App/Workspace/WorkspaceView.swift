import Ports
import SwiftUI

/// Library, chat and source side by side on a wide iPad; collapses to a stack in narrow windows.
struct WorkspaceView: View {
    let app: AppModel
    @State private var visibility = NavigationSplitViewVisibility.all
    @State private var compactColumn = NavigationSplitViewColumn.content

    var body: some View {
        if let library = app.library, let chat = app.chat, let source = app.source {
            NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $compactColumn) {
                LibraryView(library: library) { id in show { await source.openDocument(id) } }
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
            } content: {
                ChatView(chat: chat, models: app.models) { citation in show { await source.open(citation) } }
                    .navigationSplitViewColumnWidth(min: 380, ideal: 520)
            } detail: {
                SourceViewerView(source: source)
            }
            .task { await library.observe() }
            .onChange(of: library.items) { _, items in chat.updateDocuments(items) }
            .task { chat.updateDocuments(library.items) }
        } else {
            PreparingView(preparation: app.preparation)
        }
    }

    private func show(_ open: @escaping () async -> Void) {
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
