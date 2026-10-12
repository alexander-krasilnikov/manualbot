import Foundation
import Ports

/// Reads what the first bytes of a `.litertlm` file say about the model, so a candidate can be judged before the whole
/// file is downloaded. The file starts with the magic `LITERTLM`, the format's version and the header's size. Inside the
/// header the file lists its sections by name, and the names say what kind of model it is (design D4).
public enum LiteRTLMHeader {
    /// How many bytes the probe asks for. The headers seen so far are under 2 KB.
    public static let probeLength = 65_536

    private static let magic = Data("LITERTLM".utf8)
    private static let sizeOffset = 24

    /// `ModelHeader.unknown` when the bytes are not a LiteRT-LM file (no magic). A LiteRT-LM file this app cannot classify
    /// (a format version other than 1, a header longer than the bytes given, or no section it knows) has an unknown
    /// kind but still names its format version.
    public static func parse(_ bytes: Data) -> ModelHeader {
        let bytes = Data(bytes)   // indices from zero
        guard bytes.count >= sizeOffset + 4, bytes.prefix(magic.count) == magic else { return .unknown }
        func word(_ offset: Int) -> Int {
            Int(bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian)
        }
        let major = word(8), minor = word(12), patch = word(16)
        let version = "\(major).\(minor).\(patch)"
        guard major == 1 else { return ModelHeader(kind: .unknown, formatVersion: version) }
        let headerSize = word(sizeOffset)
        guard headerSize > sizeOffset + 4, headerSize <= bytes.count else { return ModelHeader(kind: .unknown, formatVersion: version) }

        let header = bytes.prefix(headerSize)
        func lists(_ section: String) -> Bool { header.range(of: Data(section.utf8)) != nil }
        let kind: ModelDescription.Kind =
            lists("tf_lite_prefill_decode") ? .llm : lists("tf_lite_text_encoder") ? .embedder : .unknown
        return ModelHeader(kind: kind, supportsImages: lists("tf_lite_vision_encoder"), formatVersion: version)
    }
}

/// Reads the start of a remote model file with a range request. Only the bytes the header needs are read, even from a
/// server that ignores the range and sends the whole file.
public struct RangeModelHeaderProbe: ModelHeaderProbing {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func probe(_ url: URL) async throws -> ModelHeader {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(LiteRTLMHeader.probeLength - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 else {
            throw ModelSearchError.unavailable("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        var data = Data()
        data.reserveCapacity(LiteRTLMHeader.probeLength)
        for try await byte in bytes {
            data.append(byte)
            if data.count >= LiteRTLMHeader.probeLength { break }   // ends the transfer: nothing more is needed
        }
        return LiteRTLMHeader.parse(data)
    }
}
