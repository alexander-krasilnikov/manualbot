// Maintains the manual catalog: the curated list of public PDFs the app offers. Run from the repository root:
//   swift scripts/manual-catalog.swift check     verify every entry against the live web; changes nothing
//   swift scripts/manual-catalog.swift refresh   re-measure the entries that still qualify and update their records
//   swift scripts/manual-catalog.swift rebuild   replace dead entries from the alternates and regenerate App/Resources/ManualCatalog.json
// Options: --source <file> --output <file> --selected (skip alternates) --only <id,id> --offline (rebuild only)
//          --retries <n> --retry-pause <seconds> --spacing <seconds> --parallel <hosts at a time>
// The source is scripts/manual-catalog/curated.json; see docs/manual-catalog.md.
import CryptoKit
import Foundation
import PDFKit

// MARK: - Rules and records

enum Config {
    static let maxBytes = 20 * 1024 * 1024
    static let userAgent = "ManualBot-CatalogCheck/1.0 (maintenance script; verifies public manual links)"
    /// Display order of the catalog.
    static let categories = [
        "Automotive", "Motorcycle", "Ships", "Yachts", "Manufacturing", "Wind turbines", "Field service", "Military", "Couchbase",
    ]
    static let kinds: Set<String> = ["manual", "catalog", "whitepaper"]
    static let defaultSource = "scripts/manual-catalog/curated.json"
    static let defaultOutput = "App/Resources/ManualCatalog.json"
    /// How many pages of a military document are read for its distribution statement.
    static let statementPages = 6
}

struct Entry: Codable, Sendable {
    var id: String
    var selected: Bool
    var category: String
    var kind: String
    var title: String
    var publisher: String
    var language: String
    var url: String
    var bytes: Int
    /// Missing in the seed for a few entries; refresh fills it in.
    var pages: Int?
    var sha256: String?
    var licenceNote: String
    var verifiedAt: String
    /// The title inside the PDF, as last measured. `title` stays the curated name.
    var pdfTitle: String?
    /// Set when the document is also a bundled sample, so the two are one document in the library.
    var documentId: String?
    var notes: String?
    /// Why an entry is an alternate rather than selected.
    var reason: String?
}

struct Rejection: Codable, Sendable {
    var category: String
    var title: String
    var url: String
    var reason: String
    var bytes: Int?
    var rejectedAt: String
}

struct Source: Codable, Sendable {
    var version: Int
    var entries: [Entry]
    var rejected: [Rejection]
}

/// One entry of the bundled catalog: what the app needs, none of the maintainers' notes.
struct CatalogEntry: Codable, Sendable {
    var id: String
    var category: String
    var kind: String
    var title: String
    var publisher: String
    var language: String
    var url: String
    var bytes: Int
    var pages: Int
    var sha256: String
    var licenceNote: String
    var verifiedAt: String
    var documentId: String?
}

struct Catalog: Codable, Sendable {
    var version: Int
    var entries: [CatalogEntry]
}

enum Verdict: String, Sendable {
    case ok, changed
    case tooLarge = "too large"
    case notPDF = "not a PDF"
    /// A military document without a public-release statement, or with a restriction.
    case restricted
    case blocked, gone, unreachable

    var qualifies: Bool { self == .ok || self == .changed }
}

struct Measured: Sendable {
    var bytes: Int
    var sha256: String
    var pages: Int
    var pdfTitle: String?
}

struct Outcome: Sendable {
    var verdict: Verdict
    var detail: String
    var measured: Measured?
}

struct Options: Sendable {
    var command = ""
    var source = Config.defaultSource
    var output = Config.defaultOutput
    var selectedOnly = false
    var only: Set<String> = []
    var offline = false
    var retries = 3
    var retryPause: TimeInterval = 5
    var spacing: TimeInterval = 1
    var parallel = 8
}

// MARK: - Output helpers

