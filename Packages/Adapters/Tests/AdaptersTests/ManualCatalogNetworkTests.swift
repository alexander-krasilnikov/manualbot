import Foundation
import Ports
import Testing
@testable import Adapters

/// Downloads two real catalog entries through the real downloader, to see that publishers' servers still accept the app's
/// requests. Opt in with `RUN_NETWORK_TESTS=1`; it is skipped otherwise, so the suite never needs a network:
///
///     RUN_NETWORK_TESTS=1 swift test --filter ManualCatalogNetworkTests
private let networkTestsEnabled = ProcessInfo.processInfo.environment["RUN_NETWORK_TESTS"] == "1"

@Suite(.serialized, .enabled(if: networkTestsEnabled)) struct ManualCatalogNetworkTests {
    private var bundledCatalogURL: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("App/Resources/ManualCatalog.json")
    }

    private func entry(_ id: String) throws -> ManualCatalogEntry {
        let catalog = try ManualCatalog.decode(from: Data(contentsOf: bundledCatalogURL))
        return try #require(catalog.entry(id: id), "the catalog no longer has \(id): pick another small entry")
    }

    private func download(_ id: String) async throws {
        let entry = try entry(id)
        let downloader = URLSessionManualDownloader()
        let result = try await downloader.download(entry, progress: { _ in })
        defer { result.discard() }
        #expect(result.fileURL.lastPathComponent == "\(id).pdf")
        #expect(try Data(contentsOf: result.fileURL).starts(with: Data("%PDF-".utf8)))
        #expect(result.bytes == entry.bytes, "the publisher has changed the file since the catalog was prepared: run refresh")
        #expect(result.sha256 == entry.sha256, "the publisher has changed the file since the catalog was prepared: run refresh")
    }

    @Test func aNationalLaboratoryEntryDownloads() async throws {
        try await download("small-wind-electric-systems-a-u-s-consumers-guide")
    }

    @Test func aManufacturerEntryDownloads() async throws {
        try await download("bergey-excel-15s-wind-turbine-powersync-25-owners-manual-rev-3")
    }
}
