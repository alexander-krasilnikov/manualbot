import Core
import Foundation
import Ports
import Testing
@testable import Adapters

/// The whole app pipeline on real parts. Needs both EMBEDDER_MODEL_DIR and GENERATOR_MODEL_PATH.
private let embedderDir = ProcessInfo.processInfo.environment["EMBEDDER_MODEL_DIR"]
private let generatorPath = ProcessInfo.processInfo.environment["GENERATOR_MODEL_PATH"]

@Suite(.serialized, .enabled(if: embedderDir != nil && generatorPath != nil))
struct RealStackTests {
    static let identity = EmbeddingModelIdentity(id: "embeddinggemma-300m", version: "1", dimensions: 768)

    private let fx = Fixtures()

    struct Stack {
        let repo: CouchbaseDocumentRepository
        let embedder: CoreMLEmbedder
        let generator: LiteRTGenerator
        let tokenizer: GemmaTokenizer
        let ingestion: IngestionService
        let retriever: Retriever
        let chat: ChatService
        let root: URL
    }

    private func makeStack(_ config: RetrievalConfiguration = .init()) async throws -> Stack {
        let dir = URL(fileURLWithPath: try #require(embedderDir))
        let tokenizer = try await GemmaTokenizer(folder: dir.appendingPathComponent("hf_model"))
        let embedder = CoreMLEmbedder(modelURL: dir.appendingPathComponent("encoder.mlmodelc"), tokenizer: tokenizer, identity: Self.identity)
        let generator = LiteRTGenerator(modelPath: try #require(generatorPath))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stack-\(UUID().uuidString)")
        let repo = try CouchbaseDocumentRepository(directory: root.appendingPathComponent("db"), originalsCache: root.appendingPathComponent("o"), embedding: Self.identity)
        let ingestion = IngestionService(
            extractor: FileDocumentExtractor(), embedder: embedder, repository: repo, jobs: repo,
            chunker: Chunker(configuration: .embeddingGemma, counter: tokenizer), supportedType: FileDocumentExtractor.documentType(for:))
        let retriever = Retriever(embedder: embedder, search: repo, repository: repo, configuration: config)
        return Stack(repo: repo, embedder: embedder, generator: generator, tokenizer: tokenizer, ingestion: ingestion, retriever: retriever,
                     chat: ChatService(chats: repo, retriever: retriever, generator: generator), root: root)
    }

    private let manual = """
        # X200 Air Purifier Manual

        ## Resetting the unit
        To reset the X200 to factory defaults, hold the power button for ten seconds until the indicator light blinks twice. \
        Release the button and wait thirty seconds before switching the unit on again.

        ## Resetting the older X100 model
        The older X100 has no power button reset. Instead, press the small recessed button on the back of the unit with a paperclip for five seconds until the light turns amber.

        ## Error codes
        Error E-042 means the motor has overheated. Switch the unit off and wait thirty minutes before restarting it. \
        Error E-107 means the filter is missing or not seated correctly.

        ## Filter replacement
        Replace the HEPA filter every six months. Open the rear panel by pressing the two latches, pull out the old filter and slide in the new one. \
        The replacement filter part number is PN-7731.
        """

    private let warranty = """
        # Warranty

        The X200 is covered by a two year limited warranty from the date of purchase. The warranty does not cover damage caused by \
        misuse, unauthorized repairs or the use of filters other than genuine replacement filters. Keep your receipt as proof of purchase.
        """

    private func ingest(_ stack: Stack, _ files: [(String, String)]) async throws -> [String] {
        var ids: [String] = []
        for (name, text) in files { ids.append(try await stack.ingestion.enqueue(fileURL: fx.write(Data(text.utf8), as: name))) }
        await stack.ingestion.run()
        for id in ids {
            let job = try await stack.repo.job(docId: id)
            #expect(job?.state == .ready, "\(String(describing: job))")
        }
        return ids
    }

    private func ask(_ stack: Stack, _ chatID: String, _ question: String) async throws -> MessageRecord {
        var reply: MessageRecord?
        for try await event in stack.chat.ask(question, in: chatID) { if case .completed(let m) = event { reply = m } }
        return try #require(reply)
    }

    @Test func answersFromRealDocumentsWithRealCitations() async throws {
        let stack = try await makeStack()
        defer { try? FileManager.default.removeItem(at: stack.root) }
        let ids = try await ingest(stack, [("x200-manual.md", manual), ("warranty.txt", warranty)])
        #expect(try await stack.repo.activeChunks(docId: ids[0]).count >= 2)

        let chat = try await stack.repo.createChat()
        let reset = try await ask(stack, chat.id, "How do I reset the X200 to factory defaults?")
        print("REAL reset:", reset.notFound ? "NOT FOUND" : reset.text, "| cited:", reset.citations.map { "\($0.docTitle) \($0.page.map(String.init) ?? "-") §\($0.heading ?? "-")" })
        #expect(!reset.notFound)
        #expect(reset.text.lowercased().contains("ten seconds") || reset.text.contains("10 seconds"), "answer: \(reset.text)")
        #expect(reset.citations.contains { $0.docTitle == "x200-manual" })
        #expect(reset.text.contains("["), "answer should carry citation markers")

        let code = try await ask(stack, chat.id, "What does error E-042 mean?")
        print("REAL E-042:", code.text)
        #expect(!code.notFound)
        #expect(code.text.lowercased().contains("overheat"), "answer: \(code.text)")

        let warrantyAnswer = try await ask(stack, chat.id, "How long is the warranty?")
        print("REAL warranty:", warrantyAnswer.text, "| cited:", warrantyAnswer.citations.map(\.docTitle))
        #expect(warrantyAnswer.text.lowercased().contains("two") || warrantyAnswer.text.contains("2"), "answer: \(warrantyAnswer.text)")
        #expect(warrantyAnswer.citations.contains { $0.docTitle == "warranty" })
    }

    @Test func aFollowUpQuestionIsResolvedUsingTheConversation() async throws {
        let stack = try await makeStack()
        defer { try? FileManager.default.removeItem(at: stack.root) }
        _ = try await ingest(stack, [("x200-manual.md", manual), ("warranty.txt", warranty)])
        let chat = try await stack.repo.createChat()

        let first = try await ask(stack, chat.id, "How do I reset the X200?")
        #expect(first.text.lowercased().contains("ten seconds"), "answer: \(first.text)")

        // "the X100" alone says nothing about resetting; the conversation supplies that.
        let followUp = try await ask(stack, chat.id, "What about the X100?")
        print("REAL follow-up query:", followUp.standaloneQuery ?? "-", "| answer:", followUp.text)
        let query = try #require(followUp.standaloneQuery).lowercased()
        #expect(query.contains("x100") && query.contains("reset"), "the rewrite should carry the topic: \(query)")
        #expect(!followUp.notFound)
        #expect(followUp.text.lowercased().contains("five seconds") || followUp.text.lowercased().contains("paperclip"), "answer: \(followUp.text)")
    }

    @Test func offTopicQuestionsAreRefusedWithoutInventing() async throws {
        let stack = try await makeStack()
        defer { try? FileManager.default.removeItem(at: stack.root) }
        _ = try await ingest(stack, [("x200-manual.md", manual), ("warranty.txt", warranty)])
        let chat = try await stack.repo.createChat()
        for question in ["What is the capital of France?", "Who won the world cup in 2010?", "Write me a poem about the sea"] {
            let reply = try await ask(stack, chat.id, question)
            print("REAL offtopic “\(question)”:", reply.notFound ? "NOT FOUND" : "ANSWERED: \(reply.text)")
            #expect(reply.notFound, "“\(question)” should be refused, got: \(reply.text)")
        }
    }

    @Test func distancesForCalibration() async throws {
        let stack = try await makeStack()
        defer { try? FileManager.default.removeItem(at: stack.root) }
        _ = try await ingest(stack, [("x200-manual.md", manual), ("warranty.txt", warranty)])
        let answerable = ["How do I reset the X200 to factory defaults?", "reset", "What does E-042 mean?", "How often should I change the filter?",
                          "how long is the warranty", "What is the part number of the filter?", "the unit is blinking twice what now",
                          "Does the warranty cover misuse?", "how do I open the rear panel", "what if the motor overheats"]
        let offTopic = ["What is the capital of France?", "Who won the world cup in 2010?", "Write me a poem about the sea", "how do I bake bread",
                        "what is the weather today", "tell me a joke", "explain quantum computing", "best pizza in Rome"]
        for (label, list) in [("ANSWERABLE", answerable), ("OFFTOPIC", offTopic)] {
            for q in list {
                let r = try await stack.retriever.retrieve(q)
                print("CALIB \(label) d=\(String(format: "%.3f", r.bestDistance ?? -1)) relevant=\(r.relevant) — \(q)")
            }
        }
    }
}