func say(_ text: String = "") { print(text) }
func note(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

func fail(_ text: String) -> Never {
    note("error: \(text)")
    exit(2)
}

func size(_ bytes: Int) -> String { String(format: "%.1f MiB", Double(bytes) / 1_048_576) }
func pad(_ text: String, _ width: Int) -> String { text.count >= width ? text : text + String(repeating: " ", count: width - text.count) }
func padLeft(_ text: String, _ width: Int) -> String { text.count >= width ? text : String(repeating: " ", count: width - text.count) + text }

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var rest = arguments.dropFirst()
    guard let command = rest.popFirst(), ["check", "refresh", "rebuild"].contains(command) else {
        fail("usage: swift scripts/manual-catalog.swift check|refresh|rebuild [options] (see the header of the script)")
    }
    options.command = command
    func value(_ name: String) -> String {
        guard let next = rest.popFirst() else { fail("\(name) needs a value") }
        return next
    }
    while let argument = rest.popFirst() {
        switch argument {
        case "--source": options.source = value(argument)
        case "--output": options.output = value(argument)
        case "--selected": options.selectedOnly = true
        case "--offline": options.offline = true
        case "--only": options.only = Set(value(argument).split(separator: ",").map(String.init))
        case "--retries": options.retries = Int(value(argument)) ?? 3
        case "--retry-pause": options.retryPause = TimeInterval(value(argument)) ?? 5
        case "--spacing": options.spacing = TimeInterval(value(argument)) ?? 1
        case "--parallel": options.parallel = max(1, Int(value(argument)) ?? 8)
        default: fail("unknown option \(argument)")
        }
    }
    if options.offline && options.command != "rebuild" { fail("--offline applies to rebuild only") }
    return options
}

// MARK: - Source file

func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
}

func load(_ path: String) -> Source {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    do { return try JSONDecoder().decode(Source.self, from: data) } catch { fail("cannot decode \(path): \(error)") }
}

