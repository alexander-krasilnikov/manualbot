import Foundation

/// Why the Models page could not search.
public enum ModelSearchError: Error, LocalizedError, Equatable {
    /// There is no network connection. Installed models keep working.
    case offline
    /// The repositories could not be searched, with the reason.
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .offline: "Searching needs a network connection."
        case .unavailable(let reason): "The model repositories could not be searched (\(reason))."
        }
    }
}

/// Finds language models that the app's runtime can run, in public model repositories.
public protocol ModelSearching: Sendable {
    /// Each result is a `.litertlm` file ready to download: pinned to a revision, with its checksum and licence.
    /// Gated repositories and files without a checksum are left out.
    func search(_ text: String) async throws -> [ModelSpec]
}
