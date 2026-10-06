import Foundation
import Ports

/// One entry per kind of event the panel can show (query events split by what they search for).
enum XrayEventTag: CaseIterable {
    case documentSaved, messageSaved, blobStored, blobRead, jobState, batchWritten, generationActivated, documentDeleted
    case vectorQuery, keywordQuery, keywordSkipped, otherQuery
    case queryRewritten, queryEmbedded, fusion, relevance, generation
}

extension TraceKind {
    var tag: XrayEventTag {
        switch self {
        case .documentSaved: .documentSaved
        case .messageSaved: .messageSaved
        case .blobStored: .blobStored
        case .blobRead: .blobRead
        case .jobState: .jobState
        case .batchWritten: .batchWritten
        case .generationActivated: .generationActivated
        case .documentDeleted: .documentDeleted
        case .query(let trace):
            switch trace.purpose {
            case .vector: .vectorQuery
            case .keyword: .keywordQuery
            case .other: .otherQuery
            }
        case .keywordSearchSkipped: .keywordSkipped
        case .queryRewritten: .queryRewritten
        case .queryEmbedded: .queryEmbedded
        case .fusion: .fusion
        case .relevance: .relevance
        case .generation: .generation
        }
    }
}

/// The words in the panel: a one-line summary of each event, and the "Why it matters" captions.
enum XrayText {
    /// One plain-language sentence per event kind saying what it shows about Couchbase Lite.
    static func caption(for tag: XrayEventTag) -> String {
        switch tag {
        case .documentSaved:
            "Documents are plain JSON records saved with one call, so there is no schema to migrate."
        case .messageSaved:
            "Chat history lives in the same database as the documents, so one store holds everything the app needs."
        case .blobStored:
            "The original file is stored inside the database next to its record, so it is kept and deleted together with it."
        case .blobRead:
            "Files stream out of the database on demand, so the app keeps no separate file store that could drift out of step."
        case .jobState:
            "Indexing progress sits in a collection that is local to this device and never replicated, so turning on sync later sends nothing about it."
        case .batchWritten:
            "Many passages and their vectors go in as one atomic transaction, all of it or none of it, even if the app is killed."
        case .generationActivated:
            "One transaction makes the new passages searchable and removes the old ones, so a search never sees a half-built index."
        case .documentDeleted:
            "Deleting a document removes its record, its file and its passages in one transaction, leaving nothing behind."
        case .vectorQuery:
            "Vector search runs inside the same embedded database as the documents, with no network and no separate vector store, and the index is queried unfiltered for speed while visibility is decided from the passage ID (document, generation, position) so a re-index in progress is never seen."
        case .keywordQuery:
            "Full-text search uses the same SQL++ as every other query and runs offline in the same engine as the vector search, which is what makes exact codes like E-042 findable."
        case .keywordSkipped:
            "A question with no searchable words skips the keyword query and relies on meaning-based search alone."
        case .otherQuery:
            "Plain SQL++ over JSON documents runs on the device with no network and no server."
        case .queryRewritten:
            "A follow-up question is rewritten on the device into a standalone search query, so search works the same inside a conversation."
        case .queryEmbedded:
            "The question becomes a vector on the device, in the same representation stored in Couchbase Lite, so no text leaves the iPad."
        case .fusion:
            "Meaning-based and exact-keyword results are merged by rank, and having both search types in one database makes that a few lines of code."
        case .relevance:
            "A distance threshold keeps the app from answering with weak matches, so it says it found nothing instead of guessing."
        case .generation:
            "Only passages retrieved from the local database reach the language model, and the answer cites them, so nothing leaves the device."
        }
    }

    static func title(for kind: TraceKind) -> String {
        switch kind {
        case .documentSaved: "Saved the document record"
        case .messageSaved: "Saved a chat message"
        case .blobStored: "Stored the original file as a blob"
        case .blobRead(_, _, let cacheHit): cacheHit ? "Opened the original file (already on disk)" : "Read the original file from the blob"
        case .jobState(_, let state, _, _): "Indexing job: \(state)"
        case .batchWritten(_, let count, _): "Wrote \(count) passage\(count == 1 ? "" : "s") in one transaction"
        case .generationActivated(_, let generation, _): "Made passage set \(generation) searchable"
        case .documentDeleted: "Deleted the document"
        case .query(let trace):
            switch trace.purpose {
            case .vector: "Vector search"
            case .keyword: "Keyword search"
            case .other: "SQL++ query"
            }
        case .keywordSearchSkipped: "Keyword search skipped"
        case .queryRewritten: "Rewrote the follow-up as a standalone query"
        case .queryEmbedded: "Embedded the question"
        case .fusion: "Merged the vector and keyword results"
        case .relevance(_, _, let outcome): outcome == .failed ? "Relevance check: not relevant" : "Relevance check: relevant"
        case .generation(_, let skipped): skipped ? "Language model not called" : "Language model answered"
        }
    }

