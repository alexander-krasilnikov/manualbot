import CryptoKit
import Foundation
import Ports
import ZIPFoundation

public enum ModelInstallError: Error, LocalizedError, Equatable {
    case invalidArchive
    case unsafeArchiveEntry(String)
    case missingEntry(String)
    case bundledModel

    public var errorDescription: String? {
        switch self {
        case .bundledModel: "This model ships inside the app and cannot be installed."
        case .invalidArchive: "The downloaded archive could not be opened."
        case .unsafeArchiveEntry(let path): "The archive contains an unsafe path (\(path)) and was rejected."
        case .missingEntry(let name): "The archive does not contain the expected model (\(name))."
        }
    }
}

/// `ModelFiles` on the real file system. Models live under `root/<id>/<version>/<fileName>`.
/// Point `root` at Application Support (not visible in the Files app) and it is excluded from backup.
public struct FileModelFiles: ModelFiles {
    public let root: URL
    /// Where models that ship inside the app live (`<bundleRoot>/<id>/<fileName>`); the app's resource folder.
    public let bundleRoot: URL?
    private let availableBytesOverride: (@Sendable () throws -> Int64)?

    public init(root: URL, bundleRoot: URL? = nil, availableBytesOverride: (@Sendable () throws -> Int64)? = nil) {
        self.root = root
        self.bundleRoot = bundleRoot
        self.availableBytesOverride = availableBytesOverride
    }

    public func availableBytes() throws -> Int64 {
        if let availableBytesOverride { return try availableBytesOverride() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    public func installedURL(for spec: ModelSpec) -> URL {
        if spec.packaging == .bundled {
            return (bundleRoot ?? root).appendingPathComponent(spec.id, isDirectory: true).appendingPathComponent(spec.fileName)
        }
        return root.appendingPathComponent(spec.id, isDirectory: true)
            .appendingPathComponent(spec.version, isDirectory: true)
            .appendingPathComponent(spec.fileName)
    }

    private func versionDirectory(for spec: ModelSpec) -> URL {
        root.appendingPathComponent(spec.id, isDirectory: true).appendingPathComponent(spec.version, isDirectory: true)
    }

    /// Written after an archive has been fully unpacked; without it the model does not count as installed.
    private func marker(for spec: ModelSpec) -> URL { versionDirectory(for: spec).appendingPathComponent(".installed") }

    public func isInstalled(_ spec: ModelSpec) -> Bool {
        if spec.packaging == .bundled { return bundleRoot != nil && FileManager.default.fileExists(atPath: installedURL(for: spec).path) }
        if spec.packaging == .zip {
            let fm = FileManager.default
            return fm.fileExists(atPath: marker(for: spec).path) && fm.fileExists(atPath: installedURL(for: spec).path)
        }
        let path = installedURL(for: spec).path
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber else { return false }
        return size.int64Value == spec.bytes
    }

    public func sha256(of file: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                guard let block = try handle.read(upToCount: 1 << 20), !block.isEmpty else { break }
                hasher.update(data: block)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    public func install(_ file: URL, for spec: ModelSpec) throws {
        if spec.packaging == .bundled { throw ModelInstallError.bundledModel }
        if spec.packaging == .zip { return try installArchive(file, for: spec) }
        let fm = FileManager.default
        var destination = installedURL(for: spec)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: file, to: destination)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try destination.setResourceValues(values)
        // Exclude the model directory too, so nothing beside the file is backed up either.
        var directory = root.appendingPathComponent(spec.id, isDirectory: true)
        try directory.setResourceValues(values)
    }

    /// Unpacks into a scratch directory first and moves it into place, so a failed or unsafe archive
    /// never leaves a half-installed model behind.
    private func installArchive(_ file: URL, for spec: ModelSpec) throws {
        let fm = FileManager.default
        guard let archive = try? Archive(url: file, accessMode: .read) else { throw ModelInstallError.invalidArchive }
        let scratch = root.appendingPathComponent(".unpack-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let base = scratch.standardizedFileURL.path + "/"
        for entry in archive {
            let target = scratch.appendingPathComponent(entry.path).standardizedFileURL
            guard !entry.path.hasPrefix("/"), target.path.hasPrefix(base) else { throw ModelInstallError.unsafeArchiveEntry(entry.path) }
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: target)
        }
        guard fm.fileExists(atPath: scratch.appendingPathComponent(spec.fileName).path) else {
            throw ModelInstallError.missingEntry(spec.fileName)
        }

        let destination = versionDirectory(for: spec)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: scratch, to: destination)
        try Data().write(to: marker(for: spec))

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = root.appendingPathComponent(spec.id, isDirectory: true)
        try directory.setResourceValues(values)
        discard(file)
    }

    public func discard(_ file: URL) { try? FileManager.default.removeItem(at: file) }

    public func uninstall(_ spec: ModelSpec) {
        guard spec.packaging != .bundled else { return }  // the app bundle is read-only
        try? FileManager.default.removeItem(at: root.appendingPathComponent(spec.id, isDirectory: true)
            .appendingPathComponent(spec.version, isDirectory: true))
    }
}
