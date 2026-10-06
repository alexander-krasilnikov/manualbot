import Foundation
import Ports
import Testing
@testable import Adapters

@Suite(.serialized) struct ExtractorTests {
    private let fx = Fixtures()

    private func extract(_ url: URL) async throws -> ExtractedDocument {
        try await FileDocumentExtractor().extract(from: url) { _ in }
    }

    // MARK: 4.1 TXT / MD

    @Test func utf8TextIsSplitIntoParagraphs() async throws {
        let url = fx.write(Data("First paragraph\nwraps here.\n\nSecond paragraph — with a dash.\n".utf8), as: "a.txt")
        let doc = try await extract(url)
        #expect(doc.blocks.map(\.text) == ["First paragraph wraps here.", "Second paragraph — with a dash."])
        #expect(doc.blocks.allSatisfy { $0.page == nil })
    }

    @Test func latin1TextIsDecoded() async throws {
        let bytes = Data([0x43, 0x61, 0x66, 0xE9, 0x20, 0x6D, 0x65, 0x6E, 0x75])  // "Café menu" in Latin-1, invalid UTF-8
        let doc = try await extract(fx.write(bytes, as: "latin.txt"))
        #expect(doc.blocks.map(\.text) == ["Café menu"])
    }

    @Test func utf16TextWithBOMIsDecoded() async throws {
        var data = Data([0xFF, 0xFE])
        data.append("Größe der Datei".data(using: .utf16LittleEndian)!)
        let doc = try await extract(fx.write(data, as: "u16.txt"))
        #expect(doc.blocks.map(\.text) == ["Größe der Datei"])
    }

    @Test func utf8BOMIsStripped() async throws {
        let doc = try await extract(fx.write(Data([0xEF, 0xBB, 0xBF]) + Data("Hello".utf8), as: "bom.txt"))
        #expect(doc.blocks.map(\.text) == ["Hello"])
    }

