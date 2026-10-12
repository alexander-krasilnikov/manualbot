import Core
import Ports
import SwiftUI

/// The Models page: the models in use and installed, the embedding models the app offers, and a search for language
/// models. Searching and downloading are the only network use after setup, and only when the user asks.
struct ModelSettingsView: View {
    @Bindable var model: ModelSettingsViewModel

    var body: some View {
        Group {
            List {
                inUseSection
                installedSection
                embeddersSection
                languageModelsSection
                Section {
                    LabeledContent("Available storage", value: Format.bytes(model.storageAvailable))
                        .accessibilityIdentifier("storageAvailable")
                } footer: {
                    Text("Models are stored on this iPad only. Searching for and downloading a model are the only times the app uses the network after setup.")
                }
            }
            .disabled(model.isSwitching)
            .overlay {
                if model.isSwitching {
                    ProgressView("Switching model…")
                        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("switchingProgress")
                }
            }
            .navigationTitle("Models")
            .alert(
                "Use \(model.confirmation?.title ?? "this model")?",
                isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.dismissConfirmation() } }),
                presenting: model.confirmation
            ) { confirmation in
                Button("Use \(confirmation.title)") { Task { await model.confirm(confirmation) } }.accessibilityIdentifier("confirmSwitch")
                Button("Cancel", role: .cancel) { model.dismissConfirmation() }.accessibilityIdentifier("cancelSwitch")
            } message: { confirmation in
                Text(confirmation.message)
            }
            .alert(
                "Models", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) { model.errorMessage = nil }.accessibilityIdentifier("modelsErrorOK")
            } message: {
                Text(model.errorMessage ?? "")
            }
            .task { await model.observe() }
        }
        .accessibilityIdentifier("modelsPage")
    }

    // MARK: Sections

    private var inUseSection: some View {
        Section("In use") {
            ForEach(model.installed.filter(\.isActive).sorted { $0.role < $1.role }) { row in
                InstalledModelRow(row: row)
                    .accessibilityIdentifier("inUse-\(row.id)")
            }
        }
    }

    @ViewBuilder private var installedSection: some View {
        let others = model.installed.filter { !$0.isActive }.sorted { ($0.role, $0.title) < ($1.role, $1.title) }
        if !others.isEmpty {
            Section("Installed") {
                ForEach(others) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        InstalledModelRow(row: row)
                        HStack {
                            Button("Use") { Task { await model.requestActivation(of: row.id) } }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("useModel-\(row.id)")
                            Button("Delete", role: .destructive) { Task { await model.delete(row.id) } }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("deleteModel-\(row.id)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("installedModel-\(row.id)")
                }
            }
        }
    }

    /// Always shown, so that it is clear where embedding models come from even when there is nothing left to download.
    private var embeddersSection: some View {
        Section {
            if model.availableEmbedders.isEmpty {
                Text("Every embedding model the app offers is installed.")
                    .foregroundStyle(.secondary).accessibilityIdentifier("noMoreEmbedders")
            }
            ForEach(model.availableEmbedders) { row in
                AvailableModelRow(row: row) { Task { await model.download(row) } }
            }
        } header: {
            Text("Embedding models")
        } footer: {
            Text("These come from a list that ships with the app: each needs settings that were tested for it. Search finds other embedding models too, but those are untested. Using another embedding model re-indexes your documents.")
        }
    }

    private var languageModelsSection: some View {
        Section {
            ForEach(model.availableDefaults) { row in
                AvailableModelRow(row: row) { Task { await model.download(row) } }
            }
            HStack {
                TextField("Search for a model", text: $model.query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { Task { await model.search() } }
                    .accessibilityIdentifier("modelSearchField")
                Button("Search") { Task { await model.search() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("modelSearchButton")
            }
            switch model.searchState {
            case .idle, .results:
                EmptyView()
            case .searching:
                ProgressView("Searching…").accessibilityIdentifier("modelSearching")
            case .offline:
                Label("Searching needs a network connection. The models you have installed keep working.", systemImage: "wifi.slash")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("searchOffline")
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .accessibilityIdentifier("searchFailed")
            }
            if model.searchState == .results, model.results.isEmpty {
                Text("No language models found.").foregroundStyle(.secondary).accessibilityIdentifier("searchNothingFound")
            }
            ForEach(model.results) { row in
                AvailableModelRow(row: row) { Task { await model.download(row) } }
                    .accessibilityIdentifier("searchResult-\(row.id)")
            }
        } header: {
            Text("Find models")
        } footer: {
            Text("Search finds public LiteRT-LM models from the litert-community, language models and embedding models. Each is checked before it is downloaded and again once it is on this iPad.")
        }
    }
}

/// A model that is installed: its name, what it is for, its size and its licence.
struct InstalledModelRow: View {
    let row: ModelSettingsViewModel.InstalledRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.title).font(.headline)
                Spacer()
                Text(Format.bytes(row.bytes)).foregroundStyle(.secondary)
            }
            Text(row.role == .embedder ? "Search and indexing" : "Answers and chat")
                .font(.caption).foregroundStyle(.secondary)
            Text(row.licence.map { "Licence: \($0)" } ?? "Licence not stated")
                .font(.caption).foregroundStyle(.secondary)
            if row.isUntested {
                Label("Untested: search quality unknown", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("untested-\(row.id)")
            }
        }
    }
}

