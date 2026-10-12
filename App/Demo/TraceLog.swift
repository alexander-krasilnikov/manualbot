import Foundation
import Ports

/// The events of one user operation (or of background activity), in the order they happened.
struct TraceGroup: Identifiable, Equatable {
    static let backgroundID = "background"

    let id: String
    var operation: TraceOperation?
    var events: [TraceEvent]

    var isBackground: Bool { operation == nil }
    var title: String { operation?.title ?? "Background activity" }
    /// An event is recorded when its step finishes, so a step began `duration` earlier.
    var startedAt: Date { events.map { $0.timestamp.addingTimeInterval(-($0.duration ?? 0)) }.min() ?? .distantPast }
    var endedAt: Date { events.map(\.timestamp).max() ?? .distantPast }
    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

/// The recent history shown in the X-ray panel: events grouped by operation, oldest group first.
struct TraceLog: Equatable {
    /// Operation groups kept. Older ones are dropped as new ones arrive.
    static let maxGroups = 50
    static let maxBackgroundEvents = 300

    private(set) var groups: [TraceGroup] = []
    /// The operation group that received the latest event (background activity does not count).
    private(set) var latestID: String?

    mutating func append(_ event: TraceEvent) {
        let id = event.operation?.id ?? TraceGroup.backgroundID
        if let index = groups.firstIndex(where: { $0.id == id }) {
            groups[index].events.append(event)
            if groups[index].isBackground, groups[index].events.count > Self.maxBackgroundEvents {
                groups[index].events.removeFirst(groups[index].events.count - Self.maxBackgroundEvents)
            }
        } else {
            groups.append(TraceGroup(id: id, operation: event.operation, events: [event]))
            let operations = groups.filter { !$0.isBackground }
            if operations.count > Self.maxGroups, let oldest = operations.first {
                groups.removeAll { $0.id == oldest.id }
            }
        }
        if event.operation != nil { latestID = id }
    }

    mutating func clear() {
        groups = []
        latestID = nil
    }
}
