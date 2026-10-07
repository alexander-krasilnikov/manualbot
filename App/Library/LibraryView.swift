import Ports
import SwiftUI
import UniformTypeIdentifiers

/// A file received by drag and drop, copied somewhere the app may read after the drop finishes.
struct DroppedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drops-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return DroppedFile(url: copy)
        }
    }
}

enum SupportedTypes {
    static let picker: [UTType] = {
        var types: [UTType] = [.plainText, .pdf, .jpeg, .png, .heic, .heif]
        for ext in ["docx", "md", "markdown"] { if let t = UTType(filenameExtension: ext) { types.append(t) } }
        return types
    }()
}

struct LibraryView: View {
    let library: LibraryViewModel
    /// Opens the database explorer.
    var onOpenExplorer: (() -> Void)?
    let onOpen: (String) -> Void

    @State private var importing = false
    @State private var renaming: LibraryViewModel.Item?
    @State private var newName = ""
    @State private var deleting: LibraryViewModel.Item?
    @State private var isDropTargeted = false
    @State private var showAbout = false

    var body: some View {
        List {
            if !library.rejections.isEmpty {
                Section {
                    ForEach(library.rejections, id: \.self) { Label($0, systemImage: "xmark.octagon").font(.callout).foregroundStyle(.red) }
                    Button("Dismiss") { library.dismissRejections() }
                }
                .accessibilityIdentifier("importRejections")
            }
            ForEach(library.items) { item in
                Button { onOpen(item.id) } label: {
                    LibraryRow(item: item, loadThumbnail: { await library.thumbnail(for: item.id) }) { Task { await library.retry(item.id) } }
                }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("doc-\(item.title)")
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { newName = item.title; renaming = item }
                        Button("Re-index", systemImage: "arrow.triangle.2.circlepath") { Task { await library.reindex(item.id) } }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { deleting = item }
                        Button("Rename") { newName = item.title; renaming = item }.tint(.blue)
                    }
            }
        }
        .overlay {
            if library.items.isEmpty {
                ContentUnavailableView {
                    Label("No documents yet", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Import PDF, Word, text or photo files, or drop them here. Everything stays on this iPad.")
                } actions: {
                    Button("Import documents") { importing = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .overlay { if isDropTargeted { RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, lineWidth: 3).padding(6) } }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItemGroup {
                if let onOpenExplorer {
                    Button("Database", systemImage: "cylinder.split.1x2", action: onOpenExplorer)
                        .accessibilityIdentifier("explorerButton")
                }
                Button("About", systemImage: "info.circle") { showAbout = true }.accessibilityIdentifier("aboutButton")
                Button("Import", systemImage: "plus") { importing = true }.accessibilityIdentifier("importButton")
            }
        }
        .sheet(isPresented: $showAbout) { AboutView() }
        .fileImporter(isPresented: $importing, allowedContentTypes: SupportedTypes.picker, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await library.importFiles(urls) } }
        }
        .dropDestination(for: DroppedFile.self, action: { files, _ in
            Task { await library.importFiles(files.map(\.url)) }
            return !files.isEmpty
        }, isTargeted: { isDropTargeted = $0 })
        .alert("Rename document", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newName).accessibilityIdentifier("renameField")
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let item = renaming { Task { await library.rename(item.id, to: newName) } } }
        }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let item = deleting { Task { await library.delete(item.id) } } }
        } message: {
            Text("The document and its search index are removed from this iPad. Earlier answers keep their quoted passages.")
        }
    }
}

struct LibraryRow: View {
    let item: LibraryViewModel.Item
    let loadThumbnail: () async -> Data?
    let onRetry: () -> Void
    @State private var thumbnail: Data?

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline).lineLimit(2)
                statusView
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.type == .image && thumbnail != nil ? "thumbnail shown" : "")
    }

    /// A photo document shows its picture; everything else shows an icon for its type.
    @ViewBuilder private var leading: some View {
        if item.type == .image {
            Group {
                if let thumbnail, let image = UIImage(data: thumbnail) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: icon).font(.title2).foregroundStyle(.tint)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: item.status) { if item.status.isReady { thumbnail = await loadThumbnail() } }
            .accessibilityIdentifier("thumbnail-\(item.title)")
        } else {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 32)
        }
    }

    private var icon: String {
        switch item.type {
        case .pdf: "doc.richtext"
        case .docx: "doc.text"
        case .markdown, .text: "text.alignleft"
        case .image: "photo"
        }
    }

    @ViewBuilder private var statusView: some View {
        switch item.status {
        case .ready:
            Text(readySubtitle).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("status-ready")
        case .queued:
            Text("Waiting…").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("status-queued")
        case .extracting(let p):
            progress("Reading", p)
        case .recognizing(let p):
            progress("Recognizing text", p)
        case .analyzing(let p):
            progress("Analyzing photos", p)
        case .embedding(let p):
            progress("Indexing", p)
        case .updating(let p):
            progress("Updating index", p)
        case .failed(let reason):
            HStack {
                Label(reason, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).lineLimit(2)
                Button("Retry", action: onRetry).buttonStyle(.bordered).controlSize(.small)
            }
            .accessibilityIdentifier("status-failed")
        }
    }

    private var readySubtitle: String {
        var parts = [Self.label(for: item.type)]
        if let pages = item.pageCount { parts.append("\(pages) page\(pages == 1 ? "" : "s")") }
        if item.type != .image, item.imageCount > 0 { parts.append("\(item.imageCount) photo\(item.imageCount == 1 ? "" : "s")") }
        parts.append(item.importedAt.formatted(date: .abbreviated, time: .omitted))
        return "Ready · " + parts.joined(separator: " · ")
    }

    static func label(for type: DocumentType) -> String {
        switch type {
        case .docx: "Word"
        case .pdf: "PDF"
        case .markdown: "Markdown"
        case .text: "Text"
        case .image: "Photo"
        }
    }

    private func progress(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: value).progressViewStyle(.linear)
            Text("\(label) \(Int(value * 100))%").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("status-working")
    }
}
