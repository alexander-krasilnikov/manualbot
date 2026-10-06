import CoreGraphics
import Ports
import Synchronization

/// A recognizer that returns scripted lines and records how it was called.
public final class FakeTextRecognizer: TextRecognizing {
    private let handler: @Sendable (CGImage) -> [RecognizedLine]
    private let state = Mutex<[Bool]>([])

    /// Returns the same lines for every image.
    public convenience init(lines: [String] = []) {
        self.init { _ in lines.map { RecognizedLine(text: $0) } }
    }

    public init(handler: @escaping @Sendable (CGImage) -> [RecognizedLine]) {
        self.handler = handler
    }

    /// The `correctLanguage` flag of each call, in order.
    public var calls: [Bool] { state.withLock { $0 } }

    public func recognize(_ image: CGImage, correctLanguage: Bool) async throws -> [RecognizedLine] {
        state.withLock { $0.append(correctLanguage) }
        return handler(image)
    }
}
