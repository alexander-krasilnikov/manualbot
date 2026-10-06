import Foundation

/// Runs blocking Vision requests on one dedicated serial queue instead of the Swift concurrency pool.
///
/// `VNImageRequestHandler.perform` blocks its thread until the request is done. Called from `Task.detached`,
/// many at once, it filled every thread of the cooperative pool and the requests then waited for each other
/// (observed as a test run that never finished). One request at a time also keeps the Neural Engine and memory
/// use predictable while documents are being indexed.
enum VisionQueue {
    private static let queue = DispatchQueue(label: "manualbot.vision", qos: .utility)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}
