import Ports
import SwiftUI

/// First-run screen: lists the models, their sizes and the storage they need, then downloads them.
struct ModelSetupView: View {
    let model: ModelSetupViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("ManualBot answers questions about your documents entirely on this iPad. It needs two models, downloaded once. After that, nothing leaves the device and no connection is needed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Models") {
                    ForEach(model.setupRows) { row in
                        ModelRowView(row: row) { Task { await model.retry(row.id) } }
                    }
                }

                if let storage = model.storage, !model.pendingRows.isEmpty {
                    Section("Storage") {
                        LabeledContent("To download", value: Format.bytes(model.totalPendingBytes))
                        LabeledContent("Available", value: Format.bytes(storage.available))
                        if !storage.isSufficient {
                            Label("Free up \(Format.bytes(storage.shortfall)) to continue.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .accessibilityIdentifier("insufficientStorage")
                        }
                    }
                }

                Section {
                    Button {
                        Task { await model.start() }
                    } label: {
                        Text(model.hasFailure ? "Download remaining models" : "Download models")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking || (model.storage.map { !$0.isSufficient } ?? false))
                    .accessibilityIdentifier("startDownload")
                }
            }
            .navigationTitle("Set up models")
        }
    }
}

struct ModelRowView: View {
    let row: ModelSetupViewModel.Row
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text(row.title).font(.headline)
                    Text(row.role == .embedder ? "Search and indexing" : "Answers and chat")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Format.bytes(row.bytes)).foregroundStyle(.secondary)
            }
            switch row.state {
            case .missing:
                Text("Not downloaded").font(.caption).foregroundStyle(.secondary)
            case .downloading(let fraction):
                ProgressView(value: fraction) { Text("Downloading \(Int(fraction * 100))%").font(.caption) }
            case .verifying:
                ProgressView { Text("Verifying").font(.caption) }
            case .installed:
                Label("Ready", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            case .failed(let reason):
                HStack {
                    Label(reason, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button("Retry", action: onRetry).buttonStyle(.bordered)
                        .accessibilityIdentifier("retry-\(row.id)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model-\(row.id)")
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
