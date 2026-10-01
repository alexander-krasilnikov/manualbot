import SwiftUI

/// Shows model setup until documents can be indexed, then the workspace. Readiness is staged:
/// the embedding model unlocks import; chat waits for the language model.
struct RootView: View {
    let app: AppModel

    var body: some View {
        Group {
            if !app.models.isLoaded {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.models.canImport {
                WorkspaceView(app: app)
            } else {
                ModelSetupView(model: app.models)
            }
        }
        .task { await app.run() }
        .onOpenURL { url in Task { await app.open([url]) } }
    }
}
