import Foundation
import Ports

/// Collects trace events while demo mode is on and hands them to the X-ray model. Does nothing while off.
final class DemoTracer: Tracer, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private let continuation: AsyncStream<TraceEvent>.Continuation
    /// Every recorded event, in order. One consumer only: the X-ray model.
    let events: AsyncStream<TraceEvent>

    init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    func record(_ event: TraceEvent) {
        guard isEnabled else { return }
        continuation.yield(event)
    }
}
