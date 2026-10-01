import Foundation
import LiteRTLM
import Ports

public enum GeneratorError: Error, LocalizedError, Equatable {
    case modelMissing(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let path): "The language model file was not found at \(path)."
        }
    }
}

public enum GeneratorBackend: Sendable {
    case gpu
    case cpu

    /// The GPU on devices. The iOS Simulator's Metal implementation cannot run the model (it allows too few
    /// texture bindings), so it falls back to the much slower CPU there.
    public static var platformDefault: GeneratorBackend {
        #if targetEnvironment(simulator)
        .cpu
        #else
        .gpu
        #endif
    }
}

/// Gemma 4 through LiteRT-LM, on the GPU (Metal) unless told otherwise. The engine loads on first use and stays resident;
/// requests are served one at a time. Each request is a fresh conversation, so no earlier question
/// leaks into an answer: the prompt already carries everything the model may use.
public final class LiteRTGenerator: Generator, @unchecked Sendable {
    private let modelPath: String
    private let cacheDirectory: String
    private let contextTokens: Int
    private let backend: GeneratorBackend
    private let holder = EngineHolder()
    private let queue = AsyncMutex()

    /// - Parameter contextTokens: KV-cache size; must fit the prompt plus the longest answer.
    public init(
        modelPath: String, cacheDirectory: String = NSTemporaryDirectory(), contextTokens: Int = 4096,
        backend: GeneratorBackend = .platformDefault
    ) {
        self.backend = backend
        self.modelPath = modelPath
        self.cacheDirectory = cacheDirectory
        self.contextTokens = contextTokens
    }

    /// Releases the model's memory after any running request finishes; it reloads on the next use.
    public func unload() async {
        await queue.withLock { await holder.reset() }
    }

    public func generate(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await queue.withLock {
                        try Task.checkCancellation()
                        let engine = try await holder.engine(path: modelPath, cache: cacheDirectory, contextTokens: contextTokens, backend: backend)
                        try await stream(request, on: engine, to: continuation)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func stream(
        _ request: GenerationRequest, on engine: Engine, to continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let conversation = try await engine.createConversation(with: ConversationConfig(
            systemMessage: Message(request.system, role: .system),
            samplerConfig: try SamplerConfig(topK: 40, topP: 0.95, temperature: request.temperature)))

        var produced = ""
        try await withTaskCancellationHandler {
            do {
                for try await chunk in conversation.sendMessageStream(Message(request.prompt), maxOutputTokens: request.maxTokens) {
                    let piece = chunk.toString
                    guard !piece.isEmpty else { continue }
                    produced += piece
                    if let cut = Self.stopIndex(in: produced, stops: request.stop) {
                        let keep = String(produced[..<cut])
                        let already = produced.count - piece.count
                        if keep.count > already { continuation.yield(String(keep.dropFirst(already))) }
                        try? conversation.cancel()
                        return
                    }
                    continuation.yield(piece)
                }
            } catch {
                // Stopping generation surfaces as a "CANCELLED" error from the runtime; that is a normal end.
                if Task.isCancelled || String(describing: error).contains("CANCELLED") { return }
                throw error
            }
        } onCancel: {
            try? conversation.cancel()
        }
    }

    static func stopIndex(in text: String, stops: [String]) -> String.Index? {
        stops.filter { !$0.isEmpty }.compactMap { text.range(of: $0)?.lowerBound }.min()
    }
}

/// Owns the engine so it is created once, lazily.
private actor EngineHolder {
    private var loaded: Engine?

    func engine(path: String, cache: String, contextTokens: Int, backend: GeneratorBackend) async throws -> Engine {
        if let loaded { return loaded }
        guard FileManager.default.fileExists(atPath: path) else { throw GeneratorError.modelMissing(path) }
        let engine = Engine(engineConfig: try EngineConfig(
            modelPath: path, backend: backend == .gpu ? .gpu : .cpu(), maxNumTokens: contextTokens, cacheDir: cache))
        try await engine.initialize()
        loaded = engine
        return engine
    }

    func reset() { loaded = nil }
}

/// A first-in, first-out async lock. (Actors are re-entrant, so they cannot serialize work that awaits.)
final class AsyncMutex: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    func withLock(_ body: @Sendable () async -> Void) async {
        await acquire()
        defer { release() }
        await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if locked {
                waiters.append(continuation)
                lock.unlock()
            } else {
                locked = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    private func release() {
        lock.lock()
        if waiters.isEmpty {
            locked = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}
