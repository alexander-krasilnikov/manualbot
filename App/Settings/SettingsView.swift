import Ports
import SwiftUI

/// The pages Settings pushes from its list.
enum SettingsPage: Hashable {
    case models, sync
}

/// How Settings is opened: at its list (the gear), or straight at the Sync page (the cloud).
enum SettingsEntry: Identifiable {
    case list, sync

    var id: Self { self }
}

/// Settings: the Models page and the Sync page. Presented from the root view, so it stays while the workspace is rebuilt
/// for a switch of models.
struct SettingsView: View {
    let app: AppModel
    let entry: SettingsEntry
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
                }
            }
            .toolbar { Button("Done") { dismiss() }.accessibilityIdentifier("settingsDone") }
        }
        .accessibilityIdentifier("settingsSheet")
        .onAppear { if entry == .sync, path.isEmpty { path = [.sync] } }
    }
}
