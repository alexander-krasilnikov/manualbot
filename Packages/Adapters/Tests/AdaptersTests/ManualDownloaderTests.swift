import CryptoKit
import Foundation
import Ports
import Synchronization
import Testing
@testable import Adapters

/// Answers catalog downloads from scripts, one per URL path: a status with headers and a body sent in chunks, an optional
/// failure part-way, an optional redirect, or a body that never ends.
final class ManualStubProtocol: URLProtocol {
    struct Script: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        /// Sent after the chunks instead of finishing.
        var failure: URLError.Code?
        var redirectTo: URL?
        /// Sends 4 KiB chunks until the client stops it.
        var endless = false
        /// Keeps the connection open without sending anything until the client stops it.
        var hang = false
    }

    static let scripts = Mutex<[String: Script]>([:])
    static let requests = Mutex<[URLRequest]>([])
    private let stopped = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requests.withLock { $0.append(request) }
        let script = Self.scripts.withLock { $0[url.path] } ?? Script(status: 404)
        DispatchQueue.global().async { [self] in
            if let target = script.redirectTo {
                let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: script.status, httpVersion: "HTTP/1.1", headerFields: script.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if script.hang {
                while !stopped.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.01) }
                return
            }
            for chunk in script.chunks where !stopped.withLock({ $0 }) {
                client?.urlProtocol(self, didLoad: chunk)
                Thread.sleep(forTimeInterval: 0.002)
            }
            if script.endless {
                let block = Data(repeating: 0x41, count: 4096)
                while !stopped.withLock({ $0 }) {
                    client?.urlProtocol(self, didLoad: block)
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return
            }
            if let failure = script.failure {
                client?.urlProtocol(self, didFailWithError: URLError(failure))
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() { stopped.withLock { $0 = true } }
}

@Suite(.serialized) struct ManualDownloaderTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("manual-downloads-\(UUID().uuidString)")

    private func entry(_ id: String = "wind", path: String = "/manuals/wind") -> ManualCatalogEntry {
        ManualCatalogEntry(
            id: id, category: "Wind turbines", kind: .manual, title: "Wind", publisher: "Acme",
            url: URL(string: "https://example.com\(path)")!, bytes: 100, pages: 1, sha256: String(repeating: "a", count: 64),
            licenceNote: "Free")
    }

    private func downloader(maxBytes: Int64 = 1_000_000) -> URLSessionManualDownloader {
        URLSessionManualDownloader(maxBytes: maxBytes, directory: directory, protocolClasses: [ManualStubProtocol.self])
    }

    private func pdf(_ bytes: Int = 3000) -> [Data] {
        let body = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x20, count: bytes)
        return stride(from: 0, to: body.count, by: 1000).map { body.subdata(in: $0..<min($0 + 1000, body.count)) }
    }

    private func script(_ path: String, _ script: ManualStubProtocol.Script) {
        ManualStubProtocol.scripts.withLock { $0[path] = script }
    }

    /// Nothing is left in the download directory: no file and no empty folder.
    private func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    private func reset() {
        ManualStubProtocol.scripts.withLock { $0 = [:] }
        ManualStubProtocol.requests.withLock { $0 = [] }
        try? FileManager.default.removeItem(at: directory)
    }

    private func failure(_ entry: ManualCatalogEntry, maxBytes: Int64 = 1_000_000) async -> ManualDownloadError? {
        do {
            _ = try await downloader(maxBytes: maxBytes).download(entry, progress: { _ in })
            return nil
        } catch {
            return error as? ManualDownloadError
        }
    }

    @Test func aPDFAtAnAddressWithoutDotPDFIsAcceptedAndNamedAfterTheEntry() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        let chunks = pdf()
        script("/manuals/wind", .init(headers: ["Content-Type": "text/plain"], chunks: chunks))
        let result = try await downloader().download(entry(), progress: { _ in })
        #expect(result.fileURL.lastPathComponent == "wind.pdf")
        #expect(result.bytes == Int64(chunks.reduce(0) { $0 + $1.count }))
        let stored = try Data(contentsOf: result.fileURL)
        #expect(stored.starts(with: Data("%PDF-".utf8)) && stored.count == Int(result.bytes))
        #expect(result.sha256.count == 64)
        result.discard()
        #expect(leftovers().isEmpty, "discard removes the file and the folder made for it")
    }

    @Test func theChecksumIsOfTheFileOnDisk() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        script("/manuals/wind", .init(chunks: pdf(5000)))
        let result = try await downloader().download(entry(), progress: { _ in })
        let expected = Data(try Data(contentsOf: result.fileURL)).sha256Hex
        #expect(result.sha256 == expected)
        result.discard()
    }

    @Test func progressReachesOneWhenTheSizeIsKnown() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        let chunks = pdf(4000)
        let length = chunks.reduce(0) { $0 + $1.count }
        script("/manuals/wind", .init(headers: ["Content-Length": "\(length)"], chunks: chunks))
        let seen = Mutex<[Double]>([])
        let result = try await downloader().download(entry(), progress: { fraction in seen.withLock { $0.append(fraction) } })
        let values = seen.withLock { $0 }
        #expect(!values.isEmpty && values.last == 1 && values == values.sorted())
        result.discard()
    }

    @Test func itIdentifiesItselfAndSendsNoCookies() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        script("/manuals/wind", .init(chunks: pdf()))
        try await downloader().download(entry(), progress: { _ in }).discard()
        let request = try #require(ManualStubProtocol.requests.withLock { $0.first })
        #expect(request.value(forHTTPHeaderField: "User-Agent") == URLSessionManualDownloader.defaultUserAgent)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test func aWebPageInsteadOfAPDFMeansTheLinkIsGone() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        script("/manuals/wind", .init(headers: ["Content-Type": "text/html"], chunks: [Data("<!DOCTYPE html><html>Moved</html>".utf8)]))
        #expect(await failure(entry()) == .gone)
        #expect(leftovers().isEmpty)
    }

    @Test func otherContentThatIsNotAPDFIsNotAPDF() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        script("/manuals/wind", .init(headers: ["Content-Type": "application/zip"], chunks: [Data("PK\u{3}\u{4}0000000".utf8)]))
        #expect(await failure(entry()) == .notPDF)
        #expect(leftovers().isEmpty)
    }

    @Test func aBodyShorterThanTheSignatureIsNotAPDF() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        script("/manuals/wind", .init(chunks: [Data("%PD".utf8)]))
        #expect(await failure(entry()) == .notPDF)
    }

    @Test func statusAnswersBecomeTypedErrors() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        script("/forbidden", .init(status: 403))
        script("/missing", .init(status: 404))
        script("/gone", .init(status: 410))
        script("/broken", .init(status: 503))
        script("/rate", .init(status: 429))
        #expect(await failure(entry(path: "/forbidden")) == .blocked)
        #expect(await failure(entry(path: "/missing")) == .gone)
        #expect(await failure(entry(path: "/gone")) == .gone)
        #expect(await failure(entry(path: "/broken")) == .http(503))
        #expect(await failure(entry(path: "/rate")) == .http(429))
        #expect(leftovers().isEmpty)
    }

    @Test func aFirewallChallengeIsABlock() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        script("/manuals/wind", .init(status: 405, headers: ["x-amzn-waf-action": "captcha"], chunks: [Data("<html>captcha</html>".utf8)]))
        #expect(await failure(entry()) == .blocked)
    }

    @Test func aDeclaredSizeOverTheLimitIsRefusedAtOnce() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        script("/manuals/wind", .init(headers: ["Content-Length": "5000"], chunks: pdf(5000)))
        #expect(await failure(entry(), maxBytes: 4000) == .tooLarge(bytes: 5000))
        #expect(leftovers().isEmpty)
    }

    @Test func aBodyThatPassesTheLimitWithoutAContentLengthIsAbandoned() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        script("/manuals/wind", .init(chunks: [Data("%PDF-1.7\n".utf8)], endless: true))
        #expect(await failure(entry(), maxBytes: 50_000) == .tooLarge(bytes: nil))
        #expect(leftovers().isEmpty, "the partial file is removed")
    }

    @Test func aBodyOfExactlyTheLimitIsAccepted() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        let body = Data("%PDF-".utf8) + Data(repeating: 0x20, count: 995)
        script("/manuals/wind", .init(chunks: [body]))
        let result = try await downloader(maxBytes: 1000).download(entry(), progress: { _ in })
        #expect(result.bytes == 1000)
        result.discard()
    }

    @Test func aRedirectToHTTPIsRefused() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        script("/manuals/wind", .init(redirectTo: URL(string: "http://example.com/plain.pdf")))
        script("/plain.pdf", .init(chunks: pdf()))
        #expect(await failure(entry()) == .gone)
        #expect(ManualStubProtocol.requests.withLock { $0.map { $0.url?.path } } == ["/manuals/wind"], "the insecure address is never requested")
    }

    @Test func aRedirectToHTTPSIsFollowed() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        script("/manuals/wind", .init(redirectTo: URL(string: "https://cdn.example.com/files/wind.pdf")))
        script("/files/wind.pdf", .init(chunks: pdf()))
        let result = try await downloader().download(entry(), progress: { _ in })
        #expect(result.fileURL.lastPathComponent == "wind.pdf")
        result.discard()
    }

    @Test func anInsecureEntryAddressIsNeverRequested() async throws {
        reset()
        let insecure = ManualCatalogEntry(
            id: "x", category: "Ships", kind: .manual, title: "X", publisher: "P", url: URL(string: "http://example.com/x.pdf")!,
            bytes: 1, pages: 1, sha256: String(repeating: "a", count: 64), licenceNote: "x")
        #expect(await failure(insecure) == .gone)
        #expect(ManualStubProtocol.requests.withLock { $0.isEmpty })
    }

    @Test func aDroppedConnectionLeavesNoFile() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        script("/manuals/wind", .init(headers: ["Content-Length": "9000"], chunks: pdf(3000), failure: .networkConnectionLost))
        #expect(await failure(entry()) == .connectionLost)
        #expect(leftovers().isEmpty)
    }

    @Test func aBodyThatEndsBeforeItsDeclaredLengthIsALostConnection() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        script("/manuals/wind", .init(headers: ["Content-Length": "9000"], chunks: pdf(3000)))
        #expect(await failure(entry()) == .connectionLost)
        #expect(leftovers().isEmpty)
    }

    @Test func noNetworkIsReportedAsOffline() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        script("/manuals/wind", .init(failure: .notConnectedToInternet))
        #expect(await failure(entry()) == .offline)
    }

    @Test func aHostThatNoLongerResolvesMeansTheLinkIsGone() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        script("/manuals/wind", .init(failure: .cannotFindHost))
        #expect(await failure(entry()) == .gone)
    }

    @Test func cancellingStopsTheTransferAndLeavesNoFile() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        script("/manuals/wind", .init(chunks: [Data("%PDF-1.7\n".utf8)], endless: true))
        let started = Mutex(false)
        let task = Task {
            try await downloader(maxBytes: .max).download(entry(), progress: { _ in started.withLock { $0 = true } })
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await Task.sleep(for: .milliseconds(100))
        #expect(leftovers().isEmpty)
    }

    @Test func cancellingBeforeAnyBytesArriveAlsoThrowsCancellation() async throws {
        reset(); defer { try? FileManager.default.removeItem(at: directory) }
        script("/manuals/wind", .init(hang: true))
        let task = Task { try await downloader().download(entry(), progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(leftovers().isEmpty)
    }
}

private extension Data {
    var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}
