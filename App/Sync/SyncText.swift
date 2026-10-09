import Foundation
import Ports

/// Words and symbols for the sync state, shared by the Sync page, the cloud indicator and the Settings list.
enum SyncText {
    /// A word or two: "Up to date".
    static func summary(_ state: SyncState) -> String {
        switch state {
        case .off: "Off"
        case .connecting: "Connecting…"
        case .syncing: "Syncing…"
        case .upToDate: "Up to date"
        case .paused: "Paused"
        case .error: "Error"
        }
    }

    /// A sentence of what is going on and, where there is something to do, what to do. `nil` when there is nothing to add.
    static func detail(_ state: SyncState) -> String? {
        switch state {
        case .off, .connecting, .syncing, .upToDate:
            return nil
        case .paused(.otherEmbedder(let active, let fleet)):
            return "Sync is paused while \(active) is in use. Every iPad that shares the library uses \(fleet): switch back to it in Models and sync carries on."
        case .paused(.reindexing(let remaining, let fleet)):
            return "\(fleet) is in use again. Sync resumes when the \(remaining) document\(remaining == 1 ? "" : "s") still indexed with another model \(remaining == 1 ? "has" : "have") been indexed again."
        case .error(.credentialsRefused):
            return "The server refused the user name or password. Correct them, then turn sync off and on again."
        case .error(.unreachable):
            return "The server cannot be reached. The app keeps trying, and everything else works as usual."
        case .error(.other(let message)):
            return message
        }
    }

    static func symbol(_ state: SyncState) -> String {
        switch state {
        case .off: "icloud.slash"
        case .connecting, .syncing: "arrow.triangle.2.circlepath.icloud"
        case .upToDate: "checkmark.icloud"
        case .paused: "pause.circle"
        case .error: "exclamationmark.icloud"
        }
    }

    /// "Today at 14:05", or "Not yet".
    static func lastSync(_ date: Date?) -> String {
        guard let date else { return "Not yet" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
