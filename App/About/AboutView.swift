import SwiftUI

/// Licences and notices for the models and libraries that ship with the app.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("ManualBot answers questions about your documents entirely on this iPad. Your documents, questions and answers never leave the device.")
                }
                Section("Models") {
                    notice(
                        "EmbeddingGemma 300M",
                        "Built into the app. Gemma is provided under and subject to the Gemma Terms of Use found at ai.google.dev/gemma/terms. Use is also subject to the Gemma Prohibited Use Policy. This copy is a Core ML conversion of Google's model.",
                        links: [("Gemma Terms of Use", "https://ai.google.dev/gemma/terms"),
                                ("Prohibited Use Policy", "https://ai.google.dev/gemma/prohibited_use_policy")])
                    notice(
                        "Gemma 4 E4B",
                        "Downloaded once on first use. Licensed under the Apache License 2.0.",
                        links: [("Apache License 2.0", "https://www.apache.org/licenses/LICENSE-2.0")])
                }
                Section("Software") {
                    notice("LiteRT-LM", "Apache License 2.0. Runs the language model.", links: [])
                    notice("Couchbase Lite", "Stores your library and search index on this iPad, under Couchbase's licence.", links: [])
                    notice("swift-transformers", "Apache License 2.0. Tokenizes text for the embedding model.", links: [])
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
