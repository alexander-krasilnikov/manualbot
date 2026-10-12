import Foundation
import Ports

/// Keeps every event it is given, in order. Enabled by default; flip `isEnabled` to test the off path.
public final class RecordingTracer: Tracer, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TraceEvent] = []
    private var enabled: Bool

    public init(isEnabled: Bool = true) { enabled = isEnabled }

    public var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    public func record(_ event: TraceEvent) { lock.withLock { stored.append(event) } }

    public var events: [TraceEvent] { lock.withLock { stored } }
    public var kinds: [TraceKind] { events.map(\.kind) }

    /// The recorded queries, in order.
    public var queries: [(event: TraceEvent, trace: QueryTrace)] {
        events.compactMap { event in
            if case .query(let trace) = event.kind { return (event, trace) }
            return nil
        }
    }
}
