import SwiftUI

/// Licences and notices for the models and libraries that ship with the app.
struct AboutView: View {
    /// Where the installed models are read from. `nil` lists none.
    var settings: ModelSettingsViewModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("ManualBot answers questions about your documents entirely on this iPad. Your documents, questions and answers never leave the device.")
                }
                Section("Models") {
                    ForEach(settings?.installed ?? []) { row in
                        notice(row.title, Self.notice(for: row), links: Self.links(for: row))
                    }
                }
                Section("Software") {
                    notice("LiteRT-LM", "Apache License 2.0. Runs the embedding model and the language model.", links: [])
                    notice("Couchbase Lite", "Stores your library and search index on this iPad, under Couchbase's licence.", links: [])
                    notice("ZIPFoundation", "MIT License. Reads Word documents.", links: [])
                }
            }
            .navigationTitle("About")
            .toolbar { Button("Done") { dismiss() } }
            .task { await settings?.reload() }
        }
        .accessibilityIdentifier("aboutSheet")
    }

    /// What About says about an installed model: its licence as its publisher states it, and what it is for.
    static func notice(for row: ModelSettingsViewModel.InstalledRow) -> String {
        let licence = row.licence.map { "Licensed under the \(LicenceLink.name(for: $0))." } ?? "Its publisher does not state a licence."
        return "\(licence) \(row.role == .embedder ? "Finds chunks and photos by meaning." : "Writes the answers.")"
    }

    /// The full terms when the app knows where they are, and the model's own page.
    static func links(for row: ModelSettingsViewModel.InstalledRow) -> [(String, String)] {
        var links: [(String, String)] = []
        if let licence = row.licence, let url = LicenceLink.url(for: licence) { links.append((LicenceLink.name(for: licence), url.absoluteString)) }
        if let page = row.repository { links.append(("Model page", page.absoluteString)) }
        return links
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

/// Licences as publishers state them ("Apache License 2.0", "apache-2.0", "mit"), and where their full terms are.
enum LicenceLink {
    private static func key(_ licence: String) -> String { licence.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// A readable name for a licence the app knows, or the licence as stated.
    static func name(for licence: String) -> String {
        switch key(licence) {
        case "apache20", "apachelicense20", "apache2": "Apache License 2.0"
        case "mit", "mitlicense": "MIT License"
        default: licence
        }
    }

    static func url(for licence: String?) -> URL? {
        guard let licence else { return nil }
        switch key(licence) {
        case "apache20", "apachelicense20", "apache2": return URL(string: "https://www.apache.org/licenses/LICENSE-2.0")
        case "mit", "mitlicense": return URL(string: "https://opensource.org/license/mit")
        default: return nil
        }
    }
}
