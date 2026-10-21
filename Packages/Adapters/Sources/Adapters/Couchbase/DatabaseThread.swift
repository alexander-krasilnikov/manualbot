import Foundation

/// Runs all Couchbase Lite work on one thread that lives as long as the process.
///
/// The vector search extension bundles an OpenMP runtime that registers every thread it runs on and cleans up when
/// that thread exits; on a GCD worker thread that the system retires, that cleanup aborts the app
/// (`__kmp_internal_end_thread` → `__kmp_free`). A thread that never exits never runs it. The thread is shared by every
/// repository and is never stopped, because stopping it would run the same cleanup.
final class DatabaseThread: SerialExecutor, @unchecked Sendable {
    static let shared = DatabaseThread()

    private let queue: Queue
    private let thread: Thread

    private init() {
        let queue = Queue()
        self.queue = queue
        thread = Thread { queue.drain() }
        thread.name = "ManualBot database"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Whether the caller is running on the database thread.
    var isCurrent: Bool { Thread.current === thread }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.push { job.runSynchronously(on: executor) }
    }

    func checkIsolated() {
        precondition(isCurrent, "Expected to run on the database thread")
    }

    /// Runs `body` on the database thread and waits for it, for synchronous code that cannot hop to the actor
    /// (the repository's `init`). Must not be called on the database thread itself, which would wait for itself.
    func runAndWait<T>(_ body: () throws -> T) throws -> T {
        precondition(!isCurrent, "runAndWait called on the database thread would deadlock")
        return try withoutActuallyEscaping(body) { body in
            let call = Call(body)
            let finished = DispatchSemaphore(value: 0)
            queue.push {
                call.run()
                finished.signal()
            }
            finished.wait()
            return try call.result!.get()
        }
    }

    /// First in, first out; the thread sleeps while it is empty.
    private final class Queue: @unchecked Sendable {
        private let condition = NSCondition()
        private var work: [() -> Void] = []

        func push(_ item: @escaping () -> Void) {
            condition.lock()
            work.append(item)
            condition.signal()
            condition.unlock()
        }

        func drain() -> Never {
            while true {
                condition.lock()
                while work.isEmpty { condition.wait() }
                let next = work.removeFirst()
                condition.unlock()
                next()
            }
        }
    }

    /// Carries a closure and its result across to the database thread while the caller waits.
    private final class Call<T>: @unchecked Sendable {
        private let body: () throws -> T
        var result: Result<T, Error>?

        init(_ body: @escaping () throws -> T) { self.body = body }

        func run() { result = Result { try body() } }
    }
}
