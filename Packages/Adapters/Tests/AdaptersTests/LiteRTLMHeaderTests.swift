import Foundation
import Ports
import Testing
@testable import Adapters

/// The first 64 KB of real `.litertlm` files (Gemma 4 E2B, format 1.5.0, and EmbeddingGemma 2 Text Vision 440M, 1.7.0).
private func fixture(_ name: String) throws -> Data {
    let found = FileManager.default.enumerator(at: Bundle.module.resourceURL!, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.first { $0.lastPathComponent == "\(name).bin" }
    return try Data(contentsOf: try #require(found))
}

@Suite struct LiteRTLMHeaderTests {
    @Test func aLanguageModelIsReadFromItsSections() throws {
        let header = LiteRTLMHeader.parse(try fixture("gemma-4-e2b"))
        #expect(header == ModelHeader(kind: .llm, supportsImages: true, formatVersion: "1.5.0"))
    }

    @Test func anEmbeddingModelIsReadFromItsSections() throws {
        let header = LiteRTLMHeader.parse(try fixture("embeddinggemma-2"))
        #expect(header == ModelHeader(kind: .embedder, supportsImages: true, formatVersion: "1.7.0"))
    }

    @Test func noFileSeenSoFarStatesAMinimumRuntime() throws {
        #expect(LiteRTLMHeader.parse(try fixture("gemma-4-e2b")).minRuntimeVersion == nil)
        #expect(LiteRTLMHeader.parse(try fixture("embeddinggemma-2")).minRuntimeVersion == nil)
    }

    @Test func bytesThatAreNotAModelFileAreNotLiteRTLM() {
        for bytes in [Data("<html>not found</html>".utf8), Data(), Data(repeating: 0, count: 4096)] {
            #expect(LiteRTLMHeader.parse(bytes) == .unknown)
            #expect(!LiteRTLMHeader.parse(bytes).isLiteRTLM)
        }
    }

    @Test func aFormatVersionOtherThanOneIsALiteRTLMFileOfUnknownKind() throws {
        var bytes = try fixture("gemma-4-e2b")
        bytes[8] = 2   // major version 2
        let header = LiteRTLMHeader.parse(bytes)
        #expect(header == ModelHeader(kind: .unknown, formatVersion: "2.5.0"))
        #expect(header.isLiteRTLM)
    }

    @Test func aHeaderLongerThanTheBytesGivenIsALiteRTLMFileOfUnknownKind() throws {
        let bytes = try fixture("gemma-4-e2b")
        #expect(LiteRTLMHeader.parse(bytes.prefix(1000)) == ModelHeader(kind: .unknown, formatVersion: "1.5.0"), "the header is 1872 bytes long")
    }

    @Test func aSliceOfALargerBufferIsReadFromItsOwnStart() throws {
        let bytes = Data(repeating: 9, count: 100) + (try fixture("embeddinggemma-2"))
        #expect(LiteRTLMHeader.parse(bytes.suffix(from: 100)).kind == .embedder)
    }
}

@Suite(.serialized) struct RangeModelHeaderProbeTests {
    private func session() -> URLSession { URLSession(configuration: .ephemeral) }

    @Test func theProbeAsksForTheStartOfTheFileOnlyAndReadsTheKind() async throws {
        let server = try TestHTTPServer(); try await server.start(); defer { server.stop() }
        // A file far larger than the header: the test server sends everything from the range's start, like a server
        // that ignores the end of the range.
        server.serve("/model.litertlm", body: try fixture("gemma-4-e2b") + Data(repeating: 0, count: 4_000_000))
        let header = try await RangeModelHeaderProbe(session: session()).probe(server.url("/model.litertlm"))
        #expect(header.kind == .llm)
        #expect(server.requests.last?.range == "bytes=0-65535")
    }

    @Test func aMissingFileIsReportedAsUnreachable() async throws {
        let server = try TestHTTPServer(); try await server.start(); defer { server.stop() }
        await #expect(throws: ModelSearchError.unavailable("HTTP 404")) {
            try await RangeModelHeaderProbe(session: session()).probe(server.url("/missing.litertlm"))
        }
    }

    @Test func aPageThatIsNotAModelIsUnknown() async throws {
        let server = try TestHTTPServer(); try await server.start(); defer { server.stop() }
        server.serve("/page", body: Data("<html>sign in</html>".utf8))
        #expect(try await RangeModelHeaderProbe(session: session()).probe(server.url("/page")) == .unknown)
    }

    /// Against the real host: `RUN_NETWORK_TESTS=1 swift test --filter RangeModelHeaderProbeTests`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_NETWORK_TESTS"] == "1"))
    func theRealHostSendsTheHeaderOfARealModel() async throws {
        let url = URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm")!
        let header = try await RangeModelHeaderProbe().probe(url)
        #expect(header.kind == .llm)
        #expect(header.formatVersion != nil)
    }
}
