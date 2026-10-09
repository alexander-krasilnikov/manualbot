import Foundation

/// Dotted version numbers of the LiteRT-LM runtime, such as "0.18.0".
public enum RuntimeVersion {
    /// Compares part by part: "0.18.1" is newer than "0.18.0", and "0.18" equals "0.18.0".
    public static func isNewer(_ version: String, than other: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = other.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
