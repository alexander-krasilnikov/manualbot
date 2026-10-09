import Ports
import SwiftUI

/// One event: what happened, when, how long it took, and (on tap) the details.
struct XrayEventRow: View {
    let event: TraceEvent
    let group: TraceGroup
    let xray: XrayModel
    @State private var open = false

    private var tag: XrayEventTag { event.kind.tag }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: XrayText.symbol(for: tag)).frame(width: 26).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(XrayText.title(for: event.kind)).font(.subheadline.weight(.semibold))
                        if let detail = XrayText.detail(for: event.kind) {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                        if case .query(let trace) = event.kind { IndexLabel(sql: trace.sql, xray: xray) }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(XrayFormat.time(event.timestamp)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        if let duration = event.duration {
                            Text(XrayFormat.duration(duration)).font(.caption.monospacedDigit().weight(.semibold))
                        }
                    }
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("xrayEvent-\(tag)")

            if xray.captions {
                Text(XrayText.caption(for: tag))
                    .font(.caption)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("xrayCaption-\(tag)")
            }
            if open { XrayEventDetail(event: event, group: group, xray: xray).padding(.leading, 36) }
        }
        .padding(.vertical, 10)
    }
}

/// "uses chunks_vec · vector index", shown as soon as the event appears.
private struct IndexLabel: View {
    let sql: String
    let xray: XrayModel

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(.tint)
            .task { await xray.loadPlan(for: sql) }
            .accessibilityIdentifier("xrayIndexLabel")
    }

    private var label: String {
        switch xray.plans[sql] {
        case .ready(let plan): XrayModel.indexLabel(inPlan: plan)
        case .failed: "query plan unavailable"
        case .loading, nil: "checking the query plan…"
        }
    }
}

// MARK: - Details

struct XrayEventDetail: View {
    let event: TraceEvent
    let group: TraceGroup
    let xray: XrayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch event.kind {
            case .query(let trace): QueryDetail(event: event, trace: trace, group: group, xray: xray)
            case .fusion(_, _, let entries): FusionDetail(entries: entries, xray: xray)
            case .relevance(let best, let threshold, let outcome, let bestImage, let imageThreshold):
                Text(XrayText.relevance(best: best, threshold: threshold, outcome: outcome, bestImage: bestImage, imageThreshold: imageThreshold))
                    .font(.callout)
            case .generation(let firstToken, let skipped):
                Text(skipped ? "No chunk was relevant, so the language model was never started." :
                        "First text after \(firstToken.map(XrayFormat.duration) ?? "–"); finished after \(event.duration.map(XrayFormat.duration) ?? "–").")
                    .font(.callout)
            case .keywordSearchSkipped:
                Text("The question has no words worth searching for, so only the meaning-based search ran.").font(.callout)
            case .queryRewritten(let original, let standalone):
                LabeledText("Asked", original)
                LabeledText("Searched for", standalone)
            case .queryEmbedded(let dimensions):
                Text("The question was turned into \(dimensions) numbers on the device.").font(.callout)
            case .documentSaved(let collection, let id): StoredDocumentLink(collection: collection, id: id, xray: xray)
            case .messageSaved(let id): StoredDocumentLink(collection: "messages", id: id, xray: xray)
            case .blobStored(let docId, _, _), .blobRead(let docId, _, _), .generationActivated(let docId, _, _, _),
                .documentDeleted(let docId, _, _):
                StoredDocumentLink(collection: "documents", id: docId, xray: xray)
            case .jobState(let docId, _, _, _): StoredDocumentLink(collection: "ingestJobs", id: docId, xray: xray)
            case .batchWritten(let collection, let count, let dimensions):
                Text("\(count) documents in “\(collection)”, each with a \(dimensions)-number vector, committed together.").font(.callout)
            case .imageAnalyzed(let docId, let generation, let n, let ocrLength, let captionSource, let dimensions):
                Text("Found \(ocrLength) characters of text on the photo; its caption came from \(XrayText.captionLabel(captionSource)); its look became \(dimensions) numbers.")
                    .font(.callout)
                StoredDocumentLink(collection: "images", id: ImageRecord.makeID(docId: docId, generation: generation, n: n), xray: xray)
            case .imagesWritten(let collection, let count, let blobBytes, let dimensions):
                Text("\(count) documents in “\(collection)”, each a JSON record with a \(dimensions)-number vector and the photo itself as a blob (\(XrayFormat.bytes(blobBytes)) in all), committed together.")
                    .font(.callout)
            case .wordsMatchedPhotos(let matches, let best, let threshold):
                Text(XrayText.wordsMatch(matches: matches, best: best, threshold: threshold)).font(.callout)
            case .photoAnalyzed(let length, let identifiers, let dimensions):
                LabeledText("Text read from the photo", length == 0 ? "none" : "\(length) characters")
                LabeledText("Identifiers kept for the search", identifiers.isEmpty ? "none" : identifiers.joined(separator: ", "))
                LabeledText("Look", "\(dimensions) numbers")
            case .modelRequest(let purpose, let host, let subject):
                LabeledText(purpose == .search ? "Searched for" : "Downloaded", subject)
                LabeledText("From", host)
                Text("Nothing about your documents, questions or answers is sent.").font(.callout)
            case .syncState(let state):
                Text("The replicator is now: \(state).").font(.callout)
            case .syncReplicated(let collection, let count, let push):
                LabeledText(push ? "Sent" : "Received", "\(count) in “\(collection)”")
                Text("Indexes are not part of this: each iPad builds its own vector and keyword indexes from the documents it holds.")
                    .font(.callout)
            case .syncRefused(let collection, let id, let reason):
                LabeledText("Record", "\(collection)/\(id)")
                LabeledText("Why", reason)
            case .syncDocumentSearchable(let docId, let title):
                LabeledText("Document", title)
                StoredDocumentLink(collection: "documents", id: docId, xray: xray)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LabeledText: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
    }
}

