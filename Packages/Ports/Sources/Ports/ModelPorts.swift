import Foundation

public protocol ModelDownloading: Sendable {
    /// Downloads the model file and returns the location of the completed temporary file.
    /// Resumes from earlier partial progress when possible. `progress` receives 0...1.
    func download(_ spec: ModelSpec, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

public protocol ModelFiles: Sendable {
    /// Free space available for important (user-initiated) downloads, in bytes.
    func availableBytes() throws -> Int64
    /// Whether the installed file exists and has the size the manifest expects.
    func isInstalled(_ spec: ModelSpec) -> Bool
    /// Location the installed model file is loaded from.
    func installedURL(for spec: ModelSpec) -> URL
    /// SHA-256 of a file as lowercase hex, computed by streaming (models do not fit comfortably in memory).
    func sha256(of file: URL) async throws -> String
    /// Moves a verified file into place and marks it excluded from backup.
    func install(_ file: URL, for spec: ModelSpec) throws
    /// Deletes a temporary or installed file. Missing files are not an error.
    func discard(_ file: URL)
    /// Deletes the installed model, if any.
    func uninstall(_ spec: ModelSpec)
    /// Deletes every installed model file that the manifest no longer lists: whole models that were dropped, and older
    /// versions of models that were kept. A model that was replaced (a new language model, say) must not leave gigabytes
    /// behind. Returns the ids of the models it removed anything for.
    @discardableResult
    func removeUnlisted(keeping manifest: ModelManifest) -> [String]
}
