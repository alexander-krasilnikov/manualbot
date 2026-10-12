import Foundation
import Ports
import PortsTesting
import Testing

@Suite struct TracingTests {
    private let op = TraceOperation(id: "ask-1", kind: .ask, title: "What is E-042?")

    private actor Hop {
        func current() -> TraceOperation? { TraceContext.operation }
    }

    @Test func operationReachesAsyncLetChildrenAndActorHops() async {
        let hop = Hop()
        let (child, viaActor, outside) = await TraceContext.$operation.withValue(op) {
            async let child = TraceContext.operation
            async let viaActor = hop.current()
            return await (child, viaActor, TraceContext.operation)
        }
        #expect(child == op)
        #expect(viaActor == op)
        #expect(outside == op)
        #expect(TraceContext.operation == nil)
    }

    @Test func emitStampsTheCurrentOperation() {
        let tracer = RecordingTracer()
        TraceContext.$operation.withValue(op) { tracer.emit(.queryEmbedded(dimensions: 768)) }
        tracer.emit(.queryEmbedded(dimensions: 768))
        #expect(tracer.events.map(\.operation) == [op, nil])
    }

    @Test func disabledTracerNeverBuildsTheEvent() {
        let tracer = RecordingTracer(isEnabled: false)
        var built = false
        // The kind is an autoclosure, so a disabled tracer must not evaluate it.
        tracer.emit(.queryEmbedded(dimensions: { built = true; return 1 }()))
        #expect(!built)
        #expect(tracer.events.isEmpty)
        #expect(!NoTracer().isEnabled)
    }

    @Test func measureRecordsDurationOfTheBody() async throws {
        let tracer = RecordingTracer()
        let value = try await tracer.measure(
            { try await Task.sleep(for: .milliseconds(20)); return 7 }, event: { .queryEmbedded(dimensions: $0) })
        #expect(value == 7)
        #expect((tracer.events.first?.duration ?? 0) >= 0.015)
    }

    @Test func shortenKeepsFourValuesAndTheLength() {
        let vector = (0..<768).map { Float($0) / 1000 }
        #expect(TraceFormat.shorten(vector) == "[0.000, 0.001, 0.002, 0.003, … 768 values]")
        #expect(TraceFormat.shorten([0.5, 0.25]) == "[0.500, 0.250]")
    }
}