private struct QueryDetail: View {
    let event: TraceEvent
    let trace: QueryTrace
    let group: TraceGroup
    let xray: XrayModel
    @State private var showPlan = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(trace.sql)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("xraySQL")
            if !trace.parameters.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(trace.parameters.keys.sorted(), id: \.self) { name in
                        Text("$\(name) = \(trace.parameters[name] ?? "")")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            if !trace.attempts.isEmpty { funnel }
            Button(showPlan ? "Hide query plan" : "Show query plan") { showPlan.toggle() }
                .font(.caption)
                .accessibilityIdentifier("xrayPlanButton")
            if showPlan { plan }
        }
    }

    private var funnel: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(trace.attempts.enumerated()), id: \.offset) { _, attempt in
                Text(XrayText.funnel(attempt, number: attemptNumber, of: searchesOfThisKind.count))
                    .font(.caption)
                    .accessibilityIdentifier("xrayFunnel")
            }
            if let used = usedAfterFusion {
                Text("→ \(used) used after merging with the other search").font(.caption).accessibilityIdentifier("xrayFunnelUsed")
            }
        }
    }

    /// Every pass over the same index in this operation. A search that finds too few visible chunks widens its
    /// window and runs again, and each pass is its own event.
    private var searchesOfThisKind: [TraceEvent] {
        group.events.filter { other in
            if case .query(let candidate) = other.kind { candidate.purpose == trace.purpose && !candidate.attempts.isEmpty } else { false }
        }
    }

    private var attemptNumber: Int { (searchesOfThisKind.firstIndex { $0.id == event.id } ?? 0) + 1 }

    /// How many of this search's chunks made it into the merged list. Only the last pass produced the result.
    private var usedAfterFusion: Int? {
        guard trace.purpose != .other, searchesOfThisKind.last?.id == event.id else { return nil }
        for later in group.events where later.timestamp >= event.timestamp {
            if case .fusion(_, _, let entries) = later.kind {
                return entries.filter {
                    switch trace.purpose {
                    case .vector: $0.vectorPosition != nil
                    case .keyword: $0.keywordPosition != nil
                    case .image: $0.imagePosition != nil
                    case .imageByWords: $0.wordsPosition != nil
                    case .other: false
                    }
                }.count
            }
        }
        return nil
    }

    @ViewBuilder private var plan: some View {
        switch xray.plans[trace.sql] {
        case .ready(let text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("xrayPlanText")
        case .failed(let message): Text(message).font(.caption).foregroundStyle(.secondary)
        case .loading, nil: ProgressView()
        }
    }
}

private struct FusionDetail: View {
    let entries: [FusionEntry]
    let xray: XrayModel

    /// The photo column only appears when the question came with a photo.
    private var showsPhotoColumn: Bool { entries.contains { $0.imagePosition != nil } }
    /// The words column only appears when typed words matched a photo.
    private var showsWordsColumn: Bool { entries.contains { $0.wordsPosition != nil } }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text("Chunk").gridColumnAlignment(.leading).accessibilityIdentifier("xrayFusionTable")
                Text("Vector"); Text("Keyword")
                if showsPhotoColumn { Text("Photo") }
                if showsWordsColumn { Text("Words → photo") }
                Text("Distance"); Text("Score")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            ForEach(entries, id: \.chunkID) { entry in
                GridRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.documentTitle).font(.caption.weight(.medium))
                        StoredDocumentLink(collection: "chunks", id: entry.chunkID, xray: xray)
                    }
                    Text(entry.vectorPosition.map { "#\($0 + 1)" } ?? "–")
                    Text(entry.keywordPosition.map { "#\($0 + 1)" } ?? "–")
                    if showsPhotoColumn { Text(entry.imagePosition.map { "#\($0 + 1)" } ?? "–") }
                    if showsWordsColumn { Text(entry.wordsPosition.map { "#\($0 + 1)" } ?? "–") }
                    Text(entry.distance.map { String(format: "%.3f", $0) } ?? "–")
                    Text(String(format: "%.4f", entry.score))
                }
                .font(.caption.monospacedDigit())
            }
        }
    }
}

/// An ID that opens the stored JSON document behind it in the database explorer.
struct StoredDocumentLink: View {
    let collection: String
    let id: String
    let xray: XrayModel

    var body: some View {
        Button { xray.openInExplorer?(collection, id) } label: {
            Text("\(collection)/\(id)").font(.system(.caption2, design: .monospaced)).lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("xrayDocLink-\(id)")
    }
}
