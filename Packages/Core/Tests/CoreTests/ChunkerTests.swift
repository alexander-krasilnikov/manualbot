import Ports
import Testing
@testable import Core

private func sentences(_ n: Int, prefix: String = "S", wordsEach: Int = 10) -> String {
    (0..<n).map { i in
        "\(prefix)\(i) " + (0..<(wordsEach - 1)).map { "w\($0)" }.joined(separator: " ") + "."
    }.joined(separator: " ")
}

private let small = ChunkerConfiguration(targetTokens: 60, maxTokens: 90, overlapTokens: 15, minTailTokens: 20)

@Suite struct ChunkerTests {
    private let counter = ApproximateTokenCounter()

    @Test func emptyInputYieldsNoChunks() {
        #expect(Chunker().chunk([]).isEmpty)
        #expect(Chunker().chunk([Block(text: "   \n ")]).isEmpty)
    }

    @Test func shortDocumentIsOneChunkWithMetadata() {
        let drafts = Chunker().chunk([Block(text: "Hold the button for ten seconds.", page: 4, heading: "Reset")])
        #expect(drafts.count == 1)
        #expect(drafts[0].ordinal == 0)
        #expect(drafts[0].page == 4)
        #expect(drafts[0].heading == "Reset")
    }

    @Test func chunksRespectTheSizeBounds() {
        let chunker = Chunker(configuration: small)
        let drafts = chunker.chunk([Block(text: sentences(60), page: 1)])
        #expect(drafts.count > 3)
        for d in drafts {
            #expect(counter.count(d.text) <= small.maxTokens, "chunk \(d.ordinal) too big: \(counter.count(d.text))")
        }
        // Most chunks land near the target rather than being tiny.
        let sizes = drafts.dropLast().map { counter.count($0.text) }
        #expect(sizes.allSatisfy { $0 >= small.targetTokens / 2 })
    }

    @Test func ordinalsAreSequentialAcrossThePage() {
        let drafts = Chunker(configuration: small).chunk([
            Block(text: sentences(30), page: 1), Block(text: sentences(30), page: 2),
        ])
        #expect(drafts.map(\.ordinal) == Array(0..<drafts.count))
    }

    @Test func neverCrossesAPageBoundary() {
        let drafts = Chunker(configuration: small).chunk([
            Block(text: sentences(8, prefix: "A"), page: 1),
            Block(text: sentences(8, prefix: "B"), page: 2),
        ])
        for d in drafts {
            let touchesA = d.text.contains("A0") || d.text.contains("A7")
            let touchesB = d.text.contains("B0") || d.text.contains("B7")
            #expect(!(touchesA && touchesB), "chunk \(d.ordinal) mixes pages")
            #expect(d.page == (touchesA ? 1 : 2))
        }
        #expect(Set(drafts.compactMap(\.page)) == [1, 2])
    }

    @Test func consecutiveChunksOnAPageOverlap() {
        let drafts = Chunker(configuration: small).chunk([Block(text: sentences(40), page: 1)])
        #expect(drafts.count >= 3)
        for (a, b) in zip(drafts, drafts.dropFirst()) {
            // Sentences are numbered (S0, S1, ...): the last one of A must reappear in B.
            let lastID = a.text.split(separator: " ").last(where: { $0.hasPrefix("S") })!
            #expect(b.text.split(separator: " ").contains(lastID), "chunk \(b.ordinal) should repeat \(lastID) from chunk \(a.ordinal)")
        }
    }

    @Test func noOverlapAcrossPages() {
        let drafts = Chunker(configuration: small).chunk([
            Block(text: sentences(20, prefix: "A"), page: 1), Block(text: sentences(20, prefix: "B"), page: 2),
        ])
        let firstOfPage2 = drafts.first { $0.page == 2 }!
        #expect(!firstOfPage2.text.contains("A19"))
    }

    @Test func headingIsCarriedAsProvenance() {
        let blocks = [
            Block(text: "Installation", kind: .heading, heading: "Installation"),
            Block(text: sentences(12, prefix: "I"), heading: "Installation"),
            Block(text: "Troubleshooting", kind: .heading, heading: "Troubleshooting"),
            Block(text: sentences(12, prefix: "T"), heading: "Troubleshooting"),
        ]
        let drafts = Chunker(configuration: small).chunk(blocks)
        let install = drafts.filter { $0.text.contains("I3") }
        let trouble = drafts.filter { $0.text.contains("T3") }
        #expect(install.allSatisfy { $0.heading == "Installation" })
        #expect(trouble.allSatisfy { $0.heading == "Troubleshooting" })
    }

    @Test func tinyTailIsMergedIntoThePreviousChunk() {
        let config = ChunkerConfiguration(targetTokens: 60, maxTokens: 100, overlapTokens: 10, minTailTokens: 30)
        // Enough for one full chunk plus a one-sentence tail.
        let text = sentences(5, wordsEach: 10) + " Tail sentence here."
        let drafts = Chunker(configuration: config).chunk([Block(text: text, page: 1)])
        #expect(drafts.last?.text.hasSuffix("Tail sentence here.") == true)
        #expect(drafts.allSatisfy { $0.text != "Tail sentence here." })
    }

    @Test func aSingleHugeSentenceIsSplitToFit() {
        let huge = (0..<400).map { "word\($0)" }.joined(separator: " ") + "."
        let drafts = Chunker(configuration: small).chunk([Block(text: huge, page: 1)])
        #expect(drafts.count > 1)
        #expect(drafts.allSatisfy { counter.count($0.text) <= small.maxTokens })
        // No words are lost.
        let words = Set(drafts.flatMap { $0.text.split(separator: " ").map(String.init) })
        #expect(words.contains("word0") && words.contains("word399."))
    }

    @Test func tablesAreKeptWhole() {
        let row = "Model | X100 | 12 V | 3 A"
        let drafts = Chunker().chunk([Block(text: row, kind: .table, page: 2)])
        #expect(drafts.map(\.text) == [row])
    }

    @Test func pagelessSourcesAreChunkedAsOneSegment() {
        let drafts = Chunker(configuration: small).chunk([
            Block(text: sentences(20, prefix: "A")), Block(text: sentences(20, prefix: "B")),
        ])
        #expect(drafts.allSatisfy { $0.page == nil })
        #expect(drafts.contains { $0.text.contains("A19") })
        #expect(drafts.contains { $0.text.contains("B0") })
    }
}
