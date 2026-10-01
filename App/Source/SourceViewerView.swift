import PDFKit
import Ports
import SwiftUI

struct SourceViewerView: View {
    let source: SourceViewerModel

    var body: some View {
        Group {
            switch source.content {
            case .none:
                ContentUnavailableView("No source open", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Tap a source under an answer, or a document in the library, to read it here."))
                    .accessibilityIdentifier("sourceEmpty")
            case .pdf(let url, let page, let passage, let title):
                PDFSource(url: url, page: page, passage: passage, title: title, openCount: source.openCount)
            case .text(let title, let paragraphs, let highlighted):
                TextSource(title: title, paragraphs: paragraphs, highlighted: highlighted, openCount: source.openCount)
            case .deleted(let citation):
                DeletedSource(citation: citation)
            case .unavailable(let title, let reason):
                ContentUnavailableView(title, systemImage: "exclamationmark.triangle", description: Text(reason))
            }
        }
        .overlay { if source.isLoading { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
        .navigationTitle("Source")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - PDF

private struct PDFSource: View {
    let url: URL
    let page: Int
    let passage: String
    let title: String
    let openCount: Int
    @State private var highlighted = false
    @State private var pageCount = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(1).accessibilityIdentifier("sourceTitle")
                Spacer()
                if highlighted {
                    Label("Passage highlighted", systemImage: "highlighter").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("passageHighlighted")
                }
                Text("Page \(page)\(pageCount > 0 ? " of \(pageCount)" : "")").font(.subheadline.monospacedDigit())
                    .accessibilityIdentifier("sourcePage")
            }
            .padding(.horizontal).padding(.vertical, 8)
            Divider()
            PDFKitView(url: url, page: page, passage: passage, openCount: openCount) { found, count in
                highlighted = found
                pageCount = count
            }
        }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let url: URL
    let page: Int
    let passage: String
    let openCount: Int
    let onResolved: (_ highlighted: Bool, _ pageCount: Int) -> Void

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
        guard let document = view.document else { return }
        let index = min(max(page - 1, 0), max(document.pageCount - 1, 0))
        guard let target = document.page(at: index) else { return }

        view.highlightedSelections = nil
        var found = false
        if let selection = Self.selection(for: passage, on: target, in: document) {
            selection.color = UIColor.systemYellow.withAlphaComponent(0.55)
            view.highlightedSelections = [selection]
            view.go(to: selection)
            found = true
        } else {
            view.go(to: PDFDestination(page: target, at: CGPoint(x: 0, y: target.bounds(for: .cropBox).height)))
        }
        let count = document.pageCount
        DispatchQueue.main.async { onResolved(found, count) }
    }

    /// The passage may span line breaks that PDF search does not see, so search for its opening words,
    /// shortening the phrase until something on the cited page matches.
    static func selection(for passage: String, on page: PDFPage, in document: PDFDocument) -> PDFSelection? {
        let words = passage.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        for count in [10, 6, 4, 3, 2] where words.count >= min(count, words.count) {
            let phrase = words.prefix(count).joined(separator: " ")
            let matches = document.findString(phrase, withOptions: [.caseInsensitive])
            if let onPage = matches.first(where: { $0.pages.contains(page) }) { return onPage }
        }
        return nil
    }
}

// MARK: - Text

private struct TextSource: View {
    let title: String
    let paragraphs: [SourceViewerModel.Paragraph]
    let highlighted: Set<Int>
    let openCount: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text(title).font(.title2.bold()).accessibilityIdentifier("sourceTitle")
                    ForEach(paragraphs) { paragraph in
                        Text(paragraph.text)
                            .font(paragraph.isHeading ? .headline : .body)
                            .padding(highlighted.contains(paragraph.id) ? 8 : 0)
                            .background(highlighted.contains(paragraph.id) ? Color.yellow.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(paragraph.id)
                            .accessibilityIdentifier(highlighted.contains(paragraph.id) ? "highlightedPassage" : "paragraph-\(paragraph.id)")
                    }
                }
                .padding()
            }
            .task(id: openCount) {
                if let first = highlighted.min() {
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation { proxy.scrollTo(first, anchor: .center) }
                }
            }
        }
    }
}

// MARK: - Deleted

private struct DeletedSource: View {
    let citation: Citation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("This document was deleted. Only the quoted passage remains.", systemImage: "trash")
                    .foregroundStyle(.orange).accessibilityIdentifier("documentDeleted")
                Text(citation.docTitle).font(.title3.bold())
                if let page = citation.page { Text("Page \(page)").foregroundStyle(.secondary) }
                Text(citation.snippet).padding(12).background(Color.yellow.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("highlightedPassage")
            }
            .padding()
        }
    }
}
