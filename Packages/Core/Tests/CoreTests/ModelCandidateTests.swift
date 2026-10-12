import Foundation
import Ports
import PortsTesting
import Testing
@testable import Core

@Suite struct RuntimeVersionTests {
    @Test func versionsCompareByParts() {
        #expect(RuntimeVersion.isNewer("0.18.1", than: "0.18.0"))
        #expect(RuntimeVersion.isNewer("0.19", than: "0.18.9"))
        #expect(!RuntimeVersion.isNewer("0.18", than: "0.18.0"))
        #expect(!RuntimeVersion.isNewer("0.17.9", than: "0.18.0"))
    }
}

/// The verdicts of the model-catalog spec's "Compatibility before download" requirement.
@Suite struct ModelCandidateTests {
    private let eightGB: UInt64 = 8_000_000_000

    private func spec(_ id: String, bytes: Int64 = 2_000_000_000) -> ModelSpec {
        ModelSpec(id: id, version: "rev", role: .generator, url: URL(string: "https://example.com/\(id).litertlm")!, bytes: bytes,
                  sha256: String(repeating: "a", count: 64), fileName: "\(id).litertlm", licence: "apache-2.0")
    }

    private func finder(_ specs: [ModelSpec], headers: [String: ModelHeader] = [:], unreachable: [String] = [])
        -> (ModelCandidateFinder, FakeHeaderProbe) {
        let probe = FakeHeaderProbe()
        for spec in specs {
            if let header = headers[spec.id] { probe.set(header, for: spec.url) }
            if unreachable.contains(spec.id) { probe.makeUnreachable(spec.url) }
        }
        return (ModelCandidateFinder(search: FakeModelSearch(results: specs), probe: probe, runtimeVersion: "0.18.0", physicalMemory: eightGB), probe)
    }

    private let llm = ModelHeader(kind: .llm, supportsImages: true, formatVersion: "1.5.0")

    @Test func aLanguageModelWhoseRuntimeIsUnknownIsOfferedAndCheckedAfterDownload() async throws {
        let (finder, _) = finder([spec("a")], headers: ["a": llm])
        let found = try await finder.find("gemma")
        #expect(found.map(\.verdict) == [.checkedAfterDownload])
        #expect(found[0].isDownloadable)
    }

    @Test func anEmbeddingModelIsOfferedAsAnEmbedder() async throws {
        let (finder, _) = finder([spec("e")], headers: ["e": ModelHeader(kind: .embedder, formatVersion: "1.7.0")])
        let found = try await finder.find("embedding")
        #expect(found.map(\.verdict) == [.checkedAfterDownload])
        #expect(found.map(\.spec.role) == [.embedder], "the header says what it is")
        #expect(found[0].isDownloadable)
    }

    @Test func aFileTooLargeForTheDeviceIsRefusedWithoutAnyRequest() async throws {
        let (finder, probe) = finder([spec("big", bytes: 7_000_000_000)], headers: ["big": llm])
        let found = try await finder.find("gemma")
        #expect(found.map(\.verdict) == [.incompatible(.tooLarge)])
        #expect(!found[0].isDownloadable)
        #expect(probe.probed.isEmpty, "a file that cannot be held is not worth a request")
    }

    @Test func aFileThatIsNotALiteRTLMFileIsRefused() async throws {
        let (finder, _) = finder([spec("page")])   // the probe knows nothing about it: not a LiteRT-LM file
        #expect(try await finder.find("x").map(\.verdict) == [.incompatible(.notALiteRTFile)])
    }

    @Test func aLiteRTLMFileOfNeitherKindCannotBeDownloaded() async throws {
        let (finder, _) = finder([spec("new")], headers: ["new": ModelHeader(kind: .unknown, formatVersion: "2.0.0")])
        let found = try await finder.find("x")
        #expect(found.map(\.verdict) == [.incompatible(.unknownKind)])
        #expect(!found[0].isDownloadable, "without a kind it has no role to be installed in")
    }

    @Test func aHeaderThatCannotBeReadLeavesTheCheckForAfterTheDownload() async throws {
        let (finder, _) = finder([spec("slow")], unreachable: ["slow"])
        #expect(try await finder.find("x").map(\.verdict) == [.checkedAfterDownload])
    }

    @Test func aHeaderThatStatesItsRuntimeIsJudgedAtOnce() async throws {
        let recent = ModelHeader(kind: .llm, formatVersion: "1.5.0", minRuntimeVersion: "0.18.0")
        let future = ModelHeader(kind: .llm, formatVersion: "1.9.0", minRuntimeVersion: "0.30.0")
        let (finder, _) = finder([spec("old"), spec("new")], headers: ["old": recent, "new": future])
        #expect(try await finder.find("x").map(\.verdict) == [.compatible, .incompatible(.needsNewerRuntime)])
    }

    @Test func resultsKeepTheOrderOfTheSearchWhateverOrderTheHeadersArrive() async throws {
        let specs = (0..<15).map { spec("m\($0)", bytes: $0 == 7 ? 7_000_000_000 : 2_000_000_000) }
        var headers: [String: ModelHeader] = [:]
        for s in specs { headers[s.id] = llm }
        let (finder, _) = finder(specs, headers: headers)
        let found = try await finder.find("x")
        #expect(found.map(\.id) == specs.map(\.id))
        #expect(found[7].verdict == .incompatible(.tooLarge))
        #expect(found.filter(\.isDownloadable).count == 14)
    }

    @Test func aFailedSearchIsReported() async {
        let search = FakeModelSearch()
        search.fail(with: ModelSearchError.offline)
        let finder = ModelCandidateFinder(search: search, probe: FakeHeaderProbe(), runtimeVersion: "0.18.0", physicalMemory: eightGB)
        await #expect(throws: ModelSearchError.offline) { try await finder.find("gemma") }
    }
}
