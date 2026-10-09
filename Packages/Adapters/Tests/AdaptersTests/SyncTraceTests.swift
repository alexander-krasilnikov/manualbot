@preconcurrency import CouchbaseLiteSwift
import Foundation
import Ports
import PortsTesting
import Testing
@testable import Adapters

/// What the X-ray is told while the library replicates (database-xray spec: Sync events).
@Suite(.serialized) struct SyncTraceTests {
    private func syncEvents(_ tracer: RecordingTracer) -> [TraceEvent] {
        tracer.events.filter { $0.operation?.kind == .sync }
    }

    @Test func replicationIsReportedInGroupsOfItsOwnKind() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let tracer = RecordingTracer()
        let a = try SyncDevice(tracer: tracer); defer { Task { await a.cleanUp() } }
        try await a.importDocument("d1", title: "Pump manual", chunks: 3, images: 1)
        await a.sync.start(server.configuration)
        try await eventually("the library on the server") { try server.count("chunks") == 3 }
        try await waitForState(a.sync, .upToDate)
        try await Task.sleep(for: .milliseconds(500))

        let events = syncEvents(tracer)
        let states = events.compactMap { event -> String? in if case .syncState(let text) = event.kind { text } else { nil } }
        #expect(states.first == "connecting")
        #expect(states.contains("up to date"))

        var pushed: [String: Int] = [:]
        for event in events {
            if case .syncReplicated(let collection, let count, true) = event.kind { pushed[collection, default: 0] += count }
        }
        #expect(pushed["documents"] == 1 && pushed["chunks"] == 3 && pushed["images"] == 1, "\(pushed)")
        #expect(events.allSatisfy { $0.operation?.kind == .sync }, "every event is in a sync group, none is background")
    }

    @Test func aReceivedDocumentBecomingSearchableIsReportedWithItsTitle() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        let tracer = RecordingTracer()
        let b = try SyncDevice(tracer: tracer); defer { Task { await b.cleanUp() } }
        try await a.importDocument("d1", title: "Pump manual", chunks: 4)
        await a.sync.start(server.configuration)
        await b.sync.start(server.configuration)
        try await eventually("the manual searchable on B") { try await b.keywordHits() == 4 }
        try await Task.sleep(for: .milliseconds(500))

        let events = syncEvents(tracer)
        var received: [String: Int] = [:]
        for event in events {
            if case .syncReplicated(let collection, let count, false) = event.kind { received[collection, default: 0] += count }
        }
        #expect(received["documents"] == 1 && received["chunks"] == 4, "\(received)")
        let searchable = events.compactMap { event -> String? in
            if case .syncDocumentSearchable(let id, let title) = event.kind { "\(id)=\(title)" } else { nil }
        }
        #expect(searchable == ["d1=Pump manual"], "reported once: \(searchable)")
    }

    @Test func aRefusedLoginIsReportedAsTheReasonSyncStopped() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let tracer = RecordingTracer()
        let a = try SyncDevice(tracer: tracer); defer { Task { await a.cleanUp() } }
        await a.sync.start(SyncConfiguration(endpoint: server.endpoint, username: "ipad1", password: "wrong"))
        try await waitForState(a.sync, .error(.credentialsRefused))

        let states = syncEvents(tracer).compactMap { event -> String? in if case .syncState(let text) = event.kind { text } else { nil } }
        #expect(states.contains { $0.hasPrefix("stopped: ") }, "\(states)")
    }

    @Test func nothingIsReportedWhileTracingIsOff() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let tracer = RecordingTracer(isEnabled: false)
        let a = try SyncDevice(tracer: tracer); defer { Task { await a.cleanUp() } }
        try await a.importDocument("d1", chunks: 2)
        await a.sync.start(server.configuration)
        try await eventually("the library on the server") { try server.count("chunks") == 2 }
        #expect(tracer.events.isEmpty)
    }

    @Test func aDeviceThatNeverStartedSyncReportsNothing() async throws {
        let tracer = RecordingTracer()
        let a = try SyncDevice(tracer: tracer); defer { Task { await a.cleanUp() } }
        try await a.importDocument("d1", chunks: 2)
        #expect(syncEvents(tracer).isEmpty, "with sync off there are no sync events")
    }

    @Test func eachBurstOfReplicationIsItsOwnGroup() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let tracer = RecordingTracer()
        let a = try SyncDevice(tracer: tracer); defer { Task { await a.cleanUp() } }
        await a.sync.start(server.configuration)
        try await waitForState(a.sync, .upToDate)
        try await a.importDocument("first", chunks: 2)
        try await eventually("the first document sent") { try server.contains("documents", id: "first") }
        try await Task.sleep(for: .seconds(1))
        try await a.importDocument("second", chunks: 2)
        try await eventually("the second document sent") { try server.contains("documents", id: "second") }
        try await Task.sleep(for: .milliseconds(500))

        let operations = Set(syncEvents(tracer).compactMap(\.operation?.id))
        #expect(operations.count >= 2, "a quiet period separates the groups: \(operations.count)")
    }
}
