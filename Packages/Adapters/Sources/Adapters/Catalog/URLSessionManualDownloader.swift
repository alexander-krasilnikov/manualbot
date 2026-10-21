import CryptoKit
import Core
import Foundation
import Ports

/// Downloads a catalog PDF to a temporary file, for a few megabytes in the foreground (no background session, no resume).
///
/// - A session of its own per download: ephemeral, no cookies, no stored credentials, no cache, and a User-Agent that says
///   what the app is. It does not pretend to be a browser: a host that refuses it is reported as blocked.
/// - The response is streamed. The first bytes must be the PDF signature, whatever the address ends in or the server says,
///   and the transfer is abandoned as soon as it passes the limit, with or without a Content-Length.
/// - Redirects are followed, but only to HTTPS addresses.
/// - The file is written only once the signature has been seen, as `<directory>/<unique>/<entry id>.pdf`, because the
///   importer reads a file's type from its name. Every failure removes what was written.
public struct URLSessionManualDownloader: ManualDownloading {
    public static let defaultUserAgent = "ManualBot/1.0 (iPad; manual catalog download)"

    private let userAgent: String
    private let maxBytes: Int64
    private let directory: URL
    private let protocolClasses: [AnyClass]?

    /// `protocolClasses` is for tests, which answer requests without a network.
    public init(
        userAgent: String = Self.defaultUserAgent, maxBytes: Int64 = IngestionService.maxOriginalBytes,
        directory: URL = FileManager.default.temporaryDirectory, protocolClasses: [AnyClass]? = nil
    ) {
        self.userAgent = userAgent
        self.maxBytes = maxBytes
        self.directory = directory
        self.protocolClasses = protocolClasses
    }

    public func download(_ entry: ManualCatalogEntry, progress: @escaping @Sendable (Double) -> Void) async throws -> ManualDownload {
        guard entry.url.scheme?.lowercased() == "https" else { throw ManualDownloadError.gone }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        if let protocolClasses { configuration.protocolClasses = protocolClasses }

        let job = ManualDownloadJob(
            fileName: "\(entry.id).pdf", parent: directory.appendingPathComponent(UUID().uuidString, isDirectory: true),
            maxBytes: maxBytes, progress: progress)
        let session = URLSession(configuration: configuration, delegate: job, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: entry.url)
        request.setValue("application/pdf, */*;q=0.5", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await job.run(task)
        } onCancel: {
            job.cancel(task)
        }
    }
}

/// The state of one download. The delegate methods run on the session's serial queue; `cancel` and `run` come from the
/// caller's task, so the state is guarded.
private final class ManualDownloadJob: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let fileName: String
    private let parent: URL
    private let maxBytes: Int64
    private let progress: @Sendable (Double) -> Void

    private var continuation: CheckedContinuation<ManualDownload, any Error>?
    private var pending: Result<ManualDownload, any Error>?
    private var cancelled = false
    private var failure: ManualDownloadError?
    private var status = 0
    private var contentType = ""
    private var expected: Int64 = -1
    private var received: Int64 = 0
    /// The first bytes, held until there are enough to tell whether this is a PDF.
    private var head = Data()
    private var verified = false
    private var handle: FileHandle?
    private var file: URL?
    private var hasher = SHA256()

    private static let signature = Data("%PDF-".utf8)

    init(fileName: String, parent: URL, maxBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.fileName = fileName
        self.parent = parent
        self.maxBytes = maxBytes
        self.progress = progress
    }

    func run(_ task: URLSessionDataTask) async throws -> ManualDownload {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()
            task.resume()
        }
    }

    func cancel(_ task: URLSessionTask) {
        lock.lock()
        cancelled = true
        lock.unlock()
        task.cancel()
    }

    // MARK: Delegate

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https" else {
            abort(.gone, task)
            return completionHandler(nil)
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            abort(.notPDF, dataTask)
            return completionHandler(.cancel)
        }
        lock.lock()
        status = http.statusCode
        contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        expected = http.expectedContentLength
        lock.unlock()
        // A firewall challenge answers with any status; it is a refusal like a 403.
        let challenge = ["captcha", "challenge"].contains(http.value(forHTTPHeaderField: "x-amzn-waf-action")?.lowercased() ?? "")
        if let error = Self.error(forStatus: http.statusCode, challenge: challenge) {
            abort(error, dataTask)
            return completionHandler(.cancel)
        }
        if http.expectedContentLength > maxBytes {
            abort(.tooLarge(bytes: http.expectedContentLength), dataTask)
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let stop = failure != nil || cancelled
        lock.unlock()
        if stop { return }
        received += Int64(data.count)
        if received > maxBytes {
            abort(.tooLarge(bytes: expected > 0 ? expected : nil), dataTask)
            return
        }
        do {
            if !verified {
                head.append(data)
                guard head.count >= Self.signature.count else { return }
                guard head.starts(with: Self.signature) else {
                    abort(Self.notPDF(head: head, contentType: contentType), dataTask)
                    return
                }
                verified = true
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                let url = parent.appendingPathComponent(fileName)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                handle = try FileHandle(forWritingTo: url)
                file = url
                try write(head)
                head = Data()
            } else {
                try write(data)
            }
        } catch {
            abort(.connectionLost, dataTask)
            return
        }
        if expected > 0 { progress(min(1, Double(received) / Double(expected))) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let wasCancelled = cancelled
        let recorded = failure
        lock.unlock()
        let result: Result<ManualDownload, any Error>
        if wasCancelled {
            result = .failure(CancellationError())
        } else if let recorded {
            result = .failure(recorded)
        } else if let error {
            result = .failure(Self.error(for: error))
        } else if !verified {
            // The body ended before the signature could be read.
            result = .failure(Self.notPDF(head: head, contentType: contentType))
        } else if expected > 0, received < expected {
            result = .failure(ManualDownloadError.connectionLost)
        } else {
            result = Result { try finish() }
        }
        complete(result)
    }

    // MARK: Helpers

    private func write(_ data: Data) throws {
        try handle?.write(contentsOf: data)
        hasher.update(data: data)
    }

    private func finish() throws -> ManualDownload {
        try handle?.close()
        handle = nil
        guard let file else { throw ManualDownloadError.notPDF }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ManualDownload(fileURL: file, bytes: received, sha256: digest)
    }

    /// Records the failure and stops the transfer; the completion callback then reports it.
    private func abort(_ error: ManualDownloadError, _ task: URLSessionTask) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
        task.cancel()
    }

    private func complete(_ result: Result<ManualDownload, any Error>) {
        if case .failure = result { removeFiles() }
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func removeFiles() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: parent)
    }

    static func error(forStatus status: Int, challenge: Bool) -> ManualDownloadError? {
        if challenge { return .blocked }
        switch status {
        case 200...299: return nil
        case 401, 403: return .blocked
        case 404, 410: return .gone
        default: return .http(status)
        }
    }

    /// A web page where the file should be means the publisher moved it; any other content is just not a PDF.
    static func notPDF(head: Data, contentType: String) -> ManualDownloadError {
        let start = String(decoding: head.prefix(512), as: UTF8.self).lowercased()
        let page = contentType.lowercased().contains("html") || start.contains("<html") || start.contains("<!doctype")
        return page ? .gone : .notPDF
    }

    static func error(for error: any Error) -> ManualDownloadError {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive: .offline
        case .cannotFindHost, .dnsLookupFailed, .appTransportSecurityRequiresSecureConnection, .unsupportedURL, .badURL: .gone
        default: .connectionLost
        }
    }
}
