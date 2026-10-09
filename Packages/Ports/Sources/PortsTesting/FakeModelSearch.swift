import Foundation
import Ports
import Synchronization

/// A search that returns what it was given, or fails the way it was told to.
public final class FakeModelSearch: ModelSearching {
    private struct State {
        var results: [ModelSpec] = []
        var error: (any Error)?
        var queries: [String] = []
    }
    private let state = Mutex(State())

    public init(results: [ModelSpec] = []) { state.withLock { $0.results = results } }

    public func setResults(_ results: [ModelSpec]) { state.withLock { $0.results = results } }
    public func fail(with error: any Error) { state.withLock { $0.error = error } }
    public var queries: [String] { state.withLock { $0.queries } }

    public func search(_ text: String) async throws -> [ModelSpec] {
        let (results, error) = state.withLock { s -> ([ModelSpec], (any Error)?) in
            s.queries.append(text)
            return (s.results, s.error)
        }
        if let error { throw error }
        return results
    }
}

/// A header probe with scripted answers. A file it was not told about reads as "not a LiteRT-LM file".
public final class FakeHeaderProbe: ModelHeaderProbing {
    private struct State {
        var headers: [URL: ModelHeader] = [:]
        var unreachable: Set<URL> = []
        var probed: [URL] = []
    }
    private let state = Mutex(State())

    public init() {}

    public func set(_ header: ModelHeader, for url: URL) { state.withLock { $0.headers[url] = header } }
    public func makeUnreachable(_ url: URL) { state.withLock { _ = $0.unreachable.insert(url) } }
    /// Every file that was probed, in the order the probes arrived.
    public var probed: [URL] { state.withLock { $0.probed } }

    public func probe(_ url: URL) async throws -> ModelHeader {
        let (header, unreachable) = state.withLock { s -> (ModelHeader, Bool) in
            s.probed.append(url)
            return (s.headers[url] ?? .unknown, s.unreachable.contains(url))
        }
        if unreachable { throw FakeModelBackend.FakeError(message: "unreachable") }
        return header
    }
}
