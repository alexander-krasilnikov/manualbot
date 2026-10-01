import Foundation
import Ports

/// Chooses an extractor by file type.
public struct FileDocumentExtractor: DocumentExtractor {
    public static let supportedExtensions: Set<String> = ["txt", "md", "markdown", "pdf", "docx"]

    public init() {}

    public static func documentType(for url: URL) -> DocumentType? {
        switch url.pathExtension.lowercased() {
        case "txt": .text
        case "md", "markdown": .markdown
        case "pdf": .pdf
        case "docx": .docx
        default: nil
        }
    }

    public func extract(from url: URL, events: @Sendable (ExtractionEvent) -> Void) async throws -> ExtractedDocument {
        switch Self.documentType(for: url) {
        case .text: try await TextExtractor(isMarkdown: false).extract(from: url, events: events)
        case .markdown: try await TextExtractor(isMarkdown: true).extract(from: url, events: events)
        case .pdf: try await PDFExtractor().extract(from: url, events: events)
        case .docx: try await DocxExtractor().extract(from: url, events: events)
        case nil: throw ExtractionError.unsupportedType(url.pathExtension.isEmpty ? "unknown" : url.pathExtension)
        }
    }
}
