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

/// A stored document, field by field: references open the document they name, shortened vectors can be shown in full,
/// image and text blobs can be previewed, and a document record lists its chunks and images.
struct DocumentView: View {
    let explorer: ExplorerModel
    let collection: String
    let id: String

    @State private var state: DocumentState?
    @State private var children: DocumentChildren?
    @State private var fullVectors: [String: String] = [:]
    @State private var previews: [String: BlobContent] = [:]

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
                        ForEach(DocumentField.fields(from: json)) { field in fieldView(field) }
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
        .task {
            state = await explorer.document(collection: collection, id: id)
            if collection == CollectionNames.documents { children = await explorer.children(of: id) }
        }
    }

    // MARK: Fields

    @ViewBuilder private func fieldView(_ field: DocumentField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.key).font(.caption).foregroundStyle(.secondary)
            switch field.value {
            case .text(let text):
                monospaced(text)
            case .json(let text):
                monospaced(text)
            case .reference(let target, let targetID):
                Button { explorer.follow(collection: target, id: targetID) } label: {
                    Label("\(target)/\(targetID)", systemImage: "arrow.turn.down.right")
                        .font(.system(.callout, design: .monospaced))
                }
                .accessibilityIdentifier("explorerRef-\(field.key)")
            case .shortVector(let text):
                if let full = fullVectors[field.key] {
                    monospaced(full)
                    Button("Show shortened") { fullVectors[field.key] = nil }
                } else {
                    monospaced(text)
                    Button("Show in full") { Task { await loadFull(field.key) } }
                        .accessibilityIdentifier("explorerShowFull-\(field.key)")
                }
            case .blob(let type, let length, let digest):
                monospaced("\(type) · \(ByteCountFormatter.string(fromByteCount: Int64(length), countStyle: .file))\n\(digest)")
                if let preview = previews[field.key] {
                    blobPreview(preview)
                } else if type.hasPrefix("image/") || type.hasPrefix("text/") {
                    Button("Preview") { Task { await loadPreview(field.key) } }
                        .accessibilityIdentifier("explorerPreview-\(field.key)")
                }
            }
        }
    }

    private func monospaced(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

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
            let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], let value = object[key]
        else { return }
        fullVectors[key] = DocumentField.fragment(value, pretty: false)
    }

    private func loadPreview(_ key: String) async {
        if let blob = await explorer.blob(collection: collection, id: id, key: key) { previews[key] = blob }
    }
}
