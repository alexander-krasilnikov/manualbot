import SwiftUI

/// Licences and notices for the models and libraries that ship with the app.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DemoSettings.self) private var demo: DemoSettings?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("ManualBot answers questions about your documents entirely on this iPad. Your documents, questions and answers never leave the device.")
                }
                if let demo {
                    @Bindable var demo = demo
                    Section {
                        Toggle("Demo mode", isOn: $demo.isOn).accessibilityIdentifier("demoModeToggle")
                    } footer: {
                        Text("Adds an X-ray view that shows what the app and Couchbase Lite do behind each import and question. Nothing else changes.")
                    }
                }
                Section("Models") {
                    notice(
                        "EmbeddingGemma 2",
                        "Downloaded once on first use. Licensed under the Apache License 2.0. Finds passages and photos by meaning.",
                        links: [("Apache License 2.0", "https://www.apache.org/licenses/LICENSE-2.0")])
                    notice(
                        "Gemma 4 E2B",
                        "Downloaded once on first use. Licensed under the Apache License 2.0.",
                        links: [("Apache License 2.0", "https://www.apache.org/licenses/LICENSE-2.0")])
                }
                Section("Software") {
                    notice("LiteRT-LM", "Apache License 2.0. Runs the embedding model and the language model.", links: [])
                    notice("Couchbase Lite", "Stores your library and search index on this iPad, under Couchbase's licence.", links: [])
                    notice("ZIPFoundation", "MIT License. Reads Word documents.", links: [])
                }
            }
            .navigationTitle("About")
            .toolbar { Button("Done") { dismiss() } }
        }
        .accessibilityIdentifier("aboutSheet")
    }

    private func notice(_ title: String, _ text: String, links: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary)
            ForEach(links, id: \.0) { link in
                if let url = URL(string: link.1) { Link(link.0, destination: url).font(.callout) }
            }
        }
        .padding(.vertical, 2)
    }
}