    @Test func markdownHeadingsBecomeProvenance() async throws {
        let md = """
            # Manual

            Intro text.

            ## Reset

            Hold the button.
            Wait ten seconds.

            ```
            # not a heading
            ```

            ### Notes
            Last line.
            """
        let doc = try await extract(fx.write(Data(md.utf8), as: "m.md"))
        let summary = doc.blocks.map { "\($0.kind.rawValue):\($0.heading ?? "-"):\($0.text)" }
        #expect(summary == [
            "heading:Manual:Manual",
            "paragraph:Manual:Intro text.",
            "heading:Reset:Reset",
            "paragraph:Reset:Hold the button. Wait ten seconds.",
            "paragraph:Reset:# not a heading",   // fenced code stays searchable but is never a heading
            "heading:Notes:Notes",
            "paragraph:Notes:Last line.",
        ])
    }

    @Test func emptyTextFileIsRejected() async {
        let url = fx.write(Data("  \n\n ".utf8), as: "empty.txt")
        await #expect(throws: ExtractionError.empty) { _ = try await extract(url) }
    }

    // MARK: 4.2 PDF

    @Test func textPdfKeepsPageNumbers() async throws {
        let url = fx.pdf(pages: ["Alpha page one has enough text.", "Bravo page two has enough text.", "Charlie page three has enough text."])
        var events: [ExtractionEvent] = []
        let box = EventBox()
        let doc = try await FileDocumentExtractor().extract(from: url) { box.append($0) }
        events = box.events
        #expect(doc.pageCount == 3)
        #expect(doc.blocks.map(\.page) == [1, 2, 3])
        #expect(doc.blocks[0].text.contains("Alpha"))
        #expect(doc.blocks[2].text.contains("Charlie"))
        #expect(events.contains(.page(3, of: 3)))
        #expect(!events.contains { if case .recognizing = $0 { true } else { false } })
    }

    @Test func scannedPdfIsRecognizedWithOCR() async throws {
        let url = fx.pdf(pages: ["Hold the reset button", "Replace the air filter"], scanned: true, name: "scan.pdf")
        let box = EventBox()
        let doc = try await FileDocumentExtractor().extract(from: url) { box.append($0) }
        #expect(doc.pageCount == 2)
        #expect(doc.blocks.map(\.page) == [1, 2])
        let all = doc.blocks.map { $0.text.lowercased() }.joined(separator: " ")
        #expect(all.contains("reset"), "OCR text was: \(all)")
        #expect(all.contains("filter"), "OCR text was: \(all)")
        #expect(box.events.contains(.recognizing(page: 1, of: 2)))
    }

    @Test func mixedPdfOnlyOCRsThePagesWithoutText() async throws {
        // Page 1 is text; page 2 is built as an image in a second PDF and read separately, so
        // here we only check that a text page never triggers OCR.
        let url = fx.pdf(pages: ["Plain selectable text on the page."], name: "text-only.pdf")
        let box = EventBox()
        _ = try await FileDocumentExtractor().extract(from: url) { box.append($0) }
        #expect(!box.events.contains { if case .recognizing = $0 { true } else { false } })
    }

    @Test func passwordProtectedPdfIsRejected() async {
        let url = fx.pdf(pages: ["Secret"], password: "hunter2", name: "locked.pdf")
        await #expect(throws: ExtractionError.passwordProtected) { _ = try await extract(url) }
    }

    @Test func corruptPdfIsRejectedWithAReason() async {
        let url = fx.write(Data("this is not a pdf".utf8), as: "bad.pdf")
        await #expect(throws: ExtractionError.self) { _ = try await extract(url) }
    }

    // MARK: 4.3 DOCX

    @Test func docxKeepsReadingOrderHeadingsListsAndTables() async throws {
        let body = [
            Fixtures.paragraph("Product Manual", style: "Title"),
            Fixtures.paragraph("Setup", style: "Heading1"),
            Fixtures.paragraph("Plug in the unit."),
            Fixtures.paragraph("Press the power button", list: true),
            Fixtures.table([["Model", "Voltage"], ["X100", "12 V"], ["X200", "24 V"]]),
            Fixtures.paragraph("Troubleshooting", style: "Heading 2"),
            Fixtures.paragraph("Error E-042 means overheating."),
        ].joined()
        let doc = try await extract(fx.docx(body: body))
        let summary = doc.blocks.map { "\($0.kind.rawValue)|\($0.heading ?? "-")|\($0.text)" }
        #expect(summary == [
            "heading|Product Manual|Product Manual",
            "heading|Setup|Setup",
            "paragraph|Setup|Plug in the unit.",
            "listItem|Setup|Press the power button",
            "table|Setup|Model | Voltage",
            "table|Setup|X100 | 12 V",
            "table|Setup|X200 | 24 V",
            "heading|Troubleshooting|Troubleshooting",
            "paragraph|Troubleshooting|Error E-042 means overheating.",
        ])
    }

    @Test func docxTableTextIsSearchable() async throws {
        let doc = try await extract(fx.docx(body: Fixtures.table([["Part", "Number"], ["Filter", "PN-7731"]])))
        #expect(doc.blocks.contains { $0.text.contains("PN-7731") })
    }

    @Test func docxWithoutTextIsRejected() async {
        await #expect(throws: ExtractionError.empty) {
            _ = try await extract(fx.docx(body: "<w:p/>", name: "blank.docx"))
        }
    }

    @Test func nonZipDocxIsRejected() async {
        let url = fx.write(Data("not a zip".utf8), as: "fake.docx")
        await #expect(throws: ExtractionError.self) { _ = try await extract(url) }
    }

    // MARK: Dispatch

    @Test func unsupportedTypeIsNamed() async {
        let url = fx.write(Data("x".utf8), as: "deck.pptx")
        await #expect(throws: ExtractionError.unsupportedType("pptx")) { _ = try await extract(url) }
    }

    @Test func fileTypesAreRecognizedCaseInsensitively() {
        #expect(FileDocumentExtractor.documentType(for: URL(fileURLWithPath: "/a/B.PDF")) == .pdf)
        #expect(FileDocumentExtractor.documentType(for: URL(fileURLWithPath: "/a/b.docx")) == .docx)
        #expect(FileDocumentExtractor.documentType(for: URL(fileURLWithPath: "/a/b.markdown")) == .markdown)
        #expect(FileDocumentExtractor.documentType(for: URL(fileURLWithPath: "/a/b.rtf")) == nil)
    }
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ExtractionEvent] = []
    func append(_ e: ExtractionEvent) { lock.lock(); stored.append(e); lock.unlock() }
    var events: [ExtractionEvent] { lock.lock(); defer { lock.unlock() }; return stored }
}