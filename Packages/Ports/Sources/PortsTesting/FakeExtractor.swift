import Foundation
import Ports
import Synchronization

/// Returns canned documents keyed by file name, and emits scripted extraction events.
public final class FakeExtractor: DocumentExtractor {
    private let results: Mutex<[String: Result<ExtractedDocument, Error>]>
    private let events: [String: [ExtractionEvent]]
    private let calls = Mutex<[String]>([])

    public init(results: [String: Result<ExtractedDocument, Error>], events: [String: [ExtractionEvent]] = [:]) {
        self.results = Mutex(results)
        self.events = events
    }

    public var extractedFiles: [String] { calls.withLock { $0 } }

    public func extract(from url: URL, events emit: @Sendable (ExtractionEvent) -> Void) async throws -> ExtractedDocument {
        let name = url.lastPathComponent
        calls.withLock { $0.append(name) }
        for event in events[name] ?? [] { emit(event) }
        guard let result = results.withLock({ $0[name] }) else { throw ExtractionError.unreadable("no fixture for \(name)") }
        return try result.get()
    }
}
