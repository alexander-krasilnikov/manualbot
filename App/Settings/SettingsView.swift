import Ports
import SwiftUI

/// The pages of Settings. `root` is the list itself; opening Settings at `sync` goes straight to that page.
enum SettingsPage: Hashable, Identifiable {
    case root, models, sync

    var id: Self { self }
}

/// Settings: the Models page and the Sync page. Presented from the root view, so it stays while the workspace is rebuilt
/// for a switch of models.
struct SettingsView: View {
    let app: AppModel
    let initial: SettingsPage
    @State private var path: [SettingsPage] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: $path) {
            List {
                NavigationLink(value: SettingsPage.models) {
                    Label("Models", systemImage: "cpu")
                }
                .accessibilityIdentifier("settingsModelsRow")
                NavigationLink(value: SettingsPage.sync) {
                    LabeledContent {
                        Text(SyncText.summary(app.sync.state)).foregroundStyle(.secondary)
                    } label: {
                        Label("Sync", systemImage: SyncText.symbol(app.sync.state))
                    }
                }
                .accessibilityIdentifier("settingsSyncRow")
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .models: ModelSettingsView(model: app.settings)
                case .sync: SyncSettingsView(model: app.sync)
                case .root: EmptyView()
                }
            }
            .toolbar { Button("Done") { dismiss() }.accessibilityIdentifier("settingsDone") }
        }
        .accessibilityIdentifier("settingsSheet")
        .onAppear { if initial != .root, path.isEmpty { path = [initial] } }
    }
}
