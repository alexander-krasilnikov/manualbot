import Ports
import SwiftUI

/// What the preview cards can ask for. The workspace supplies them, so the cards stay free of models.
struct PreviewActions {
    /// Selects the chunk this many places away in the contents list.
    var step: (Int) -> Void = { _ in }
    /// Selects the chunk that stands for the previewed image.
    var showChunk: () -> Void = {}
    var showInDocument: (Citation) -> Void = { _ in }
    /// Opens the Database explorer at the shown record.
    var openInDatabase: (SourceViewerModel.DatabaseRecord) -> Void = { _ in }
}

/// Opens the Database explorer at the record behind what the source column shows.
struct OpenInDatabaseButton: View {
    let action: () -> Void

    var body: some View {
        Button("Open in Database", systemImage: "cylinder.split.1x2", action: action)
            .buttonStyle(.bordered).controlSize(.small)
            .accessibilityIdentifier("openInDatabase")
    }
}

// MARK: - Chunk

struct ChunkPreviewCard: View {
    let preview: SourceViewerModel.ChunkPreview
    let actions: PreviewActions
    var record: SourceViewerModel.DatabaseRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                facts
                Divider()
                Text(markedText).font(.body).textSelection(.enabled).accessibilityIdentifier("chunkText")
                if preview.leadingOverlap > 0 || preview.trailingOverlap > 0 { legend }
                HStack {
                    Button("Show in document", systemImage: "doc.text.magnifyingglass") { actions.showInDocument(preview.citation) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("showInDocument")
                    if let record { OpenInDatabaseButton { actions.openInDatabase(record) } }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chunkPreview")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preview.docTitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).accessibilityIdentifier("sourceTitle")
            HStack {
                Text("Chunk \(preview.entry.ordinal + 1) of \(preview.total)").font(.title2.bold()).accessibilityIdentifier("chunkPosition")
                if preview.entry.imageId != nil { Label("Photo", systemImage: "photo").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Previous", systemImage: "chevron.left") { actions.step(-1) }
                    .disabled(!preview.hasPrevious).accessibilityIdentifier("previousChunk")
                Button("Next", systemImage: "chevron.right") { actions.step(1) }
                    .disabled(!preview.hasNext).accessibilityIdentifier("nextChunk")
            }
            .labelStyle(.iconOnly).buttonStyle(.bordered)
        }
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            if let page = preview.entry.page { fact("Page", "\(page)") }
            if let heading = preview.entry.heading { fact("Heading", heading) }
            fact("Length", "\(preview.entry.text.count) characters")
            fact("Embedding", "\(preview.entry.embeddingModel) · \(preview.entry.dimension) dimensions")
        }
        .font(.callout)
    }

    private func fact(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    /// The chunk's text with the parts it shares with its neighbours tinted.
    private var markedText: AttributedString {
        let text = preview.entry.text
        let leadingEnd = text.index(text.startIndex, offsetBy: min(preview.leadingOverlap, text.count))
        let trailingStart = text.index(text.endIndex, offsetBy: -min(preview.trailingOverlap, text.count))
        guard leadingEnd <= trailingStart else { return AttributedString(text) }
        var result = AttributedString()
        func add(_ part: Substring, tinted: Bool) {
            var piece = AttributedString(part)
            if tinted { piece.backgroundColor = Color.blue.opacity(0.22) }
            result += piece
        }
        add(text[..<leadingEnd], tinted: true)
        add(text[leadingEnd..<trailingStart], tinted: false)
        add(text[trailingStart...], tinted: true)
        return result
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            if preview.leadingOverlap > 0 { Label("The start repeats the end of the previous chunk", systemImage: "arrow.up.left") }
            if preview.trailingOverlap > 0 { Label("The end is repeated at the start of the next chunk", systemImage: "arrow.down.right") }
        }
        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("chunkOverlapLegend")
    }
}

// MARK: - Image

struct ImagePreviewCard: View {
    let preview: SourceViewerModel.ImagePreview
    let actions: PreviewActions
    var record: SourceViewerModel.DatabaseRecord?
    @State private var image: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(preview.docTitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).accessibilityIdentifier("sourceTitle")
                Text("Image \(preview.entry.n + 1)").font(.title2.bold())
                Group {
                    if let image {
                        ZoomableImage(image: image).accessibilityIdentifier("previewImage").accessibilityLabel(preview.entry.caption ?? "Image")
                    } else {
                        ContentUnavailableView("The image cannot be shown", systemImage: "photo.badge.exclamationmark")
                    }
                }
                .frame(height: 360).background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                facts
                HStack {
                    if preview.hasChunk {
                        Button("Show chunk", systemImage: "text.alignleft") { actions.showChunk() }
                            .buttonStyle(.bordered).accessibilityIdentifier("showChunk")
                    }
                    Button("Show in document", systemImage: "doc.text.magnifyingglass") { actions.showInDocument(preview.citation) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("showInDocument")
                    if let record { OpenInDatabaseButton { actions.openInDatabase(record) } }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: preview.entry.id) { image = UIImage(data: preview.data) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("imagePreview")
    }

    private var facts: some View {
        let entry = preview.entry
        return Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
            fact("Size", "\(entry.width) × \(entry.height) pixels")
            if let page = entry.page { fact("Page", "\(page)") }
            if let heading = entry.heading { fact("Heading", heading) }
            fact("Caption", caption)
            fact("Text in the image", entry.ocrText.isEmpty ? "None recognized" : entry.ocrText)
        }
        .font(.callout)
    }

    private var caption: String {
        guard let caption = preview.entry.caption, !caption.isEmpty else { return "None" }
        switch preview.entry.captionSource {
        case .nearby: return "\(caption) (from nearby text)"
        case .alt: return "\(caption) (from the alt text)"
        case .none: return caption
        }
    }

    private func fact(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
