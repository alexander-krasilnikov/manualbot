import Foundation
import Ports
import Testing
@testable import Adapters

/// Runs against a real Gemma 4 file. Set GENERATOR_MODEL_PATH to `gemma-4-E2B-it.litertlm` (the app's model; E4B works too).
private let modelPath = ProcessInfo.processInfo.environment["GENERATOR_MODEL_PATH"]

/// No model needed.
struct LiteRTGeneratorWarmUpTests {
    @Test func aMissingModelFileIsReportedAtWarmUp() async {
        let generator = LiteRTGenerator(modelPath: "/nonexistent/model.litertlm")
        await #expect(throws: GeneratorError.modelMissing("/nonexistent/model.litertlm")) { try await generator.warmUp() }
    }
}

@Suite(.serialized, .enabled(if: modelPath != nil))
struct LiteRTGeneratorTests {
    private static let generator = LiteRTGenerator(modelPath: modelPath ?? "")

    private func request(_ prompt: String, max: Int = 48, stop: [String] = []) -> GenerationRequest {
        GenerationRequest(system: "You are a terse assistant.", prompt: prompt, maxTokens: max, temperature: 0, stop: stop)
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await piece in stream { text += piece }
        return text
    }

    @Test func warmUpLoadsTheModelSoTheFirstQuestionIsNotTheOneThatLoadsIt() async throws {
        let generator = LiteRTGenerator(modelPath: modelPath ?? "")
        try await generator.warmUp()
        let text = try await collect(generator.generate(request("Say the word ready.", max: 8)))
        #expect(!text.isEmpty)
        await generator.unload()
    }

    @Test func streamsAnAnswerInPieces() async throws {
        var pieces = 0, text = ""
        for try await piece in Self.generator.generate(request("Name three primary colors.")) { pieces += 1; text += piece }
        #expect(pieces > 3, "should arrive as a stream, got \(pieces) piece(s)")
        #expect(text.lowercased().contains("red") || text.lowercased().contains("blue"), "answer was: \(text)")
    }

    @Test func stoppingEarlyEndsQuicklyAndTheNextRequestStillWorks() async throws {
        _ = try await collect(Self.generator.generate(request("Say ok.", max: 4)))  // load the engine first; only the stop is timed
        let start = ContinuousClock.now
        var n = 0
        for try await _ in Self.generator.generate(request("Write a very long story about a robot.", max: 800)) {
            n += 1
            if n == 4 { break }
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(8), "stopping should not wait for 800 tokens: \(elapsed)")

        let after = try await collect(Self.generator.generate(request("Say the word ready.")))
        #expect(!after.isEmpty, "the generator must be usable after a stopped request")
    }

    @Test func concurrentRequestsAreServedOneAtATime() async throws {
        async let a = collect(Self.generator.generate(request("Say the word alpha.", max: 12)))
        async let b = collect(Self.generator.generate(request("Say the word bravo.", max: 12)))
        let (first, second) = try await (a, b)
        #expect(first.lowercased().contains("alpha"), "\(first)")
        #expect(second.lowercased().contains("bravo"), "\(second)")
    }

    @Test func stopSequencesCutTheOutput() async throws {
        let text = try await collect(Self.generator.generate(request("Count from one to ten in words, comma separated.", max: 80, stop: ["five"])))
        #expect(!text.lowercased().contains("five"), "output should stop before 'five': \(text)")
        #expect(text.lowercased().contains("three"))
    }

    @Test func taskCancellationStopsGeneration() async throws {
        let task = Task { try await collect(Self.generator.generate(request("Write a very long story about a dragon.", max: 800))) }
        try await Task.sleep(for: .seconds(1))
        let start = ContinuousClock.now
        task.cancel()
        _ = try? await task.value
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(!(try await collect(Self.generator.generate(request("Say ok.", max: 8)))).isEmpty)
    }

    @Test func aMissingModelFileIsReported() async throws {
        let missing = LiteRTGenerator(modelPath: "/nonexistent/model.litertlm")
        await #expect(throws: GeneratorError.modelMissing("/nonexistent/model.litertlm")) {
            _ = try await collect(missing.generate(request("hi")))
        }
    }

    @Test func stopIndexFindsTheEarliestSequence() {
        #expect(LiteRTGenerator.stopIndex(in: "abc END def STOP", stops: ["STOP", "END"]).map { "abc END def STOP".distance(from: "abc END def STOP".startIndex, to: $0) } == 4)
        #expect(LiteRTGenerator.stopIndex(in: "abc", stops: []) == nil)
        #expect(LiteRTGenerator.stopIndex(in: "abc", stops: [""]) == nil)
    }
}
