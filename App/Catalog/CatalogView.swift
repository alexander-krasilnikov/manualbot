import Ports
import SwiftUI

/// The manual catalog: categories on the left, the entries of the chosen category (or all) on the right, with a kind filter,
/// search, and an import button on each entry. Entries can be ticked to import several at once.
struct CatalogView: View {
    @Bindable var model: CatalogViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var detail: ManualCatalogEntry?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            entryList
        }
        .task { model.startMonitoringNetwork() }
        .sheet(item: $detail) { entry in
            CatalogDetailView(model: model, entry: entry)
        }
        .alert(
            "Download from \(model.notice?.hosts.formatted(.list(type: .and)) ?? "")?",
            isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.dismissNotice() } }), presenting: model.notice
        ) { _ in
            Button("Download") { model.confirmNotice() }.accessibilityIdentifier("catalogNoticeDownload")
            Button("Cancel", role: .cancel) {}
        } message: { notice in
            Text(CatalogText.notice(hosts: notice.hosts))
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $model.category) {
            Label("All categories", systemImage: "square.grid.2x2")
                .badge(model.filteredEntries.count)
                .tag(String?.none)
                .accessibilityIdentifier("catalogCategory-all")
            ForEach(model.visibleCategories, id: \.self) { category in
                Text(category)
                    .badge(model.count(in: category))
                    .tag(String?.some(category))
                    .accessibilityIdentifier("catalogCategory-\(category)")
            }
        }
        .navigationTitle("Categories")
    }

    // MARK: Entries

    private var entryList: some View {
        List {
            if !model.isOnline {
                Label(CatalogText.offlineMessage, systemImage: "wifi.slash")
                    .font(.callout).foregroundStyle(.orange)
                    .accessibilityIdentifier("catalogOffline")
            }
            Picker("Kind", selection: $model.kind) {
                Text("All").tag(ManualKind?.none)
                Text("Manuals").tag(ManualKind?.some(.manual))
                Text("Catalogs").tag(ManualKind?.some(.catalog))
                Text("Whitepapers").tag(ManualKind?.some(.whitepaper))
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("catalogKind")
            ForEach(model.sections, id: \.category) { section in
                Section(section.category) {
                    ForEach(section.entries) { entry in
                        CatalogRow(
                            entry: entry, state: model.state(of: entry), isSelected: model.selection.contains(entry.id),
                            publisherUpdatedFile: model.publisherUpdatedFile(entry), canImportNow: model.isOnline,
                            onToggle: { model.toggleSelection(entry) }, onOpen: { detail = entry },
                            onImport: { model.requestImport([entry.id]) }, onCancel: { model.cancel(entry) },
                            onBrowser: { openURL(entry.url) })
                    }
                }
            }
        }
        .overlay {
            if model.sections.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
                    .accessibilityIdentifier("catalogEmpty")
            }
        }
        .searchable(text: $model.searchText, prompt: "Search title, publisher or category")
        .navigationTitle("Manual catalog")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }.accessibilityIdentifier("catalogDone")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Import \(model.importableSelection.count)") { model.requestImportOfSelection() }
                    .disabled(model.importableSelection.isEmpty || !model.isOnline)
                    .accessibilityIdentifier("catalogImportSelected")
            }
        }
    }
}

