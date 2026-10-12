import Foundation
import Ports
import Synchronization
import Testing
@testable import Adapters

/// Answers the requests of a search from canned responses, keyed by path.
final class StubURLProtocol: URLProtocol {
    struct Reply: Sendable {
        let status: Int
        let body: String
    }

    static let replies = Mutex<[String: Reply]>([:])
    static let offline = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if StubURLProtocol.offline.withLock({ $0 }) {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let reply = StubURLProtocol.replies.withLock { $0[url.path] } ?? Reply(status: 404, body: "")
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct HuggingFaceModelSearchTests {
    private let checksum = String(repeating: "c", count: 64)
    private let otherChecksum = String(repeating: "d", count: 64)

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func reset() {
        StubURLProtocol.offline.withLock { $0 = false }
        StubURLProtocol.replies.withLock { replies in
            replies = [
                "/api/models": .init(status: 200, body: """
                [{"id":"litert-community/gemma-open"},{"id":"litert-community/gemma-gated"}]
                """),
                "/api/models/litert-community/gemma-open": .init(status: 200, body: """
                {"id":"litert-community/gemma-open","sha":"abc123","gated":false,"cardData":{"license":"apache-2.0"},
                 "siblings":[{"rfilename":"README.md","size":100},
                             {"rfilename":"gemma-open.litertlm","size":5,"lfs":{"sha256":"\(checksum)","size":1000}},
                             {"rfilename":"unchecked.litertlm","size":5}]}
                """),
                "/api/models/litert-community/gemma-gated": .init(status: 200, body: """
                {"id":"litert-community/gemma-gated","sha":"def456","gated":"auto",
                 "siblings":[{"rfilename":"g.litertlm","size":1,"lfs":{"sha256":"\(otherChecksum)","size":1}}]}
                """),
            ]
        }
    }

    @Test func gatedRepositoriesAndFilesWithoutAChecksumAreLeftOut() async throws {
        reset()
        let results = try await HuggingFaceModelSearch(session: session).search("gemma")
        #expect(results.map(\.fileName) == ["gemma-open.litertlm"])
    }

    @Test func aResultIsPinnedToItsRevisionAndCarriesItsChecksumAndLicence() async throws {
        reset()
        let spec = try #require(try await HuggingFaceModelSearch(session: session).search("gemma").first)
        #expect(spec.id == "litert-community-gemma-open-gemma-open")
        #expect(spec.version == "abc123")
        #expect(spec.role == .generator)
        #expect(spec.url.absoluteString == "https://huggingface.co/litert-community/gemma-open/resolve/abc123/gemma-open.litertlm")
        #expect(spec.bytes == 1000, "the size of the file itself, not of its pointer")
        #expect(spec.sha256 == checksum)
        #expect(spec.licence == "apache-2.0")
        #expect(spec.repository?.absoluteString == "https://huggingface.co/litert-community/gemma-open")
    }

    @Test func anOfflineSearchIsReportedAsOffline() async {
        reset()
        StubURLProtocol.offline.withLock { $0 = true }
        await #expect(throws: ModelSearchError.offline) {
            try await HuggingFaceModelSearch(session: session).search("gemma")
        }
    }

    @Test func aServerErrorIsReportedWithItsStatus() async {
        reset()
        StubURLProtocol.replies.withLock { $0["/api/models"] = .init(status: 500, body: "") }
        await #expect(throws: ModelSearchError.unavailable("HTTP 500")) {
            try await HuggingFaceModelSearch(session: session).search("gemma")
        }
    }
}
