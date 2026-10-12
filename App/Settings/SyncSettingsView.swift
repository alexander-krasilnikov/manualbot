import Core
import Ports
import SwiftUI

/// The Sync page: the server and account, the switch, what sync is doing, and what is not shared.
struct SyncSettingsView: View {
    @Bindable var model: SyncModel

    var body: some View {
        @Bindable var settings = model.settings
        List {
            Section {
                TextField("Server address", text: $settings.address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .onSubmit { Task { await model.apply() } }
                    .onChange(of: settings.address) { model.settingsEdited() }
                    .accessibilityIdentifier("syncAddress")
                TextField("User name", text: $settings.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { Task { await model.apply() } }
                    .onChange(of: settings.username) { model.settingsEdited() }
                    .accessibilityIdentifier("syncUsername")
                SecureField("Password", text: $settings.password)
                    .onSubmit { Task { await model.apply() } }
                    .onChange(of: settings.password) { model.settingsEdited() }
                    .accessibilityIdentifier("syncPassword")
            } header: {
                Text("Server")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The Sync Gateway of your library, such as 192.168.1.20:4984. Only documents, their originals, and their search data are sent: chats stay on this iPad.")
                    if settings.passwordNotSaved {
                        Text("The password could not be saved to the Keychain, so it is forgotten when the app closes.")
                            .foregroundStyle(.red).accessibilityIdentifier("syncPasswordNotSaved")
                    }
                }
            }

            Section {
                Toggle("Sync the library", isOn: Binding(
                    get: { settings.isEnabled },
                    set: { on in
                        settings.isEnabled = on
                        Task { await model.apply(restart: on) }
                    }))
                    .accessibilityIdentifier("syncToggle")
            }

            Section("Status") {
                LabeledContent("State") {
                    Label(SyncText.summary(model.state), systemImage: SyncText.symbol(model.state))
                }
                .accessibilityIdentifier("syncState")
                if let detail = SyncText.detail(model.state) {
                    Text(detail).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("syncDetail")
                }
                LabeledContent("Last synced", value: SyncText.lastSync(model.status.lastSync))
                    .accessibilityIdentifier("syncLastSync")
                LabeledContent("Documents sent", value: "\(model.status.sent)").accessibilityIdentifier("syncSent")
                LabeledContent("Documents received", value: "\(model.status.received)").accessibilityIdentifier("syncReceived")
            }

            if !model.unshared.isEmpty {
                Section {
                    ForEach(model.unshared) { document in
                        LabeledContent(document.title, value: IngestionError.sizeText(document.bytes))
                            .accessibilityIdentifier("syncUnshared-\(document.title)")
                    }
                } header: {
                    Text("Not shared")
                } footer: {
                    Text("The original of each is larger than \(IngestionError.sizeText(IngestionService.maxOriginalBytes)), the most that can be sent. They stay on this iPad, where they work as before.")
                }
            }
        }
        .navigationTitle("Sync")
        .onDisappear { Task { await model.apply() } }
        .accessibilityIdentifier("syncPage")
    }
}
