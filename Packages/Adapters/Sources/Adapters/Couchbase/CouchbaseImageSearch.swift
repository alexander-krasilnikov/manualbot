@preconcurrency import CouchbaseLiteSwift
import Foundation
import Ports

/// Search over the images of each ready document's active generation, on the same pattern as chunk
/// search: the index is queried unfiltered, and visibility is decided from the image ID (it encodes
/// `docId:generation:img:n`), widening the candidate window when too few survive.
extension CouchbaseDocumentRepository: ImageSearching {
    public func imageSearch(_ vector: [Float], limit: Int, filter: SearchFilter) throws -> [ScoredImage] {
        guard limit > 0 else { return [] }
        let visible = try visibleGenerations(for: filter)
        guard !visible.isEmpty else { return [] }
        return try search(
            in: collections.images, limit: limit, visible: visible, requireModel: filter.embeddingModel, purpose: TraceContext.imageQueryIsWords ? .imageByWords : .image,
            parseID: { ImageRecord.parseID($0).map { ($0.docId, $0.generation) } },
            load: { try Self.image(from: $0) }, model: \.featureModel
        ) { window, parameters in
            parameters.setValue(vector, forName: "vector")
            let sql = """
                SELECT meta().id AS id, APPROX_VECTOR_DISTANCE(features, $vector, "cosine") AS score
                FROM \(CouchbaseSchema.scope).images
                ORDER BY APPROX_VECTOR_DISTANCE(features, $vector, "cosine")
                LIMIT \(window)
                """
            return (sql, tracer.isEnabled ? ["vector": TraceFormat.shorten(vector)] : [:])
        }.map { ScoredImage(image: $0.value, score: $0.score) }
    }
}
