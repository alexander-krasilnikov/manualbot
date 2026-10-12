import Ports
import PortsTesting
import Testing
@testable import Core

@Test func coreBuildsAgainstPortsAndFakes() async throws {
    let embedder: any Embedder = FakeEmbedder()
    let v = try await embedder.embed(["hello"], kind: .query)
    #expect(v.count == 1)
}
