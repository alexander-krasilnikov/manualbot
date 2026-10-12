import Foundation

/// Whether a model file is small enough for this device: it may take at most a share of its physical memory.
/// A rough filter for the Models page. Failing to load a model is still caught when it is activated.
public enum ModelFit {
    public static let memoryShare = 0.45

    public static func fits(bytes: Int64, physicalMemory: UInt64) -> Bool {
        Double(bytes) <= Double(physicalMemory) * memoryShare
    }
}
