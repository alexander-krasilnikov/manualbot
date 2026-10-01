import Ports
import Synchronization

/// A generator that replays scripted fragments and records how it was used.
public final class ScriptedGenerator: Generator {
    private struct State {
        var requests: [GenerationRequest] = []
        var cancellations = 0
    }

    private let script: @Sendable (GenerationRequest) -> [String]
    private let state = Mutex(State())

    public init(script: @escaping @Sendable (GenerationRequest) -> [String]) {
        self.script = script
    }

    public convenience init(fragments: [String]) {
        self.init { _ in fragments }
    }

    public var requests: [GenerationRequest] { state.withLock { $0.requests } }
    public var callCount: Int { state.withLock { $0.requests.count } }
    /// Number of streams that were ended before the script finished.
    public var cancellationCount: Int { state.withLock { $0.cancellations } }

    public func generate(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error> {
        state.withLock { $0.requests.append(request) }
        let fragments = script(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for fragment in fragments {
                    if Task.isCancelled { return }
                    continuation.yield(fragment)
                    await Task.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { [self] reason in
                if case .cancelled = reason {
                    state.withLock { $0.cancellations += 1 }
                    task.cancel()
                }
            }
        }
    }
}
