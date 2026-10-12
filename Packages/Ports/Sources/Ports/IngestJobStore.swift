/// Device-local queue of ingestion work. It survives relaunches so interrupted jobs can resume.
public protocol IngestJobStore: Sendable {
    func upsert(job: IngestJobRecord) async throws
    func job(docId: String) async throws -> IngestJobRecord?
    /// All jobs, oldest first.
    func jobs() async throws -> [IngestJobRecord]
    func deleteJob(docId: String) async throws
}