func write<T: Encodable>(_ value: T, to path: String) {
    do {
        var data = try encoder().encode(value)
        data.append(0x0A)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch { fail("cannot write \(path): \(error)") }
}

func stamp() -> String { ISO8601DateFormatter().string(from: Date()) }

// MARK: - Fetching

struct Fetched: Sendable {
    var status = 0
    var finalURL: URL?
    var contentType = ""
    var body = Data()
    var tooLarge = false
    var insecureRedirect = false
    /// The host's firewall answered with a challenge (a captcha) instead of the file.
    var challenged = false
    var retryAfter: TimeInterval?
    var error: String?
}

/// Streams one response, refusing a non-HTTPS redirect and stopping as soon as the body passes the limit.
final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var fetched = Fetched()
    private var continuation: CheckedContinuation<Fetched, Never>?

    func run(_ request: URLRequest, in session: URLSession) async -> Fetched {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if request.url?.scheme?.lowercased() == "https" {
            completionHandler(request)
        } else {
            lock.lock()
            fetched.insecureRedirect = true
            lock.unlock()
            task.cancel()
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else { return completionHandler(.cancel) }
        lock.lock()
        fetched.status = http.statusCode
        fetched.finalURL = http.url
        fetched.contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        fetched.challenged = ["captcha", "challenge"].contains(http.value(forHTTPHeaderField: "x-amzn-waf-action")?.lowercased() ?? "")
        fetched.retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        let declared = http.expectedContentLength
        let tooLarge = declared > Int64(Config.maxBytes)
        if tooLarge { fetched.tooLarge = true }
        lock.unlock()
        completionHandler(tooLarge ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        fetched.body.append(data)
        let over = fetched.body.count > Config.maxBytes
        if over {
            fetched.tooLarge = true
            fetched.body = Data()
        }
        lock.unlock()
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if let error, !fetched.tooLarge, !fetched.insecureRedirect { fetched.error = error.localizedDescription }
        let result = fetched
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

func fetch(_ url: URL) async -> Fetched {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 300
    configuration.httpAdditionalHeaders = ["User-Agent": Config.userAgent]
    let collector = Collector()
    let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: url)
    request.setValue("application/pdf, */*;q=0.5", forHTTPHeaderField: "Accept")
    return await collector.run(request, in: session)
}

// MARK: - Reading the PDF

/// PDFKit is not documented as safe for parallel use, so reading is serialized.
let pdfLock = NSLock()

struct Reading {
    var pages: Int
    var title: String?
    var statement: String?
}

func read(_ body: Data, wantsStatement: Bool) -> Reading? {
    pdfLock.lock()
    defer { pdfLock.unlock() }
    guard let document = PDFDocument(data: body), document.pageCount > 0 else { return nil }
    var title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if title?.isEmpty == true { title = nil }
    var statement: String?
    if wantsStatement {
        var text = ""
        for index in 0..<min(Config.statementPages, document.pageCount) { text += " " + (document.page(at: index)?.string ?? "") }
        statement = distribution(of: text)
    }
    return Reading(pages: document.pageCount, title: title, statement: statement)
}

/// nil when the text carries a public-release statement and no restriction; otherwise what is wrong.
func distribution(of text: String) -> String? {
    let words = text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    let restrictions = [
        #"distribution statement:? ?[b-f]\b"#, #"export[- ]control"#, #"arms export control"#, #"international traffic in arms"#,
        #"export administration (act|regulations)"#, #"distribution (authorized|limited) to"#, #"distribution is limited"#,
        #"for official use only"#, #"controlled unclassified"#, #"\bfouo\b"#,
    ]
    for pattern in restrictions {
        if let range = words.range(of: pattern, options: .regularExpression) { return "carries a restriction (\"\(words[range])\")" }
    }
    let releases = [
        #"distribution statement:? ?a\b"#, #"approved for public release"#, #"distribution (is )?unlimited"#, #"unlimited distribution"#,
        #"\bdistribution a\b"#,
    ]
    for pattern in releases where words.range(of: pattern, options: .regularExpression) != nil { return nil }
    return words.count < 40 ? "has no text layer to read a distribution statement from" : "has no public-release statement"
}

// MARK: - Checking one entry

func classify(_ entry: Entry, _ fetched: Fetched) -> (outcome: Outcome, transient: Bool) {
    func result(_ verdict: Verdict, _ detail: String, transient: Bool = false) -> (Outcome, Bool) {
        (Outcome(verdict: verdict, detail: detail, measured: nil), transient)
    }
    if fetched.insecureRedirect { return result(.gone, "redirects to an address that is not HTTPS") }
    if fetched.tooLarge { return result(.tooLarge, "more than \(size(Config.maxBytes))") }
    if let error = fetched.error { return result(.unreachable, error, transient: true) }
    if let final = fetched.finalURL, final.scheme?.lowercased() != "https" { return result(.gone, "final address is not HTTPS") }
    switch fetched.status {
    case _ where fetched.challenged:
        return result(.blocked, "HTTP \(fetched.status): the host's firewall asks for a captcha")
    case 200...299: break
    case 401, 403: return result(.blocked, "HTTP \(fetched.status): the host refuses automatic downloads")
    case 404, 410: return result(.gone, "HTTP \(fetched.status)")
    case 408, 429, 500...599: return result(.unreachable, "HTTP \(fetched.status)", transient: true)
    case 400...499: return result(.gone, "HTTP \(fetched.status)")
    default: return result(.unreachable, "HTTP \(fetched.status)", transient: true)
    }
    let signature = Data("%PDF-".utf8)
    guard fetched.body.starts(with: signature) else {
        let head = String(decoding: fetched.body.prefix(512), as: UTF8.self).lowercased()
        let isPage = fetched.contentType.lowercased().contains("html") || head.contains("<html") || head.contains("<!doctype")
        return isPage ? result(.gone, "the address now returns a web page, not a PDF") : result(.notPDF, "content is \(fetched.contentType.isEmpty ? "not a PDF" : fetched.contentType)")
    }
    guard let reading = read(fetched.body, wantsStatement: entry.category == "Military") else {
        return result(.notPDF, "starts like a PDF but cannot be read")
    }
    if let problem = reading.statement { return result(.restricted, problem) }
    let digest = SHA256.hash(data: fetched.body).map { String(format: "%02x", $0) }.joined()
    let measured = Measured(bytes: fetched.body.count, sha256: digest, pages: reading.pages, pdfTitle: reading.title)
    var detail = "\(size(measured.bytes)), \(reading.pages) pages"
    var verdict = Verdict.ok
    if measured.bytes != entry.bytes {
        verdict = .changed
        detail = "size \(entry.bytes) -> \(measured.bytes) bytes"
    } else if let recorded = entry.sha256, recorded != digest {
        verdict = .changed
        detail = "same size, different checksum"
    }
    return (Outcome(verdict: verdict, detail: detail, measured: measured), false)
}

/// Retries a transient failure with a pause before giving up.
func measure(_ entry: Entry, _ options: Options) async -> Outcome {
    guard let url = URL(string: entry.url), url.scheme?.lowercased() == "https" else {
        return Outcome(verdict: .gone, detail: "the address is not HTTPS", measured: nil)
    }
    var attempt = 0
    while true {
        let fetched = await fetch(url)
        let (outcome, transient) = classify(entry, fetched)
        guard transient, attempt < options.retries else {
            if transient { return Outcome(verdict: outcome.verdict, detail: "\(outcome.detail) after \(attempt + 1) tries", measured: nil) }
            return outcome
        }
        attempt += 1
        let pause = min(fetched.retryAfter ?? options.retryPause * Double(attempt), 60)
        try? await Task.sleep(for: .seconds(pause))
    }
}

actor Progress {
    private var done = 0
    private let total: Int
    init(total: Int) { self.total = total }
    func finished(_ entry: Entry, _ outcome: Outcome) {
        done += 1
        note("[\(done)/\(total)] \(outcome.verdict.rawValue.uppercased()) \(entry.id)")
    }
}

/// Checks the entries host by host: one request at a time to a host with a pause between them, several hosts together.
func runChecks(_ entries: [Entry], _ options: Options) async -> [String: Outcome] {
    let byHost = Dictionary(grouping: entries) { URL(string: $0.url)?.host ?? "" }
    let hosts = byHost.keys.sorted { (byHost[$0]!.count, $1) > (byHost[$1]!.count, $0) }
    let progress = Progress(total: entries.count)
    var results: [String: Outcome] = [:]
    await withTaskGroup(of: [(String, Outcome)].self) { group in
        var pending = hosts[...]
        func start() {
            guard let host = pending.popFirst(), let list = byHost[host] else { return }
            group.addTask {
                var done: [(String, Outcome)] = []
                for (index, entry) in list.enumerated() {
                    if index > 0 { try? await Task.sleep(for: .seconds(options.spacing)) }
                    let outcome = await measure(entry, options)
                    await progress.finished(entry, outcome)
                    done.append((entry.id, outcome))
                }
                return done
            }
        }
        for _ in 0..<options.parallel { start() }
        while let finished = await group.next() {
            for (id, outcome) in finished { results[id] = outcome }
            start()
        }
    }
    return results
}

// MARK: - Reporting

struct Tally {
    var ok = 0, changed = 0, replaced = 0, attention = 0, alternates = 0, alternateIssues = 0
}

func tally(_ entries: [Entry], _ outcomes: [String: Outcome], replaced: Set<String> = []) -> [String: Tally] {
    var table: [String: Tally] = [:]
    for entry in entries {
        guard let outcome = outcomes[entry.id] else { continue }
        var row = table[entry.category] ?? Tally()
        if entry.selected {
            if replaced.contains(entry.id) { row.replaced += 1 }
            else if outcome.verdict == .ok { row.ok += 1 }
            else if outcome.verdict == .changed { row.changed += 1 }
            else { row.attention += 1 }
        } else {
            row.alternates += 1
            if !outcome.verdict.qualifies { row.alternateIssues += 1 }
        }
        table[entry.category] = row
    }
    return table
}

func printEntries(_ entries: [Entry], _ outcomes: [String: Outcome]) {
    for category in Config.categories {
        let rows = entries.filter { $0.category == category && outcomes[$0.id] != nil }
        guard !rows.isEmpty else { continue }
        say("\n\(category)")
        for entry in rows.sorted(by: { ($0.selected ? 0 : 1, $0.title) < ($1.selected ? 0 : 1, $1.title) }) {
            let outcome = outcomes[entry.id]!
            let mark = entry.selected ? " " : "alt"
            say("  \(pad(outcome.verdict.rawValue, 12)) \(pad(mark, 3)) \(entry.id.prefix(48))  \(outcome.detail)")
        }
    }
}

func printTable(_ table: [String: Tally]) {
    // Only the commands that look at the alternates have anything to say about them.
    let showAlternates = table.values.contains { $0.alternates > 0 }
    func line(_ name: String, _ row: Tally) -> String {
        let counts = "\(pad(name, 16)) \(padLeft(String(row.ok), 4)) \(padLeft(String(row.changed), 8)) \(padLeft(String(row.replaced), 9)) \(padLeft(String(row.attention), 10))"
        return showAlternates ? "\(counts)   \(row.alternates) (\(row.alternateIssues))" : counts
    }
    say("\n\(pad("Category", 16)) \(padLeft("ok", 4)) \(padLeft("changed", 8)) \(padLeft("replaced", 9)) \(padLeft("attention", 10))" + (showAlternates ? "   alternates (issues)" : ""))
    var total = Tally()
    for category in Config.categories {
        guard let row = table[category] else { continue }
        say(line(category, row))
        total.ok += row.ok; total.changed += row.changed; total.replaced += row.replaced; total.attention += row.attention
        total.alternates += row.alternates; total.alternateIssues += row.alternateIssues
    }
    say(line("Total", total))
}

func attention(_ table: [String: Tally]) -> Int { table.values.reduce(0) { $0 + $1.attention } }

func finish(_ table: [String: Tally], hint: String? = nil) -> Never {
    let count = attention(table)
    let changed = table.values.reduce(0) { $0 + $1.changed }
    say("\n\(count) need attention")
    if changed > 0, let hint { say("\(changed) changed since they were recorded; \(hint)") }
    exit(count > 0 ? 1 : 0)
}

// MARK: - Commands

func selection(_ source: Source, _ options: Options) -> [Entry] {
    var entries = source.entries
    if options.selectedOnly { entries = entries.filter(\.selected) }
    if !options.only.isEmpty { entries = entries.filter { options.only.contains($0.id) } }
    if entries.isEmpty { fail("no entries to check") }
    return entries
}

func check(_ options: Options) async -> Never {
    let source = load(options.source)
    let entries = selection(source, options)
    let outcomes = await runChecks(entries, options)
    printEntries(entries, outcomes)
    let table = tally(entries, outcomes)
    printTable(table)
    finish(table, hint: "run refresh to record the new details")
}

func refresh(_ options: Options) async -> Never {
    var source = load(options.source)
    let entries = selection(source, options)
    let outcomes = await runChecks(entries, options)
    var updated = 0
    let now = stamp()
    for index in source.entries.indices {
        let entry = source.entries[index]
        guard let outcome = outcomes[entry.id], outcome.verdict.qualifies, let measured = outcome.measured else { continue }
        source.entries[index].bytes = measured.bytes
        source.entries[index].pages = measured.pages
        source.entries[index].sha256 = measured.sha256
        source.entries[index].pdfTitle = measured.pdfTitle
        source.entries[index].verifiedAt = now
        updated += 1
    }
    write(source, to: options.source)
    printEntries(entries, outcomes)
    var table = tally(entries, outcomes)
    // A refreshed record is up to date, so changed entries count as ok afterwards.
    for key in table.keys { table[key]!.ok += table[key]!.changed; table[key]!.changed = 0 }
    printTable(table)
    say("\n\(updated) records updated in \(options.source); entries that no longer qualify were left as they were")
    finish(table)
}

func validate(_ entries: [CatalogEntry]) -> [String] {
    var problems: [String] = []
    var ids: Set<String> = [], urls: Set<String> = []
    for entry in entries {
        if !ids.insert(entry.id).inserted { problems.append("duplicate id \(entry.id)") }
        if !urls.insert(entry.url).inserted { problems.append("duplicate address \(entry.url)") }
        if URL(string: entry.url)?.scheme?.lowercased() != "https" { problems.append("\(entry.id): address is not HTTPS") }
        if entry.bytes <= 0 || entry.bytes > Config.maxBytes { problems.append("\(entry.id): \(entry.bytes) bytes is outside 1...\(Config.maxBytes)") }
        if entry.pages <= 0 { problems.append("\(entry.id): no page count recorded (run refresh)") }
        if entry.sha256.count != 64 { problems.append("\(entry.id): no checksum recorded (run refresh)") }
        if !Config.kinds.contains(entry.kind) { problems.append("\(entry.id): unknown kind \(entry.kind)") }
        if !Config.categories.contains(entry.category) { problems.append("\(entry.id): unknown category \(entry.category)") }
    }
    for category in Config.categories where !entries.contains(where: { $0.category == category }) {
        problems.append("no entry in category \(category)")
    }
    return problems
}

func rebuild(_ options: Options) async -> Never {
    var source = load(options.source)
    let selected = source.entries.filter(\.selected)
    var outcomes: [String: Outcome] = [:]
    if !options.offline { outcomes = await runChecks(selected, options) }

    var replaced: [(dead: String, with: String)] = []
    var dropped: [String] = []
    let now = stamp()
    let day = String(now.prefix(10))
    for entry in selected {
        guard let outcome = outcomes[entry.id], !outcome.verdict.qualifies,
            let slot = source.entries.firstIndex(where: { $0.id == entry.id })
        else { continue }
        source.entries[slot].selected = false
        var replacement: Int?
        let candidates = source.entries.indices.filter {
            let other = source.entries[$0]
            return !other.selected && other.category == entry.category && other.kind == entry.kind && other.id != entry.id
                && !(other.reason ?? "").hasPrefix("Retired")
        }
        for index in candidates {
            let other = source.entries[index]
            note("trying alternate \(other.id) for \(entry.id)")
            let result = await measure(other, options)
            if result.verdict.qualifies, let measured = result.measured {
                source.entries[index].selected = true
                source.entries[index].reason = nil
                source.entries[index].bytes = measured.bytes
                source.entries[index].pages = measured.pages
                source.entries[index].sha256 = measured.sha256
                source.entries[index].pdfTitle = measured.pdfTitle
                source.entries[index].verifiedAt = now
                replacement = index
                break
            }
            try? await Task.sleep(for: .seconds(options.spacing))
        }
        let why = "\(outcome.verdict.rawValue): \(outcome.detail)"
        if let replacement {
            source.entries[slot].reason = "Retired \(day), \(why); replaced by \(source.entries[replacement].id)"
            replaced.append((entry.id, source.entries[replacement].id))
        } else {
            source.entries[slot].reason = "Retired \(day), \(why); no alternate qualified"
            dropped.append(entry.id)
        }
    }

    var chosen = source.entries.filter(\.selected).map { entry in
        CatalogEntry(
            id: entry.id, category: entry.category, kind: entry.kind, title: entry.title, publisher: entry.publisher,
            language: entry.language, url: entry.url, bytes: entry.bytes, pages: entry.pages ?? 0, sha256: entry.sha256 ?? "",
            licenceNote: entry.licenceNote, verifiedAt: entry.verifiedAt, documentId: entry.documentId)
    }
    let rank = { (category: String) in Config.categories.firstIndex(of: category) ?? Int.max }
    chosen.sort { a, b in
        (rank(a.category), a.title.lowercased(), a.id) < (rank(b.category), b.title.lowercased(), b.id)
    }

    let before = (FileManager.default.contents(atPath: options.output)).flatMap { try? JSONDecoder().decode(Catalog.self, from: $0) }?.entries.count
    for (dead, with) in replaced { say("replaced \(dead) with \(with)") }
    for id in dropped {
        let category = selected.first { $0.id == id }?.category ?? ""
        say("no alternate for \(id): \(category) is now one entry short")
    }
    let problems = validate(chosen)
    if !problems.isEmpty {
        say("\nvalidation failed; nothing was written")
        for problem in problems { say("  \(problem)") }
        exit(1)
    }

    var table: [String: Tally] = [:]
    for entry in selected {
        var row = table[entry.category] ?? Tally()
        let verdict = outcomes[entry.id]?.verdict ?? .ok
        if replaced.contains(where: { $0.dead == entry.id }) { row.replaced += 1 }
        else if dropped.contains(entry.id) { row.attention += 1 }
        else if verdict == .changed { row.changed += 1 }
        else { row.ok += 1 }
        table[entry.category] = row
    }
    write(Catalog(version: 1, entries: chosen), to: options.output)
    if !replaced.isEmpty || !dropped.isEmpty { write(source, to: options.source) }
    printEntries(selected, outcomes)
    printTable(table)
    say("\n\(chosen.count) entries written to \(options.output) (previous catalog: \(before.map(String.init) ?? "none"))")
    finish(table, hint: "run refresh, then rebuild again")
}

let options = parse(CommandLine.arguments)
switch options.command {
case "check": await check(options)
case "refresh": await refresh(options)
default: await rebuild(options)
}
