public struct GenerationRequest: Sendable, Equatable {
    public var system: String
    public var prompt: String
    public var maxTokens: Int
    public var temperature: Float
    public var stop: [String]

    public init(
        system: String, prompt: String, maxTokens: Int = 512, temperature: Float = 0.2, stop: [String] = []
    ) {
        self.system = system
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.stop = stop
    }
}

public protocol Generator: Sendable {
    /// Streams generated text fragments. Cancelling the consuming task, or ending iteration early,
    /// MUST stop generation and release the runtime's resources.
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error>
}