/// A model that can be downloaded, with what is known about it first and its progress after.
struct AvailableModelRow: View {
    let row: ModelSettingsViewModel.AvailableRow
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Format.bytes(row.spec.bytes)).foregroundStyle(.secondary)
            }
            if row.isUntestedEmbedder {
                Label("Untested: search quality unknown", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("untested-\(row.id)")
            }
            if let verdict = row.verdict {
                HStack(spacing: 4) {
                    Image(systemName: symbol(for: verdict)).accessibilityHidden(true)
                    Text(verdict.label).accessibilityIdentifier("verdict-\(row.id)")
                }
                .font(.caption).foregroundStyle(color(for: verdict))
            }
            switch row.state {
            case .missing:
                if row.canDownload {
                    Button("Download", action: onDownload).buttonStyle(.bordered)
                        .accessibilityIdentifier("downloadModel-\(row.id)")
                }
            case .downloading(let fraction):
                ProgressView(value: fraction) { Text("Downloading \(Int(fraction * 100))%").font(.caption) }
            case .verifying:
                ProgressView { Text("Checking the file").font(.caption) }
            case .installed:
                Label("Installed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            case .failed(let reason):
                HStack {
                    Label(reason, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.red)
                    Spacer()
                    if row.canDownload {
                        Button("Retry", action: onDownload).buttonStyle(.bordered).accessibilityIdentifier("retryModel-\(row.id)")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("availableModel-\(row.id)")
    }

    private var detail: String {
        var parts: [String] = []
        // A search result says what kind of model it is. An embedding model also says whether it was tested.
        if row.source == .search { parts.append(row.isEmbedder ? "Embedding model" : "Language model") }
        if let supportsPhotos = row.supportsPhotos { parts.append(supportsPhotos ? "Search and photos" : "Search, no photos") }
        parts.append(row.spec.licence.map { "Licence: \($0)" } ?? "Licence not stated")
        return parts.joined(separator: " · ")
    }

    private func symbol(for verdict: ModelCandidate.Verdict) -> String {
        switch verdict {
        case .compatible: "checkmark.seal"
        case .checkedAfterDownload: "questionmark.circle"
        case .incompatible: "xmark.octagon"
        }
    }

    private func color(for verdict: ModelCandidate.Verdict) -> Color {
        switch verdict {
        case .compatible: .green
        case .checkedAfterDownload: .secondary
        case .incompatible: .red
        }
    }
}
