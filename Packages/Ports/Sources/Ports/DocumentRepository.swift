import Foundation

public protocol DocumentRepository: Sendable {
    func upsert(_ document: DocumentRecord) async throws
    func document(id: String) async throws -> DocumentRecord?
    func documents() async throws -> [DocumentRecord]

    /// Writes chunks by ID. Writing a chunk that already exists overwrites it.
    func writeChunks(_ chunks: [Chunk]) async throws
    func chunks(docId: String, generation: Int) async throws -> [Chunk]
    /// Chunks of the document's active generation. Empty until a generation has been activated.
    func activeChunks(docId: String) async throws -> [Chunk]

    /// Makes `generation` the document's active generation, then removes the chunks of every other
    /// generation. The switch is atomic: readers see either the old set or the new set.
    func activate(generation: Int, for docId: String) async throws

    /// Stores a copy of the imported original file with the document.
    func attachOriginal(fileURL: URL, contentType: String, to docId: String) async throws
    /// A readable file copy of the stored original (materialized on demand by the repository),
    /// or `nil` if the document has none.
    func originalFileURL(docId: String) async throws -> URL?

    /// Removes the document, its stored original, and all of its chunks in one operation.
    func deleteDocument(id: String) async throws
}
