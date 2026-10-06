import CoreGraphics
import Foundation
import Ports
import PortsTesting
import Testing

@Suite struct ImagePortsTests {
    /// Coloured blocks from a seed; `zoom` > 1 crops in a little, like a second photo of the same scene.
    static func picture(_ seed: Int, zoom: CGFloat = 1) -> CGImage {
        let size = 128
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let s = CGFloat(size)
        context.translateBy(x: -(zoom - 1) * s / 2, y: -(zoom - 1) * s / 2)
        context.scaleBy(x: zoom, y: zoom)
        var state = UInt64(seed) &* 0x9E3779B97F4A7C15 | 1
        func next() -> CGFloat {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return CGFloat(state % 1000) / 1000
        }
        for row in 0..<4 {
            for column in 0..<4 {
                context.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
                context.fill(CGRect(x: CGFloat(column) * s / 4, y: CGFloat(row) * s / 4, width: s / 4, height: s / 4))
            }
        }
        return context.makeImage()!
    }

    static func distance(_ a: [Float], _ b: [Float]) -> Float { 1 - zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    // MARK: 2.1 fakes

    @Test func fakeFeaturerKeepsARecropCloserThanAnotherPicture() async throws {
        let featurer = FakeImageFeaturer()
        let original = try await featurer.features(of: Self.picture(1))
        let recrop = try await featurer.features(of: Self.picture(1, zoom: 1.05))
        let other = try await featurer.features(of: Self.picture(2))
        #expect(original.count == featurer.identity.dimensions)
        #expect(abs(original.reduce(0) { $0 + $1 * $1 }.squareRoot() - 1) < 1e-4)
        #expect(Self.distance(original, recrop) < Self.distance(original, other))
        #expect(try await featurer.features(of: Self.picture(1)) == original)
    }

    @Test func fakeTextRecognizerReturnsScriptedLinesAndRecordsCalls() async throws {
        let recognizer = FakeTextRecognizer(lines: ["MODEL X200-B", "S/N 4471-22"])
        let lines = try await recognizer.recognize(Self.picture(1), correctLanguage: false)
        #expect(lines.map(\.text) == ["MODEL X200-B", "S/N 4471-22"])
        _ = try await recognizer.recognize(Self.picture(1), correctLanguage: true)
        #expect(recognizer.calls == [false, true])
    }

    // MARK: 2.2 models

    @Test func recordsSavedBeforeImagesExistStillDecode() throws {
        let message = #"{"id":"m","chatId":"c","role":"assistant","text":"hi","citations":[{"n":1,"chunkId":"d:1:0","docId":"d","docTitle":"T","snippet":"s"}],"stopped":false,"notFound":false,"createdAt":1}"#
        let decoded = try JSONDecoder().decode(MessageRecord.self, from: Data(message.utf8))
        #expect(!decoded.hasAttachment && decoded.imageMatches.isEmpty && !decoded.matchesOnly)
        #expect(decoded.citations[0].imageId == nil)

        let job = #"{"docId":"d","targetGeneration":2,"state":"embedding","progress":0.5,"nextOrdinal":16,"enqueuedAt":1}"#
        let decodedJob = try JSONDecoder().decode(IngestJobRecord.self, from: Data(job.utf8))
        #expect(decodedJob.nextImage == 0 && decodedJob.nextOrdinal == 16)

        let chunk = #"{"docId":"d","generation":1,"ordinal":0,"text":"t","embedding":[1],"embeddingModel":"m"}"#
        #expect(try JSONDecoder().decode(Chunk.self, from: Data(chunk.utf8)).imageId == nil)
    }

    @Test func newFieldsRoundTrip() throws {
        let match = ImageMatch(imageId: "d:1:img:0", docId: "d", docTitle: "Manual", page: 14, distance: 0.2)
        let message = MessageRecord(
            id: "m", chatId: "c", role: .assistant, text: "x", createdAt: Date(timeIntervalSince1970: 5),
            hasAttachment: true, imageMatches: [match], matchesOnly: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        #expect(try decoder.decode(MessageRecord.self, from: encoder.encode(message)) == message)

        let job = IngestJobRecord(docId: "d", targetGeneration: 1, state: .analyzingImages, nextImage: 8, enqueuedAt: Date(timeIntervalSince1970: 5))
        #expect(try decoder.decode(IngestJobRecord.self, from: encoder.encode(job)) == job)
    }

    @Test func imageIDsNeverParseAsChunkIDsAndBack() {
        let imageID = ImageRecord.makeID(docId: "doc", generation: 3, n: 7)
        #expect(imageID == "doc:3:img:7")
        #expect(Chunk.parseID(imageID) == nil)
        let parts = ImageRecord.parseID(imageID)
        #expect(parts?.docId == "doc" && parts?.generation == 3 && parts?.n == 7)

        let chunkID = Chunk.makeID(docId: "doc", generation: 3, ordinal: 7)
        #expect(ImageRecord.parseID(chunkID) == nil)
        #expect(Chunk.parseID(chunkID)?.ordinal == 7)
    }

    // MARK: 2.3 repository

    private func write(_ repo: InMemoryDocumentRepository, docId: String, generation: Int, count: Int, page: Int? = nil, heading: String? = nil) async {
        await repo.writeImages((0..<count).map { n in
            ImageWrite(
                record: ImageRecord(
                    docId: docId, generation: generation, n: n, page: page ?? n + 1, heading: heading, width: 10, height: 10,
                    features: [1], featureModel: "m"),
                displayCopy: Data([UInt8(generation), UInt8(n)]))
        })
    }

    @Test func activateRemovesOtherGenerationsImagesAndChunks() async throws {
        let repo = InMemoryDocumentRepository()
        await repo.upsert(DocumentRecord(id: "d", title: "T", type: .pdf))
        await write(repo, docId: "d", generation: 1, count: 2)
        try await repo.activate(generation: 1, for: "d")
        #expect(await repo.activeImages(docId: "d").count == 2)

        await write(repo, docId: "d", generation: 2, count: 3)
        #expect(await repo.activeImages(docId: "d").count == 2)       // still the old set until switched
        try await repo.activate(generation: 2, for: "d")
        #expect(await repo.activeImages(docId: "d").count == 3)
        #expect(await repo.images(docId: "d", generation: 1).isEmpty)
        #expect(await repo.imageData(id: ImageRecord.makeID(docId: "d", generation: 1, n: 0)) == nil)
        #expect(await repo.imageData(id: ImageRecord.makeID(docId: "d", generation: 2, n: 1)) == Data([2, 1]))
    }

    @Test func lookupsByPageAndHeadingAndDeletion() async throws {
        let repo = InMemoryDocumentRepository()
        await repo.upsert(DocumentRecord(id: "d", title: "T", type: .pdf))
        await write(repo, docId: "d", generation: 1, count: 3, heading: "Install")
        await repo.writeChunks([
            Chunk(docId: "d", generation: 1, ordinal: 0, page: 2, heading: "Install", text: "a", embedding: [1], embeddingModel: "m"),
            Chunk(docId: "d", generation: 1, ordinal: 1, page: 3, heading: "Other", text: "b", embedding: [1], embeddingModel: "m"),
        ])
        try await repo.activate(generation: 1, for: "d")
        #expect(await repo.activeImages(docId: "d", page: 2).map(\.n) == [1])
        #expect(await repo.activeImages(docId: "d", heading: "Install").count == 3)
        #expect(await repo.activeChunks(docId: "d", page: 3).map(\.text) == ["b"])
        #expect(await repo.activeChunks(docId: "d", heading: "Install").map(\.text) == ["a"])

        await repo.deleteDocument(id: "d")
        #expect(await repo.images(docId: "d", generation: 1).isEmpty)
    }

    @Test func attachmentIsKeptWhenTheMessageIsSavedAgainAndRemovedWithTheChat() async throws {
        let repo = InMemoryDocumentRepository()
        let chat = try await repo.createChat()
        let message = MessageRecord(id: "m", chatId: chat.id, role: .user, text: "q", hasAttachment: true)
        await repo.upsert(message: message, attachment: Data([1, 2, 3]))
        await repo.upsert(message: message)
        #expect(await repo.attachment(messageId: "m") == Data([1, 2, 3]))
        await repo.deleteChat(id: chat.id)
        #expect(await repo.attachment(messageId: "m") == nil)
    }
}
