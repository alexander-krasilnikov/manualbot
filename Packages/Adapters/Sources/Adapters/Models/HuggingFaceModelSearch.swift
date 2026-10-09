import Foundation
import Ports

/// Searches the `litert-community` organisation on Hugging Face for `.litertlm` language models. Only public
/// repository metadata is requested; the query text is the only thing sent.
public struct HuggingFaceModelSearch: ModelSearching {
    private let session: URLSession
    private let host: URL
    private let maxRepositories: Int

    public init(session: URLSession = .shared, host: URL = URL(string: "https://huggingface.co")!, maxRepositories: Int = 12) {
        self.session = session
        self.host = host
        self.maxRepositories = maxRepositories
    }

    public func search(_ text: String) async throws -> [ModelSpec] {
        var listing = URLComponents(url: host, resolvingAgainstBaseURL: false)!
        listing.path = "/api/models"
        listing.queryItems = [
            URLQueryItem(name: "author", value: "litert-community"),
            URLQueryItem(name: "search", value: text),
            URLQueryItem(name: "limit", value: String(maxRepositories)),
        ]
        let found: [Listed] = try await get(listing.url!)

        var specs: [ModelSpec] = []
        for item in found {
            var detail = URLComponents(url: host, resolvingAgainstBaseURL: false)!
            detail.path = "/api/models/\(item.id)"
            detail.queryItems = [URLQueryItem(name: "blobs", value: "true")]
            let repository: Repository = try await get(detail.url!)
            // A gated repository needs an account to download from, and the app has none. A repository without a revision cannot be pinned.
            guard repository.gated != .yes, let revision = repository.sha else { continue }
            for file in repository.siblings ?? [] where file.rfilename.hasSuffix(".litertlm") {
                guard let checksum = file.lfs?.sha256, checksum.count == 64, checksum.allSatisfy(\.isHexDigit),
                      let bytes = file.lfs?.size ?? file.size, bytes > 0 else { continue }
                let name = (file.rfilename as NSString).lastPathComponent
                let path = file.rfilename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.rfilename
                specs.append(ModelSpec(
                    id: Self.modelID(repository: item.id, file: name), version: revision, role: .generator,
                    url: URL(string: "\(host.absoluteString)/\(item.id)/resolve/\(revision)/\(path)")!,
                    bytes: bytes, sha256: checksum.lowercased(), fileName: name,
                    displayName: (name as NSString).deletingPathExtension,
                    licence: repository.cardData?.license,
                    repository: URL(string: "\(host.absoluteString)/\(item.id)")))
            }
        }
        return specs
    }

    /// A directory name for the model: the repository and the file, lowercase, with no characters a file system dislikes.
    static func modelID(repository: String, file: String) -> String {
        let raw = "\(repository)-\((file as NSString).deletingPathExtension)".lowercased()
        return String(raw.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let error as URLError where Self.isOffline(error) {
            throw ModelSearchError.offline
        } catch {
            throw ModelSearchError.unavailable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelSearchError.unavailable("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ModelSearchError.unavailable("unexpected response")
        }
    }

    static func isOffline(_ error: URLError) -> Bool {
        [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .cannotFindHost, .cannotConnectToHost].contains(error.code)
    }

    private struct Listed: Decodable {
        let id: String
    }

    private struct Repository: Decodable {
        let sha: String?
        let gated: Gated?
        let cardData: CardData?
        let siblings: [Sibling]?

        /// Hugging Face reports `false` for open repositories and `"auto"` or `"manual"` for gated ones.
        enum Gated: Decodable, Equatable {
            case no, yes

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if container.decodeNil() { self = .no; return }
                if let flag = try? container.decode(Bool.self) { self = flag ? .yes : .no; return }
                self = .yes
            }
        }

        struct CardData: Decodable {
            let license: String?
        }

        struct Sibling: Decodable {
            let rfilename: String
            let size: Int64?
            let lfs: LFS?

            struct LFS: Decodable {
                let sha256: String?
                let size: Int64?
            }
        }
    }
}
