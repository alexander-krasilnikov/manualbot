import SwiftUI

@main
struct ManualBotApp: App {
    private let launch: Result<AppModel, Error>

    @Environment(\.scenePhase) private var scenePhase

    @MainActor init() {
        launch = Result { try AppEnvironment.makeAppModel() }
        if case .success(let app) = launch { app.registerBackgroundTask() }
    }

    var body: some Scene {
        WindowGroup {
            switch launch {
            case .success(let app):
                RootView(app: app)
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .background { Task { await app.scheduleBackgroundIndexingIfNeeded() } }
                    }
            case .failure(let error):
                ContentUnavailableView("Cannot start", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
            }
        }
    }
}
