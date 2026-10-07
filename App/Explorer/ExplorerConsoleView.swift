import Ports
import SwiftUI

/// The SQL++ console: an editor, starter queries, and the rows a query returned.
struct ConsoleView: View {
    @Bindable var explorer: ExplorerModel

    var body: some View {
        @Bindable var console = explorer.console
        VStack(spacing: 0) {
            TextEditor(text: $console.sql)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(minHeight: 130, maxHeight: 230)
                .padding(.horizontal, 8)
                .accessibilityIdentifier("consoleEditor")
            controls(console)
            Divider()
            results(console)
        }
        .navigationTitle("Query")
    }

    private func controls(_ console: ExplorerConsole) -> some View {
        HStack(spacing: 12) {
            Menu("Starters", systemImage: "text.badge.plus") {
                ForEach(explorer.starters) { starter in
                    Button(starter.title) { console.use(starter) }
                }
            }
            .accessibilityIdentifier("consoleStarters")
            Button("Plan", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                Task { await explorer.showPlan() }
            }
            .disabled(console.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("consolePlan")
            Spacer()
            if console.state == .running {
                ProgressView()
                Button("Cancel", systemImage: "xmark.circle") { console.cancel() }
                    .accessibilityIdentifier("consoleCancel")
            } else {
                Button("Run", systemImage: "play.fill") { Task { await console.run() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(console.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("consoleRun")
            }
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private func results(_ console: ExplorerConsole) -> some View {
        VStack(spacing: 0) {
            if console.databaseStillBusy {
                Label("A cancelled query is still running in the database.", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.orange).padding(8)
                    .accessibilityIdentifier("consoleBusy")
            }
            switch console.state {
            case .idle:
                ContentUnavailableView(
                    "Run a query", systemImage: "terminal",
                    description: Text("Type a SELECT, or pick a starter. Parameters are not supported."))
            case .running:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ScrollView {
                    Text(message)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .accessibilityIdentifier("consoleError")
                }
            case .finished(let rows):
                List {
                    Section {
                        ForEach(Array(rows.rows.enumerated()), id: \.offset) { index, row in
                            Button { explorer.showRow(index) } label: {
                                Text(Self.oneLine(row)).font(.system(.caption, design: .monospaced)).lineLimit(3)
                            }
                            .accessibilityIdentifier("consoleRow-\(index)")
                        }
                    } header: {
                        summary(rows)
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("consoleResults")
            }
        }
    }

    private func summary(_ rows: QueryRows) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(rows.rows.count) \(rows.rows.count == 1 ? "row" : "rows") · \(Self.milliseconds(rows.duration))")
                .accessibilityIdentifier("consoleSummary")
            if rows.truncated {
                Text("Showing the first \(ExplorerConsole.rowLimit) rows; the query returned more.")
                    .foregroundStyle(.orange).accessibilityIdentifier("consoleTruncated")
            }
        }
        .font(.caption)
        .textCase(nil)
    }

    static func milliseconds(_ duration: Duration) -> String {
        let value = duration.seconds * 1000
        return value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
    }

    /// A pretty-printed row on a few lines of a list.
    static func oneLine(_ row: String) -> String {
        row.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }
}

/// One result row in full.
struct ResultRowView: View {
    let console: ExplorerConsole
    let row: Int

    var body: some View {
        if case .finished(let rows) = console.state, rows.rows.indices.contains(row) {
            ScrollView {
                Text(rows.rows[row])
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityIdentifier("consoleRowDetail")
            }
            .navigationTitle("Row \(row + 1)")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Run the query again to see this row", systemImage: "terminal")
        }
    }
}

/// The plan the database reports for the query in the editor, with the index it names.
struct PlanView: View {
    let console: ExplorerConsole

    var body: some View {
        Group {
            switch console.plan {
            case .none, .loading:
                ProgressView()
            case .failed(let message):
                ContentUnavailableView("No plan", systemImage: "exclamationmark.triangle", description: Text(message))
                    .accessibilityIdentifier("consolePlanError")
            case .ready(let plan):
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(XrayModel.indexLabel(inPlan: plan)).font(.headline).accessibilityIdentifier("consolePlanIndex")
                        Text(plan)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("consolePlanText")
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Query plan")
        .navigationBarTitleDisplayMode(.inline)
    }
}
