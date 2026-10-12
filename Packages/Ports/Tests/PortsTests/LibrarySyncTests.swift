import Foundation
import Testing
@testable import Ports
@testable import PortsTesting

@Suite struct ScriptedLibrarySyncTests {
    private let configuration = SyncConfiguration(endpoint: URL(string: "ws://localhost:4984/manualbot")!, username: "ipad1", password: "secret")

    @Test func startReportsTheScriptedStatesInOrderAndRemembersTheConfiguration() async {
        let sync = ScriptedLibrarySync(onStart: [.connecting, .syncing, .upToDate])
        var updates = await sync.statusUpdates().makeAsyncIterator()
        #expect(await updates.next()?.state == .off, "the first update is the current status")

        await sync.start(configuration)
        #expect(await updates.next()?.state == .connecting)
        #expect(await updates.next()?.state == .syncing)
        let last = await updates.next()
        #expect(last?.state == .upToDate)
        #expect(last?.lastSync != nil)
        #expect(await sync.configurations == [configuration])
        #expect(await sync.isRunning)
    }

    @Test func stopReportsOffAndIsCounted() async {
        let sync = ScriptedLibrarySync()
        await sync.start(configuration)
        await sync.stop()
        #expect(await sync.status.state == .off)
        #expect(await sync.stopCount == 1)
        #expect(await !sync.isRunning)
    }

    @Test func everySubscriberSeesEveryChange() async {
        let sync = ScriptedLibrarySync()
        var first = await sync.statusUpdates().makeAsyncIterator()
        var second = await sync.statusUpdates().makeAsyncIterator()
        _ = await first.next(); _ = await second.next()

        await sync.emit(.paused(.otherEmbedder(active: "A", fleet: "B")), sent: 4, received: 9)
        for status in [await first.next(), await second.next()] {
            #expect(status?.state == .paused(.otherEmbedder(active: "A", fleet: "B")))
            #expect(status?.sent == 4 && status?.received == 9)
        }
    }

    @Test func unsharedDocumentsAreWhatWasScripted() async {
        let large = UnsharedDocument(id: "d1", title: "Big manual", bytes: 35 * 1024 * 1024)
        let sync = ScriptedLibrarySync(unshared: [large])
        #expect(await sync.unsharedDocuments() == [large])
        await sync.setUnshared([])
        #expect(await sync.unsharedDocuments().isEmpty)
    }
}
