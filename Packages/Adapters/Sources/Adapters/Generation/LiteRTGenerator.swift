import Foundation
import LiteRTLM
import Ports
import Synchronization

private let log = Diagnostics.generation

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
    private let seed: Int
    private let holder = EngineHolder()
    private let queue = AsyncMutex()
    /// Numbers requests in the log.
    private let requests = Atomic(0)

    /// The KV-cache size the app asks for. A language model that supports less cannot give full answers and is rejected.
    public static let defaultContextTokens = 4096

    /// - Parameter contextTokens: KV-cache size; must fit the prompt plus the longest answer.
    /// - Parameter seed: Seeds the sampler, so the same prompt gives the same answer. The answer evaluation depends on it.
    public init(
        modelPath: String, cacheDirectory: String = NSTemporaryDirectory(), contextTokens: Int = LiteRTGenerator.defaultContextTokens,
        backend: GeneratorBackend = .platformDefault, seed: Int = 0
    ) {
        self.seed = seed
        self.backend = backend
        self.modelPath = modelPath
        self.cacheDirectory = cacheDirectory
        self.contextTokens = contextTokens
    }

    /// Loads the model now instead of at the first question. Switching to another language model uses it, so that a model
    /// that cannot be loaded is found out at once and the previous one kept.
    public func warmUp() async throws {
        try await queue.withLock {
            _ = try await holder.engine(path: modelPath, cache: cacheDirectory, contextTokens: contextTokens, backend: backend)
        }
    }

    /// Releases the model's memory after any running request finishes; it reloads on the next use.
    public func unload() async {
        await queue.withLock { await holder.reset() }
    }

    public func generate(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let n = requests.add(1, ordering: .relaxed).newValue
            let queued = ContinuousClock.now
            log.notice("""
                request \(n): queued, system \(request.system.count) + prompt \(request.prompt.count) chars, \
                max \(request.maxTokens) tokens, temperature \(request.temperature, format: .fixed(precision: 1))
                """)
            let task = Task { [self] in
                do {
                    try await queue.withLock {
                        try Task.checkCancellation()
                        log.notice("request \(n): running after waiting \(Self.since(queued), privacy: .public)")
                        let engine = try await holder.engine(path: modelPath, cache: cacheDirectory, contextTokens: contextTokens, backend: backend)
                        try await stream(request, number: n, on: engine, to: continuation)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    log.notice("request \(n): cancelled before it ran")
                    continuation.finish()
                } catch {
                    log.error("request \(n): failed: \(String(describing: error), privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func stream(
        _ request: GenerationRequest, number n: Int, on engine: Engine,
        to continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let conversation = try await engine.createConversation(with: ConversationConfig(
            systemMessage: Message(request.system, role: .system),
            samplerConfig: try SamplerConfig(topK: 40, topP: 0.95, temperature: request.temperature, seed: seed)))
        log.notice("request \(n): conversation created, sending the prompt")

        let started = ContinuousClock.now
        var produced = ""
        var pieces = 0
        var ending = "end of stream"
        defer {
            log.notice("""
                request \(n): \(ending, privacy: .public) after \(Self.since(started), privacy: .public), \(pieces) pieces, \
                \(produced.count) chars
                """)
        }
        try await withTaskCancellationHandler {
            do {
                for try await chunk in conversation.sendMessageStream(Message(request.prompt), maxOutputTokens: request.maxTokens) {
                    let piece = chunk.toString
                    guard !piece.isEmpty else { continue }
                    if pieces == 0 { log.notice("request \(n): first piece after \(Self.since(started), privacy: .public)") }
                    pieces += 1
                    produced += piece
                    if let cut = Self.stopIndex(in: produced, stops: request.stop) {
                        let keep = String(produced[..<cut])
                        let already = produced.count - piece.count
                        if keep.count > already { continuation.yield(String(keep.dropFirst(already))) }
                        ending = "stop sequence"
                        try? conversation.cancel()
                        return
                    }
                    continuation.yield(piece)
                }
            } catch {
                // Stopping generation surfaces as a "CANCELLED" error from the runtime; that is a normal end.
                if Task.isCancelled || String(describing: error).contains("CANCELLED") { ending = "cancelled"; return }
                ending = "runtime error"
                throw error
            }
        } onCancel: {
            log.notice("request \(n): cancelling the conversation")
            try? conversation.cancel()
        }
    }

    /// `1.234s`, for the log.
    private static func since(_ start: ContinuousClock.Instant) -> String {
        String(format: "%.3fs", start.duration(to: .now).seconds)
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
        let started = ContinuousClock.now
        log.notice("""
            loading the model \((path as NSString).lastPathComponent, privacy: .public) on the \
            \(backend == .gpu ? "GPU" : "CPU", privacy: .public), \(contextTokens) context tokens
            """)
        let engine = Engine(engineConfig: try EngineConfig(
            modelPath: path, backend: backend == .gpu ? .gpu : .cpu(), maxNumTokens: contextTokens, cacheDir: cache))
        do {
            try await engine.initialize()
        } catch {
            log.error("the model failed to load: \(String(describing: error), privacy: .public)")
            throw error
        }
        log.notice("the model loaded in \(String(format: "%.3fs", started.duration(to: .now).seconds), privacy: .public)")
        loaded = engine
        return engine
    }

    func reset() {
        if loaded != nil { log.notice("unloading the model") }
        loaded = nil
    }
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
