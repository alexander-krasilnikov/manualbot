import Core
import Foundation
import Ports

/// The evaluation corpus: text sources from the test resources plus documents generated in every other
/// format, so extraction, OCR, chunking and retrieval are all exercised by the same questions.
enum EvalCorpus {
    /// The folder holding `eval.json` and the text sources. Resource bundles are laid out differently on macOS
    /// and iOS (nested or flat), so find it instead of assuming a path.
    static var directory: URL {
        let root = Bundle.module.resourceURL!
        let found = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first { $0.lastPathComponent == "eval.json" }
        return found?.deletingLastPathComponent() ?? root
    }

    static func suite() throws -> EvalSuite {
        try EvalSuite.decode(from: Data(contentsOf: directory.appendingPathComponent("eval.json")))
    }

    /// Writes every document of the suite into `fx` and returns their URLs, in the suite's order.
    static func build(in fx: Fixtures, suite: EvalSuite) throws -> [URL] {
        try suite.documents.map { name in
            switch name {
            case "router-guide.docx": routerGuide(fx)
            case "coffee-machine.pdf": fx.pdf(pages: coffeePages, name: name)
            case "safety-sheet-scanned.pdf": fx.pdf(pages: safetyPages, scanned: true, name: name)
            default: try copy(name, into: fx)
            }
        }
    }

    private static func copy(_ name: String, into fx: Fixtures) throws -> URL {
        fx.write(try Data(contentsOf: directory.appendingPathComponent(name)), as: name)
    }

    static func routerGuide(_ fx: Fixtures) -> URL {
        let body = [
            Fixtures.paragraph("Router Quick Start", style: "Title"),
            Fixtures.paragraph("Setup", style: "Heading1"),
            Fixtures.paragraph("Connect the router power adapter and wait two minutes until the status light turns solid green."),
            Fixtures.paragraph("Wi-Fi password", style: "Heading1"),
            Fixtures.paragraph("The default Wi-Fi password is printed on the label on the bottom of the router. Change it after the first login."),
            Fixtures.paragraph("Admin page", style: "Heading1"),
            Fixtures.paragraph("Open a browser and go to 192.168.8.1 to reach the admin page. The default user name is admin."),
            Fixtures.paragraph("Light meanings", style: "Heading1"),
            Fixtures.table([["Light", "Meaning"], ["Solid green", "Connected to the internet"], ["Blinking red", "No internet connection detected"], ["Blinking blue", "Firmware update in progress"]]),
            Fixtures.paragraph("Factory reset", style: "Heading1"),
            Fixtures.paragraph("Press and hold the reset button with a paperclip for ten seconds until all lights flash. This erases all settings."),
            Fixtures.paragraph("Firmware", style: "Heading1"),
            Fixtures.paragraph("Updates are installed from the admin page under System and then Firmware."),
        ].joined()
        return fx.docx(body: body, name: "router-guide.docx")
    }

    static let coffeePages = [
        "Coffee machine user guide. Fill the water tank with fresh cold water only. Never fill the tank above the maximum mark.",
        "Descaling. Descale the machine every three months. Pour the descaling solution into the water tank, run the descaling programme and rinse with two full tanks of clean water.",
        "Error messages and care. Error C-14 means the brew unit is blocked. Remove the brew unit and rinse it under warm water. Empty the drip tray every day.",
    ]

    static let safetyPages = [
        "SAFETY INSTRUCTIONS. Do not use this appliance near water, a bath or a shower. Keep the appliance away from wet areas.",
        "If you smell gas, do not switch on any electrical device. Open the windows and leave the building.",
    ]
}