private struct CatalogRow: View {
    let entry: ManualCatalogEntry
    let state: CatalogViewModel.EntryState
    let isSelected: Bool
    let publisherUpdatedFile: Bool
    let canImportNow: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onImport: () -> Void
    let onCancel: () -> Void
    let onBrowser: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            selector
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                    Text(entry.publisher).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 8) {
                        Text(CatalogText.kind(entry.kind))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: Capsule())
                        Text("\(CatalogText.size(entry)) · \(CatalogText.pages(entry))").font(.caption).foregroundStyle(.secondary)
                    }
                    stateView
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("catalogRow-\(entry.id)")
            actions
        }
        .padding(.vertical, 2)
    }

    /// A tick for entries that can still be imported; a check mark for those that are in the library.
    @ViewBuilder private var selector: some View {
        switch state {
        case .notImported, .failed:
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").font(.title3).frame(width: 32, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isSelected ? "Deselect \(entry.title)" : "Select \(entry.title)")
            .accessibilityIdentifier("catalogSelect-\(entry.id)")
        case .queued, .inLibrary:
            Image(systemName: "checkmark.circle").font(.title3).foregroundStyle(.green).frame(width: 32, height: 44)
        case .downloading:
            ProgressView().frame(width: 32, height: 44)
        }
    }

    @ViewBuilder private var stateView: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch state {
            case .notImported:
                Text("Not imported").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("catalogState-\(entry.id)")
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 2) {
                    if let progress { ProgressView(value: progress).progressViewStyle(.linear) } else { ProgressView().progressViewStyle(.linear) }
                    Text(progress.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading…").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("catalogState-\(entry.id)")
            case .queued:
                Text("Queued for indexing").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("catalogState-\(entry.id)")
            case .inLibrary:
                Text("In library").font(.caption).foregroundStyle(.green).accessibilityIdentifier("catalogState-\(entry.id)")
            case .failed(let failure):
                Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("catalogState-\(entry.id)")
            }
            if publisherUpdatedFile {
                Label(CatalogText.updatedNote, systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("catalogUpdated-\(entry.id)")
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch state {
        case .notImported:
            Button("Import", action: onImport).buttonStyle(.bordered).disabled(!canImportNow)
                .accessibilityIdentifier("catalogImport-\(entry.id)")
        case .downloading:
            Button("Cancel", action: onCancel).buttonStyle(.bordered).accessibilityIdentifier("catalogCancel-\(entry.id)")
        case .failed(let failure):
            VStack(alignment: .trailing, spacing: 6) {
                Button("Retry", action: onImport).buttonStyle(.bordered).disabled(!canImportNow)
                    .accessibilityIdentifier("catalogRetry-\(entry.id)")
                if failure.canOpenInBrowser {
                    Button("Open in browser", action: onBrowser).buttonStyle(.bordered)
                        .accessibilityIdentifier("catalogBrowser-\(entry.id)")
                }
            }
        case .queued, .inLibrary:
            EmptyView()
        }
    }
}

/// One entry in full: who published it, on what terms, and where the file comes from.
private struct CatalogDetailView: View {
    let model: CatalogViewModel
    let entry: ManualCatalogEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(entry.title).font(.title3.weight(.semibold))
                    LabeledContent("Publisher", value: entry.publisher).accessibilityIdentifier("catalogDetailPublisher")
                    LabeledContent("Category", value: entry.category)
                    LabeledContent("Kind", value: CatalogText.kind(entry.kind))
                    LabeledContent("Size", value: CatalogText.size(entry))
                    LabeledContent("Pages", value: String(entry.pages))
                    LabeledContent("Language", value: Locale.current.localizedString(forLanguageCode: entry.language) ?? entry.language)
                }
                Section("Licence") {
                    Text(entry.licenceNote).accessibilityIdentifier("catalogDetailLicence")
                }
                Section("Source") {
                    Text(entry.url.absoluteString).font(.callout.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("catalogDetailAddress")
                    Text("Downloaded from the publisher’s server when you import it. ManualBot does not keep a copy of it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open in browser", systemImage: "safari") { openURL(entry.url) }
                        .accessibilityIdentifier("catalogDetailBrowser")
                }
                Section {
                    switch model.state(of: entry) {
                    case .notImported, .failed:
                        Button("Import", systemImage: "arrow.down.circle") {
                            model.requestImport([entry.id])
                            dismiss()
                        }
                        .disabled(!model.isOnline)
                        .accessibilityIdentifier("catalogDetailImport")
                    case .downloading: Text("Downloading…").foregroundStyle(.secondary)
                    case .queued: Text("Queued for indexing").foregroundStyle(.secondary)
                    case .inLibrary: Label("In library", systemImage: "checkmark.circle").foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("catalogDetailDone") }
            }
        }
        .presentationDetents([.large])
    }
}