    /// The second line of an event row.
    static func detail(for kind: TraceKind) -> String? {
        switch kind {
        case .documentSaved(let collection, let id): "\(collection)/\(id)"
        case .messageSaved(let id): "messages/\(id)"
        case .blobStored(_, let contentType, let length): "\(contentType) · \(XrayFormat.bytes(length))"
        case .blobRead(_, let length, _): XrayFormat.bytes(length)
        case .jobState(_, _, let progress, let localOnly):
            "\(Int((progress * 100).rounded()))%" + (localOnly ? " · saved in ingestJobs, a device-local collection" : "")
        case .batchWritten(let collection, _, let dimensions): "\(collection) · \(dimensions)-dimension vectors"
        case .generationActivated(_, _, let removed):
            removed == 0 ? "nothing to remove" : "removed \(removed) older passage\(removed == 1 ? "" : "s") in the same transaction"
        case .documentDeleted(_, let removed): "\(removed) passage\(removed == 1 ? "" : "s") removed in the same transaction"
        case .query(let trace):
            if let attempt = trace.attempts.last {
                "returned \(trace.returnedRows) · usable \(attempt.kept)"
            } else {
                "returned \(trace.returnedRows) row\(trace.returnedRows == 1 ? "" : "s")"
            }
        case .keywordSearchSkipped: "the question has no searchable words"
        case .queryRewritten(let original, let standalone): "“\(original)” → “\(standalone)”"
        case .queryEmbedded(let dimensions): "\(dimensions)-dimension vector"
        case .fusion(let method, let k, let entries): "\(entries.count) passage\(entries.count == 1 ? "" : "s") · \(method), k=\(Int(k))"
        case .relevance(let best, let threshold, let outcome): relevance(best: best, threshold: threshold, outcome: outcome)
        case .generation(let firstToken, let skipped):
            skipped ? "the question was not relevant, so no answer was generated"
                : firstToken.map { "first text after \(XrayFormat.duration($0))" }
        }
    }

    static func relevance(best: Double?, threshold: Double, outcome: RelevanceOutcome) -> String {
        let limit = String(format: "%.2f", threshold)
        guard let best else { return "no comparable passages in the library" }
        let distance = String(format: "%.3f", best)
        switch outcome {
        case .passedOnDistance: return "best distance \(distance) ≤ threshold \(limit)"
        case .passedOnIdentifier(let code):
            return "best distance \(distance) > threshold \(limit), but “\(code)” appears word for word in a top passage"
        case .failed: return "best distance \(distance) > threshold \(limit)"
        }
    }

    /// One line per pass over the index: how many rows came back, how many were visible, how many were used.
    static func funnel(_ attempt: FunnelAttempt, number: Int, of total: Int) -> String {
        var line = total > 1 ? "Attempt \(number) of \(total): " : ""
        line += "asked for \(attempt.window) → index returned \(attempt.returned) → \(attempt.visible) visible, \(attempt.notVisible) hidden → \(attempt.kept) usable"
        if attempt.wrongModel > 0 { line += " (\(attempt.wrongModel) embedded by another model)" }
        if attempt.notExamined > 0 { line += "; stopped once enough were found, \(attempt.notExamined) not examined" }
        return line
    }

    static func symbol(for tag: XrayEventTag) -> String {
        switch tag {
        case .documentSaved, .messageSaved: "doc.text"
        case .blobStored, .blobRead: "paperclip"
        case .jobState: "gearshape"
        case .batchWritten, .generationActivated: "square.stack.3d.up"
        case .documentDeleted: "trash"
        case .vectorQuery: "point.3.connected.trianglepath.dotted"
        case .keywordQuery, .keywordSkipped: "text.magnifyingglass"
        case .otherQuery: "tablecells"
        case .queryRewritten: "arrow.triangle.2.circlepath"
        case .queryEmbedded: "number"
        case .fusion: "arrow.triangle.merge"
        case .relevance: "checkmark.seal"
        case .generation: "sparkles"
        }
    }
}

enum XrayFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 0.001 { return String(format: "%.0f µs", seconds * 1_000_000) }
        if seconds < 1 { return String(format: seconds < 0.01 ? "%.1f ms" : "%.0f ms", seconds * 1000) }
        return String(format: "%.1f s", seconds)
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}
