import Foundation

/// A catalog PDF fetched into temporary storage.
public struct ManualDownload: Sendable, Equatable {
    /// The temporary file, named `<entry id>.pdf` so that its type is known from the name. The caller removes it with `discard()`.
    public var fileURL: URL
    public var bytes: Int64
    /// SHA-256 of the file, lowercase hex.
    public var sha256: String

    public init(fileURL: URL, bytes: Int64, sha256: String) {
        self.fileURL = fileURL
        self.bytes = bytes
        self.sha256 = sha256
    }

    /// Removes the temporary file, and the directory the downloader made for it when that is now empty.
    public func discard() {
        try? FileManager.default.removeItem(at: fileURL)
        let directory = fileURL.deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        guard directory.standardizedFileURL != temporary,
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true
        else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Why a catalog download failed. None of these leaves a file behind.
public enum ManualDownloadError: Error, Equatable, Sendable {
    /// The device has no network connection.
    case offline
    /// The publisher refuses automatic downloads (HTTP 401 or 403).
    case blocked
    /// The address no longer leads to the file: not found, or it now answers with a web page or a non-HTTPS address.
    case gone
    /// The content does not start with the PDF signature, and is not a web page either.
    case notPDF
    /// The file is larger than the import limit. `bytes` is the size when the server said so.
    case tooLarge(bytes: Int64?)
    /// The server answered with an error status.
    case http(Int)
    /// The connection dropped or timed out.
    case connectionLost
}

public protocol ManualDownloading: Sendable {
    /// Downloads the entry's PDF to a temporary file. `progress` receives 0...1 when the size is known. Cancelling the task
    /// stops the transfer and throws `CancellationError`. On any failure no temporary file remains.
    func download(_ entry: ManualCatalogEntry, progress: @escaping @Sendable (Double) -> Void) async throws -> ManualDownload
}
