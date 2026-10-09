import Foundation
import Ports
import Synchronization

/// Accepts every model unless told to reject it, so store tests can check what happens after a rejection.
public final class FakeModelValidator: ModelValidating {
    private let rejections = Mutex<[String: ModelValidationError]>([:])

    public init() {}

    public func reject(_ id: String, with error: ModelValidationError) {
        rejections.withLock { $0[id] = error }
    }

    @discardableResult
    public func validate(_ file: URL, for spec: ModelSpec) throws -> ModelDescription {
        if let error = rejections.withLock({ $0[spec.id] }) { throw error }
        // An embedding model reports a vector size, as a real file does, so an untested one can be given generic settings.
        return spec.role == .embedder
            ? ModelDescription(kind: .embedder, embeddingDimension: 768, embeddingInputLengths: [128, 256, 512])
            : ModelDescription(kind: .llm)
    }
}
