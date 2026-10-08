import Ports
import SwiftUI

/// What the library sidebar shows for one document: its chunks or its images, in sections, one selected.
struct DocumentContentsView: View {
    let model: DocumentContentsModel
    /// The document's library entry, or `nil` once it has been deleted.
    let item: LibraryViewModel.Item?

    var body: some View {
        List {
            switch model.kind {
            case .chunks:
                ForEach(model.chunkSections) { section in
                    Section(section.title) {
                        ForEach(section.entries) { chunk in
                            ChunkRow(chunk: chunk, isSelected: model.selection == .chunk(chunk.id)) { model.select(.chunk(chunk.id)) }
                        }
                    }
                }
            case .images:
                ForEach(model.imageSections) { section in
                    Section(section.title) {
                        ForEach(section.entries) { image in
                            ImageRow(image: image, isSelected: model.selection == .image(image.id),
                                     load: { await model.displayCopy(for: image.id) }) { model.select(.image(image.id)) }
                        }
                    }
                }
            }
        }
        .overlay { placeholder }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Contents", selection: Bindable(model).kind) {
                Text("Chunks \(model.chunks.count)").tag(DocumentContentsModel.Kind.chunks)
                Text("Images \(model.images.count)").tag(DocumentContentsModel.Kind.images)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)
            .accessibilityIdentifier("contentsKind")
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        // Loads when the view appears, and again when a re-index of the document finishes.
        .task(id: item?.status.isUpdating ?? false) {
            let updating = item?.status.isUpdating ?? false
            guard !updating || model.phase == .loading else { return }
            await model.load()
        }
    }

    @ViewBuilder private var placeholder: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView("Cannot read the contents", systemImage: "exclamationmark.triangle", description: Text(message))
        case .loaded:
            if model.kind == .images, model.images.isEmpty {
                ContentUnavailableView("No images", systemImage: "photo.on.rectangle", description: Text("This document has no images."))
                    .accessibilityIdentifier("contentsEmpty")
            } else if model.kind == .chunks, model.chunks.isEmpty {
                ContentUnavailableView("No chunks", systemImage: "text.alignleft", description: Text("This document has no searchable text."))
                    .accessibilityIdentifier("contentsEmpty")
            }
        }
    }
}

private struct ChunkRow: View {
    let chunk: ChunkEntry
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(chunk.ordinal + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 28, alignment: .trailing)
                Text(chunk.text).font(.callout).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if chunk.imageId != nil { Image(systemName: "photo").foregroundStyle(.tint).accessibilityLabel("Stands for a photo") }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.18) : nil)
        .accessibilityIdentifier("chunkRow-\(chunk.ordinal)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ImageRow: View {
    let image: ImageEntry
    let isSelected: Bool
    let load: () async -> Data?
    let onSelect: () -> Void
    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 56, height: 56).background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Image \(image.n + 1)").font(.callout.weight(.medium))
                    if let caption = image.caption, !caption.isEmpty {
                        Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.18) : nil)
        .task(id: image.id) { if let data = await load() { thumbnail = UIImage(data: data) } }
        .accessibilityIdentifier("imageRow-\(image.n)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
