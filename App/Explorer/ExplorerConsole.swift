import Foundation
import Observation
import Ports

/// A query ready to run, for a presenter who does not want to type on stage.
struct StarterQuery: Identifiable, Equatable {
    let title: String
    let sql: String
    var id: String { title }

    static func all(firstDocumentID: String?) -> [StarterQuery] {
        let document = (firstDocumentID ?? "document id").replacingOccurrences(of: "\"", with: "")
        return [
            StarterQuery(
                title: "Keyword search",
                sql: """
                    SELECT meta().id AS id, docId, page, text
                    FROM manualbot.chunks
                    WHERE MATCH(chunks_fts, "error")
                    ORDER BY RANK(chunks_fts)
                    LIMIT 20
                    """),
            StarterQuery(
                title: "Chunks of one document",
                sql: """
                    SELECT meta().id AS id, generation, ordinal, page, heading
                    FROM manualbot.chunks
                    WHERE docId = "\(document)"
                    ORDER BY generation, ordinal
                    LIMIT 50
                    """),
            StarterQuery(
                title: "Ingest jobs by state",
                sql: "SELECT state, COUNT(*) AS jobs FROM manualbot.ingestJobs GROUP BY state"),
        ]
    }
}

/// The SQL++ console. It runs what is typed (Couchbase Lite SQL++ only reads), keeps at most `rowLimit` rows, and
/// refuses parameters. A cancelled query is forgotten: the database cannot interrupt it, but its result is dropped.
@MainActor @Observable
final class ExplorerConsole {
    static let rowLimit = 200

    enum State: Equatable {
        case idle
        case running
        case finished(QueryRows)
        case failed(String)
    }

    enum PlanState: Equatable {
        case none
        case loading
        case ready(String)
        case failed(String)
    }

    var inspector: (any TraceInspector)?
    var sql = ""
    private(set) var state = State.idle
    private(set) var plan = PlanState.none
    /// Queries that were cancelled but are still running in the database.
    private(set) var abandoned = 0

    @ObservationIgnored private var runID = 0

    var databaseStillBusy: Bool { abandoned > 0 }

    func use(_ starter: StarterQuery) {
        sql = starter.sql
        state = .idle
        plan = .none
    }

    func run() async {
        guard state != .running else { return }
        let text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let inspector else { return }
        plan = .none
        if let name = Self.parameter(in: text) {
            state = .failed("Parameters are not supported ($\(name)). Write the value into the query instead.")
            return
        }
        runID += 1
        let mine = runID
        state = .running
        do {
            let rows = try await inspector.query(sql: text, limit: Self.rowLimit)
            if mine != runID { abandoned -= 1; return }
            state = .finished(rows)
        } catch {
            if mine != runID { abandoned -= 1; return }
            state = .failed(error.localizedDescription)
        }
    }

    /// Gives the editor back at once and drops the result when it arrives.
    func cancel() {
        guard state == .running else { return }
        abandoned += 1
        runID += 1
        state = .idle
    }

    func loadPlan() async {
        let text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let inspector else { return }
        if let name = Self.parameter(in: text) {
            plan = .failed("Parameters are not supported ($\(name)).")
            return
        }
        plan = .loading
        do {
            plan = .ready(try await inspector.plan(sql: text))
        } catch {
            plan = .failed(error.localizedDescription)
        }
    }

    /// The name of the first `$parameter` outside quotes (strings in single or double quotes, names in backticks).
    static func parameter(in sql: String) -> String? {
        let characters = Array(sql)
        var quote: Character?
        var index = 0
        while index < characters.count {
            let c = characters[index]
            if let open = quote {
                if c == "\\" { index += 1 } else if c == open { quote = nil }
            } else if c == "\"" || c == "'" || c == "`" {
                quote = c
            } else if c == "$", index + 1 < characters.count, characters[index + 1].isLetter || characters[index + 1].isNumber
                || characters[index + 1] == "_"
            {
                var name = ""
                var next = index + 1
                while next < characters.count, characters[next].isLetter || characters[next].isNumber || characters[next] == "_" {
                    name.append(characters[next])
                    next += 1
                }
                return name
            }
            index += 1
        }
        return nil
    }
}
