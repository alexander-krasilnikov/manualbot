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

    /// Makes `generation` the document's active generation, then removes the chunks and images of every other
    /// generation. The switch is atomic: readers see either the old set or the new set.
    func activate(generation: Int, for docId: String) async throws

    /// Chunks of the active generation on `page`, or under `heading`. Empty until a generation has been activated.
    func activeChunks(docId: String, page: Int) async throws -> [Chunk]
    func activeChunks(docId: String, heading: String) async throws -> [Chunk]

    /// Writes images with their display copies by ID in one transaction. Writing an image that already exists overwrites it.
    func writeImages(_ writes: [ImageWrite]) async throws
    func images(docId: String, generation: Int) async throws -> [ImageRecord]
    /// Images of the document's active generation. Empty until a generation has been activated.
    func activeImages(docId: String) async throws -> [ImageRecord]
    func activeImages(docId: String, page: Int) async throws -> [ImageRecord]
    func activeImages(docId: String, heading: String) async throws -> [ImageRecord]
    /// The stored display copy (JPEG) of an image, or `nil` if it no longer exists.
    func imageData(id: String) async throws -> Data?

    /// Stores a copy of the imported original file with the document.
    func attachOriginal(fileURL: URL, contentType: String, to docId: String) async throws
    /// A readable file copy of the stored original (materialized on demand by the repository),
    /// or `nil` if the document has none.
    func originalFileURL(docId: String) async throws -> URL?

    /// IDs of the documents whose active generation holds a chunk embedded by a model other than `textModel`, or an image
    /// whose vector came from a model other than `imageModel` (both are model tags). Documents without an active generation
    /// are not included: they have nothing searchable yet.
    func documentIDs(notEmbeddedBy textModel: String, imageModel: String) async throws -> [String]

    /// Removes the document, its stored original, and all of its chunks and images in one operation.
    func deleteDocument(id: String) async throws
}
