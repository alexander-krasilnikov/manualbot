import Foundation
import Observation
import Ports
import SwiftUI

/// What the X-ray panel shows and how: the recorded log plus the presenter's display choices.
@MainActor @Observable
final class XrayModel {
    /// A query plan, fetched the first time its event is shown.
    enum PlanState: Equatable {
        case loading
        case ready(String)
        case failed(String)
    }

    private(set) var log = TraceLog()
    /// Show background activity (library refreshes and the like) among the groups.
    var showBackground = false
    var captions = false
    /// Groups the presenter opened or closed by hand; every other group follows the "latest is open" rule.
    private(set) var expansion: [String: Bool] = [:]
    private(set) var plans: [String: PlanState] = [:]
    /// Set once the database is open.
    var inspector: (any TraceInspector)?
    /// True when the language and embedding models are stand-ins, so distances mean nothing.
    var usesStubModels = false
    let network: NetworkMonitor
    /// Clears the library and chats and imports the samples. Set once the app's services exist.
    var resetAction: (() async -> Void)?
    /// Whether sync is on, so that the reset confirmation can say the documents go from every device that shares the library.
    var syncEnabled: () -> Bool = { false }
    private(set) var isResetting = false

    // MARK: Presenter aids

    /// Steps from small to very large. The default sits in the middle so the text can shrink as well as grow.
    static let textSizes: [DynamicTypeSize] = [
        .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge, .accessibility1, .accessibility2, .accessibility3,
    ]
    static let defaultTextSize = DynamicTypeSize.large
    /// Text size of the panel alone, independent of the rest of the app.
    private(set) var textSize = XrayModel.defaultTextSize
    /// Shows events that arrive together one at a time. Only the display is slowed, never the work itself.
    var slowReveal = false {
        didSet { if !slowReveal { flushPending() } }
    }
    private(set) var pendingCount = 0

    var canGrowText: Bool { textSize != Self.textSizes.last }
    var canShrinkText: Bool { textSize != Self.textSizes.first }

    func growText() { shiftText(by: 1) }
    func shrinkText() { shiftText(by: -1) }

    private func shiftText(by step: Int) {
        guard let index = Self.textSizes.firstIndex(of: textSize) else { return }
        textSize = Self.textSizes[min(max(index + step, 0), Self.textSizes.count - 1)]
    }

    @ObservationIgnored private let tracer: DemoTracer
    @ObservationIgnored private let revealInterval: Duration
    @ObservationIgnored private var pending: [TraceEvent] = []
    @ObservationIgnored private var releaser: Task<Void, Never>?
    @ObservationIgnored private var lastReveal: ContinuousClock.Instant?

    init(tracer: DemoTracer, revealInterval: Duration = .milliseconds(400), network: NetworkMonitor = NetworkMonitor()) {
        self.tracer = tracer
        self.revealInterval = revealInterval
        self.network = network
    }

    /// Follows the tracer for as long as the caller keeps this task alive.
    func run() async {
        for await event in tracer.events { receive(event) }
    }

    private func receive(_ event: TraceEvent) {
        // Once anything is waiting, everything queues behind it, so order is kept.
        guard slowReveal || !pending.isEmpty else { return log.append(event) }
        pending.append(event)
        pendingCount = pending.count
        if releaser == nil {
            releaser = Task { [weak self] in
                // Each event waits until one interval after the previous reveal, however its arrival was spread.
                while let self {
                    let wait = self.timeUntilNextReveal()
                    if wait > .zero { try? await Task.sleep(for: wait) }
                    guard !Task.isCancelled, self.revealNext() else { break }
                }
            }
        }
    }

    private func timeUntilNextReveal() -> Duration {
        guard let lastReveal else { return .zero }
        return max(.zero, ContinuousClock.now.duration(to: lastReveal + revealInterval))
    }

    /// Shows the oldest waiting event. Returns whether more are waiting.
    private func revealNext() -> Bool {
        if !pending.isEmpty {
            log.append(pending.removeFirst())
            pendingCount = pending.count
            lastReveal = .now
        }
        if pending.isEmpty { releaser = nil; return false }
        return true
    }

    private func flushPending() {
        let waiting = pending
        discardPending()
        for event in waiting { log.append(event) }
    }

    private func discardPending() {
        releaser?.cancel()
        releaser = nil
        pending = []
        pendingCount = 0
        lastReveal = nil
    }

    func resetDemo() async {
        guard let resetAction, !isResetting else { return }
        isResetting = true
        defer { isResetting = false }
        await resetAction()
    }

    func clear() {
        discardPending()
        log.clear()
        expansion = [:]
    }

    // MARK: Groups

    /// The groups to list, newest first.
    var visibleGroups: [TraceGroup] {
        log.groups.filter { showBackground || !$0.isBackground }.reversed()
    }

    func isExpanded(_ group: TraceGroup) -> Bool {
        expansion[group.id] ?? (group.id == log.latestID)
    }

    func setExpanded(_ group: TraceGroup, _ value: Bool) { expansion[group.id] = value }

    // MARK: Plans and stored documents

    /// Asks the database for the plan of `sql` once, and keeps the answer.
    func loadPlan(for sql: String) async {
        guard plans[sql] == nil, let inspector else { return }
        plans[sql] = .loading
        do {
            plans[sql] = .ready(try await inspector.plan(sql: sql))
        } catch {
            plans[sql] = .failed(error.localizedDescription)
        }
    }

    /// Opens the database explorer at a stored document. Set by the demo session.
    var openInExplorer: (@MainActor (_ collection: String, _ id: String) -> Void)?

    /// "uses chunks_vec · vector index", from the index names the app declares.
    static func indexLabel(inPlan plan: String) -> String {
        for index in knownIndexes where plan.contains(index.name) { return "uses \(index.name) · \(index.kind)" }
        return "no index · reads the whole collection"
    }

    static let knownIndexes: [(name: String, kind: String)] = [
        ("chunks_vec", "vector index"), ("chunks_fts", "full-text index"),
        ("chunks_doc_gen", "value index"), ("messages_chat", "value index"),
        ("images_vec", "vector index"), ("images_doc_gen", "value index"),
    ]
}
