import Foundation
import Ports
import Synchronization

public enum ModelDownloadError: Error, LocalizedError, Equatable {
    case httpStatus(Int)
    case incompleteFile(expected: Int64, actual: Int64)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): "The server answered with HTTP \(code)."
        case .incompleteFile(let expected, let actual): "The download ended early (\(actual) of \(expected) bytes)."
        }
    }
}

/// Downloads model files with `URLSession`, keeping resume data on disk so an interrupted download
/// continues from where it stopped, even after the app is relaunched.
///
/// Production passes a background configuration (`URLSessionConfiguration.background(withIdentifier:)`)
/// so the transfer continues while the app is suspended. Tests pass a plain configuration.
public final class URLSessionModelDownloader: NSObject, ModelDownloading, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Pending {
        var spec: ModelSpec
        var progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<URL, Error>
        var staged: URL?
        var failure: Error?
        var cancelledByCaller = false
    }
    private struct State {
        var pending: [Int: Pending] = [:]
        var taskByModel: [String: URLSessionDownloadTask] = [:]
    }

    private let staging: URL
    private let resumeStore: URL
    private let state = Mutex(State())
    private var session: URLSession!

    /// - Parameters:
    ///   - staging: where completed downloads wait for verification and installation.
    ///   - resumeStore: where resume data for interrupted downloads is kept.
    public init(configuration: URLSessionConfiguration, staging: URL, resumeStore: URL) {
        self.staging = staging
        self.resumeStore = resumeStore
        super.init()
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: resumeStore, withIntermediateDirectories: true)
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// The production downloader: a background session, so the transfer continues while the app is
    /// suspended and the system can relaunch the app when it completes.
    public static func background(identifier: String, staging: URL, resumeStore: URL) -> URLSessionModelDownloader {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = false          // the user asked for this download
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.waitsForConnectivity = true
        return URLSessionModelDownloader(configuration: configuration, staging: staging, resumeStore: resumeStore)
    }

    public func invalidate() { session.invalidateAndCancel() }

    private func stagedURL(for spec: ModelSpec) -> URL {
        staging.appendingPathComponent("\(spec.id)-\(spec.version).download")
    }

    private func resumeURL(for spec: ModelSpec) -> URL {
        resumeStore.appendingPathComponent("\(spec.id)-\(spec.version).resume")
    }

    private func size(of url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value
    }

    // MARK: ModelDownloading

    public func download(_ spec: ModelSpec, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        // A transfer that finished while the app was not running is already staged.
        let staged = stagedURL(for: spec)
        if size(of: staged) == spec.bytes {
            progress(1)
            return staged
        }
        try? FileManager.default.removeItem(at: staged)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task: URLSessionDownloadTask
                if let data = try? Data(contentsOf: resumeURL(for: spec)) {
                    task = session.downloadTask(withResumeData: data)
                    try? FileManager.default.removeItem(at: resumeURL(for: spec))
                } else {
                    task = session.downloadTask(with: spec.url)
                }
                state.withLock {
                    $0.pending[task.taskIdentifier] = Pending(spec: spec, progress: progress, continuation: continuation)
                    $0.taskByModel[spec.id] = task
                }
                task.resume()
            }
        } onCancel: {
            let task = state.withLock { s -> URLSessionDownloadTask? in
                guard let task = s.taskByModel[spec.id] else { return nil }
                s.pending[task.taskIdentifier]?.cancelledByCaller = true
                return task
            }
            // Keep what was already transferred so the next attempt resumes.
            task?.cancel(byProducingResumeData: { [self] data in
                if let data { try? data.write(to: resumeURL(for: spec)) }
            })
        }
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let pending = state.withLock({ $0.pending[downloadTask.taskIdentifier] }) else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : pending.spec.bytes
        pending.progress(min(Double(totalBytesWritten) / Double(max(total, 1)), 1))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns, so it must be moved now.
        guard let spec = state.withLock({ $0.pending[downloadTask.taskIdentifier]?.spec }) else { return }
        let target = stagedURL(for: spec)
        let fm = FileManager.default
        var failure: Error?
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = ModelDownloadError.httpStatus(http.statusCode)
        } else if let actual = size(of: location), actual != spec.bytes {
            failure = ModelDownloadError.incompleteFile(expected: spec.bytes, actual: actual)
        } else {
            do {
                try? fm.removeItem(at: target)
                try fm.moveItem(at: location, to: target)
            } catch {
                failure = error
            }
        }
        state.withLock {
            $0.pending[downloadTask.taskIdentifier]?.staged = failure == nil ? target : nil
            $0.pending[downloadTask.taskIdentifier]?.failure = failure
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let finished = state.withLock { s -> Pending? in
            guard let pending = s.pending.removeValue(forKey: task.taskIdentifier) else { return nil }
            if s.taskByModel[pending.spec.id]?.taskIdentifier == task.taskIdentifier { s.taskByModel[pending.spec.id] = nil }
            return pending
        }
        guard let finished else { return }

        if let error {
            // Keep resume data from a dropped connection for the next attempt.
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? data.write(to: resumeURL(for: finished.spec))
            }
            if finished.cancelledByCaller || (error as NSError).code == NSURLErrorCancelled {
                finished.continuation.resume(throwing: CancellationError())
            } else {
                finished.continuation.resume(throwing: error)
            }
        } else if let failure = finished.failure {
            try? FileManager.default.removeItem(at: resumeURL(for: finished.spec))
            finished.continuation.resume(throwing: failure)
        } else if let staged = finished.staged {
            try? FileManager.default.removeItem(at: resumeURL(for: finished.spec))
            finished.continuation.resume(returning: staged)
        } else {
            finished.continuation.resume(throwing: URLError(.unknown))
        }
    }
}
