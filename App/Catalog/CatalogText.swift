import Core
import Foundation
import Ports

/// The words of the manual catalog: what an entry's state and a failed download say, in plain terms.
enum CatalogText {
    /// The import limit as it is shown everywhere else ("20 MB").
    static var limit: String { IngestionError.sizeText(IngestionService.maxOriginalBytes) }

    static let updatedNote = "The publisher has updated this file since the catalog was prepared."

    static let offlineMessage = "No internet connection. You can browse the catalog, but importing needs a connection."

    static func kind(_ kind: ManualKind) -> String {
        switch kind {
        case .manual: "Manual"
        case .catalog: "Catalog"
        case .whitepaper: "Whitepaper"
        }
    }

    static func size(_ entry: ManualCatalogEntry) -> String { IngestionError.sizeText(entry.bytes) }

    /// "413 pages", or "1 page".
    static func pages(_ entry: ManualCatalogEntry) -> String { "\(entry.pages) page\(entry.pages == 1 ? "" : "s")" }

    /// What the first download from a host says before it starts: where the file comes from, and that nothing is sent about the user.
    static func notice(hosts: [String]) -> String {
        let names = hosts.formatted(.list(type: .and))
        let source = hosts.count == 1 ? "the publisher’s server, \(names)" : "the publishers’ servers: \(names)"
        return "The PDF will be downloaded from \(source). Nothing about you or your library is sent. The document stays on this iPad."
    }

    static func failure(_ error: any Error, for entry: ManualCatalogEntry) -> CatalogViewModel.Failure {
        guard let error = error as? ManualDownloadError else {
            return CatalogViewModel.Failure(message: error.localizedDescription, canOpenInBrowser: false)
        }
        switch error {
        case .offline:
            return .init(message: "No internet connection. Connect and try again.", canOpenInBrowser: false)
        case .blocked:
            return .init(message: "The publisher does not allow automatic downloads. Open the address in the browser, save the PDF, and import it with Files.", canOpenInBrowser: true)
        case .gone, .notPDF:
            return .init(message: "This link no longer leads to a PDF. The publisher may have moved or replaced it.", canOpenInBrowser: true)
        case .tooLarge(let bytes):
            let size = bytes.map { "\(IngestionError.sizeText($0)), over" } ?? "larger than"
            return .init(message: "“\(entry.title)” is \(size) the \(limit) limit for documents, so it was not downloaded.", canOpenInBrowser: false)
        case .http(let status):
            return .init(message: "The publisher’s server answered with an error (HTTP \(status)). Try again later.", canOpenInBrowser: false)
        case .connectionLost:
            return .init(message: "The connection was lost before the download finished. Try again.", canOpenInBrowser: false)
        }
    }
}
