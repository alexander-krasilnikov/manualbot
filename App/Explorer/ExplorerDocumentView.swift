import Foundation
import Ports
import SwiftUI
import UIKit

/// One top-level field of a stored document, classified for display.
struct DocumentField: Identifiable, Equatable {
    enum Value: Equatable {
        case text(String)
        /// The ID of a document in another collection.
        case reference(collection: String, id: String)
        /// A vector shortened for display, e.g. `[0.021, -0.113, … 256 values]`.
        case shortVector(String)
        case blob(contentType: String, length: Int, digest: String)
        /// Anything else (numbers, booleans, nested values) as JSON.
        case json(String)
    }

    let key: String
    let value: Value
    var id: String { key }

    /// The fields of the stored JSON that `storedDocument` returns, in key order.
    static func fields(from json: String) -> [DocumentField] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return [DocumentField(key: "document", value: .text(json))]
        }
        return object.keys.sorted().map { DocumentField(key: $0, value: classify(key: $0, object[$0] ?? NSNull())) }
    }

    private static func classify(key: String, _ value: Any) -> Value {
        if let text = value as? String {
            if let collection = ExplorerModel.collection(referencedBy: key), !text.isEmpty {
                return .reference(collection: collection, id: text)
            }
            if text.hasPrefix("["), text.hasSuffix(" values]") { return .shortVector(text) }
            return .text(text)
        }
        if let blob = value as? [String: Any], blob["@type"] as? String == "blob" {
            return .blob(
                contentType: blob["content_type"] as? String ?? "", length: (blob["length"] as? NSNumber)?.intValue ?? 0,
                digest: blob["digest"] as? String ?? "")
        }
        return .json(fragment(value, pretty: true))
    }

    /// `value` as JSON text, for nested values and for vectors shown in full.
    static func fragment(_ value: Any, pretty: Bool) -> String {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A stored document as highlighted JSON: references open the document they name, shortened vectors can be shown in
/// full, image and text blobs can be previewed next to their attributes, and a document record lists its chunks and
/// images.
struct DocumentView: View {
    let explorer: ExplorerModel
    let collection: String
    let id: String

    @State private var state: DocumentState?
    @State private var children: DocumentChildren?
    @State private var fullVectors: [String: [Any]] = [:]
    @State private var previews: [String: BlobContent] = [:]
    @State private var syncAttributesExpanded = false
    @State private var syncAttributes: SyncAttributesLoader

    private var documentIdentity: String { "\(collection)/\(id)" }

    init(explorer: ExplorerModel, collection: String, id: String) {
        self.explorer = explorer
        self.collection = collection
        self.id = id
        _syncAttributes = State(initialValue: SyncAttributesLoader(collection: collection, id: id))
    }

    var body: some View {
        Group {
            switch state {
            case nil:
                ProgressView()
            case .gone:
                ContentUnavailableView(
                    "This document no longer exists", systemImage: "trash",
                    description: Text("\(collection)/\(id) has been deleted."))
                    .accessibilityIdentifier("xrayDocumentGone")
            case .failed(let message):
                ContentUnavailableView("Cannot read this document", systemImage: "exclamationmark.triangle", description: Text(message))
            case .found(let json):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        syncAttributesSection
                        jsonView(json)
                        if let children, !(children.chunks.isEmpty && children.images.isEmpty) { childrenView(children) }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(json)
                    .accessibilityIdentifier("xrayStoredDocument")
                }
            }
        }
        .navigationTitle("\(collection)/\(id)")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: documentIdentity) {
            syncAttributesExpanded = false
            state = nil
            children = nil
            fullVectors = [:]
            previews = [:]
            state = await explorer.document(collection: collection, id: id)
            if collection == CollectionNames.documents { children = await explorer.children(of: id) }
        }
        .onAppear {
            if syncAttributesExpanded { Task { await syncAttributes.loadIfNeeded(using: explorer) } }
        }
        .onDisappear { syncAttributes.cancel() }
    }

    // MARK: Sync attributes

    private var syncAttributesSection: some View {
        DisclosureGroup(isExpanded: $syncAttributesExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                switch syncAttributes.state {
                case .idle:
                    EmptyView()
                case .loading:
                    ProgressView("Loading local sync attributes…")
                        .accessibilityIdentifier("explorerSyncAttributesLoading")
                case .loaded(let attributes):
                    Text(SyncAttributesJSON.highlight(attributes))
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("explorerSyncAttributesJSON")
                    Button("Copy Sync Attributes", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = SyncAttributesJSON.encode(attributes)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("explorerCopySyncAttributes")
                case .missing:
                    Text("This document no longer exists in the local database.")
                        .accessibilityIdentifier("explorerSyncAttributesMissing")
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cannot read sync attributes: \(message)")
                        Button("Retry", systemImage: "arrow.clockwise") {
                            Task { await syncAttributes.retry(using: explorer) }
                        }
                            .accessibilityIdentifier("explorerRetrySyncAttributes")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Sync attributes")
                .font(.headline)
                .accessibilityIdentifier("explorerSyncAttributes")
        }
        .onChange(of: syncAttributesExpanded) { _, expanded in
            if expanded { Task { await syncAttributes.loadIfNeeded(using: explorer) } }
        }
    }

    // MARK: JSON

    @ViewBuilder private func jsonView(_ json: String) -> some View {
        if let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
            let fields = DocumentField.fields(from: json)
            VStack(alignment: .leading, spacing: 2) {
                code(JSONHighlighter.punctuation("{"))
                ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                    fieldRow(field, raw: object[field.key] ?? NSNull(), last: index == fields.count - 1)
                }
                code(JSONHighlighter.punctuation("}"))
            }
            .contextMenu {
                Button("Copy JSON", systemImage: "doc.on.doc") { UIPasteboard.general.string = json }
            }
            // Its own element, or the identifier would replace those of the buttons inside.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("explorerJSON")
        } else {
            code(AttributedString(json))
        }
    }

    /// One top-level member: `"key": value,` with the value's own controls on the same line.
    @ViewBuilder private func fieldRow(_ field: DocumentField, raw: Any, last: Bool) -> some View {
        let lead = AttributedString(JSONHighlighter.padding(1)) + JSONHighlighter.key(field.key)
        let comma = JSONHighlighter.punctuation(last ? "" : ",")
        switch field.value {
        case .reference(let target, let targetID):
            // The key keeps its own width so the link follows it; the link's tap area runs to the end of the line.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(lead).font(.system(.callout, design: .monospaced)).fixedSize()
                Button { explorer.follow(collection: target, id: targetID) } label: {
                    (Text(JSONHighlighter.string(targetID)).underline() + Text(comma))
                        .font(.system(.callout, design: .monospaced)).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(target)/\(targetID)")
                .accessibilityIdentifier("explorerRef-\(field.key)")
            }
        case .shortVector(let text):
            if let full = fullVectors[field.key] {
                row(lead + JSONHighlighter.highlight(full, indent: 1) + comma) {
                    Button("Show shortened") { fullVectors[field.key] = nil }
                }
            } else {
                row(lead + JSONHighlighter.number(text) + comma) {
                    Button("Show all") { Task { await loadFull(field.key) } }
                        .accessibilityIdentifier("explorerShowFull-\(field.key)")
                }
            }
        case .blob(let type, _, _):
            VStack(alignment: .leading, spacing: 6) {
                row(lead + JSONHighlighter.highlight(raw, indent: 1) + comma) {
                    if previews[field.key] != nil {
                        Button("Hide preview", systemImage: "eye.slash") { previews[field.key] = nil }
                            .accessibilityIdentifier("explorerHidePreview-\(field.key)")
                    } else if type.hasPrefix("image/") || type.hasPrefix("text/") {
                        Button("Preview", systemImage: type.hasPrefix("image/") ? "photo" : "doc.text") {
                            Task { await loadPreview(field.key) }
                        }
                        .accessibilityIdentifier("explorerPreview-\(field.key)")
                    }
                }
                if let preview = previews[field.key] { blobPreview(preview).padding(.leading, 24) }
            }
        case .text, .json:
            code(lead + JSONHighlighter.highlight(raw, indent: 1) + comma)
        }
    }

    private func row(_ text: AttributedString, @ViewBuilder control: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            code(text)
            control().buttonStyle(.bordered).controlSize(.small).font(.caption)
        }
    }

    /// Not selectable: selectable text takes touches a little outside its own lines, which made the link on the line
    /// above dead wherever the text below it reached. The whole document is copied from the context menu instead.
    private func code(_ text: AttributedString) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func monospaced(_ text: String) -> some View { code(AttributedString(text)) }

    @ViewBuilder private func blobPreview(_ blob: BlobContent) -> some View {
        if blob.contentType.hasPrefix("image/"), let image = UIImage(data: blob.data) {
            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("explorerImagePreview")
        } else if blob.contentType.hasPrefix("text/") {
            // Only the start of a long text.
            monospaced(String(decoding: blob.data.prefix(64 * 1024), as: UTF8.self))
        }
    }

    private func childrenView(_ children: DocumentChildren) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Chunks and images").font(.headline)
            reference(list: children.chunks, title: "Chunks", collection: CollectionNames.chunks)
            reference(list: children.images, title: "Images", collection: CollectionNames.images)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explorerChildren")
    }

    @ViewBuilder private func reference(list: [String], title: String, collection: String) -> some View {
        if !list.isEmpty {
            DisclosureGroup("\(title) (\(list.count))") {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(list, id: \.self) { child in
                        Button { explorer.follow(collection: collection, id: child) } label: {
                            Text(child).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        }
                        .accessibilityIdentifier("explorerChild-\(child)")
                    }
                }
            }
        }
    }

    // MARK: Loading

    private func loadFull(_ key: String) async {
        guard case .found(let json) = await explorer.document(collection: collection, id: id, fullVectors: true),
            let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], let value = object[key] as? [Any]
        else { return }
        fullVectors[key] = value
    }

    private func loadPreview(_ key: String) async {
        if let blob = await explorer.blob(collection: collection, id: id, key: key) { previews[key] = blob }
    }
}
