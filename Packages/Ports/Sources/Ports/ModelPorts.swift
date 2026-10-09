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
    /// Deletes the installed model, if any, with its record.
    func uninstall(_ spec: ModelSpec)
    /// Writes the record that describes an installed model, next to its file.
    func writeRecord(_ record: ModelRecord) throws
    /// Every record written for an installed model. A model installed before records existed has none.
    func records() -> [ModelRecord]
    /// The models the user activated, per role. Defaults when nothing was activated.
    func loadActive() -> ActiveModels
    func saveActive(_ active: ActiveModels) throws
    /// Deletes every installed model file that is not in `keeping`: whole models that are no longer kept, and older
    /// versions of models that are. A model that was replaced (a new language model, say) must not leave gigabytes
    /// behind. Returns the ids of the models it removed anything for.
    @discardableResult
    func removeAbandoned(keeping specs: [ModelSpec]) -> [String]
}
