import Foundation
import Ports

/// A model found by search, with what is known about it before anything is downloaded. Its spec says whether it is a
/// language model or an embedding model (`spec.role`), as far as its header could tell.
public struct ModelCandidate: Sendable, Equatable, Identifiable {
    public enum Reason: Sendable, Equatable {
        /// The start of the file is not that of a LiteRT-LM model.
        case notALiteRTFile
        /// A LiteRT-LM file, but of a model that is neither a language model nor an embedding model.
        case unknownKind
        /// The file is larger than this device can hold in memory.
        case tooLarge
        /// The file says it needs a newer runtime than this app contains.
        case needsNewerRuntime
    }

    public enum Verdict: Sendable, Equatable {
        /// A language model that this app's runtime can run.
        case compatible
        /// A language model, but whether this runtime can run it is only known once the runtime has read the downloaded
        /// file (the header does not say which runtime it needs). Offered for download.
        case checkedAfterDownload
        /// Cannot be used here. Not offered for download.
        case incompatible(Reason)
    }

    public var spec: ModelSpec
    public var verdict: Verdict

    public var id: String { spec.id }

    public var isDownloadable: Bool {
        if case .incompatible = verdict { false } else { true }
    }

    public init(spec: ModelSpec, verdict: Verdict) {
        self.spec = spec
        self.verdict = verdict
    }
}

/// Judges search results before anything is downloaded: by size against this device first, then by the start of each
/// file. The runtime has the last word once a file is downloaded (`ModelValidating`); this only keeps people from
/// downloading gigabytes that cannot work.
public struct ModelCandidateFinder: Sendable {
    /// Header requests running at once. Each reads at most 64 KB.
    static let concurrency = 6

    private let search: any ModelSearching
    private let probe: any ModelHeaderProbing
    private let physicalMemory: UInt64
    private let runtimeVersion: String

    public init(
        search: any ModelSearching, probe: any ModelHeaderProbing, runtimeVersion: String,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.search = search
        self.probe = probe
        self.runtimeVersion = runtimeVersion
        self.physicalMemory = physicalMemory
    }

    /// The search results in the order the search gave them, each with its verdict. Throws when the search itself fails
    /// (offline, say); a file whose header cannot be read is a candidate like any other, checked after download.
    public func find(_ text: String) async throws -> [ModelCandidate] {
        let specs = try await search.search(text)
        var candidates = [ModelCandidate?](repeating: nil, count: specs.count)
        await withTaskGroup(of: (Int, ModelCandidate).self) { group in
            var next = 0
            while next < min(Self.concurrency, specs.count) {
                let index = next
                group.addTask { (index, await self.assess(specs[index])) }
                next += 1
            }
            for await (index, candidate) in group {
                candidates[index] = candidate
                if next < specs.count {
                    let index = next
                    group.addTask { (index, await self.assess(specs[index])) }
                    next += 1
                }
            }
        }
        return candidates.compactMap { $0 }
    }

    public func assess(_ spec: ModelSpec) async -> ModelCandidate {
        // Size needs no request, and a file that cannot be held is not worth one.
        guard ModelFit.fits(bytes: spec.bytes, physicalMemory: physicalMemory) else {
            return ModelCandidate(spec: spec, verdict: .incompatible(.tooLarge))
        }
        guard let header = try? await probe.probe(spec.url) else {
            return ModelCandidate(spec: spec, verdict: .checkedAfterDownload)
        }
        guard header.isLiteRTLM else { return ModelCandidate(spec: spec, verdict: .incompatible(.notALiteRTFile)) }
        // The kind decides the role the model would have. A file of a kind the app has no use for cannot be downloaded:
        // without a role it could not be installed, whatever the runtime made of it afterwards.
        var found = spec
        switch header.kind {
        case .unknown: return ModelCandidate(spec: spec, verdict: .incompatible(.unknownKind))
        case .llm: found.role = .generator
        case .embedder: found.role = .embedder
        }
        guard let required = header.minRuntimeVersion else { return ModelCandidate(spec: found, verdict: .checkedAfterDownload) }
        return ModelCandidate(spec: found, verdict: RuntimeVersion.isNewer(required, than: runtimeVersion)
            ? .incompatible(.needsNewerRuntime) : .compatible)
    }
}
