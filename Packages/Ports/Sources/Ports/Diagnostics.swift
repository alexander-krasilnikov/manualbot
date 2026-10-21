import os

/// Lines for the system log, so the steps before a crash can be read afterwards. Unlike the tracer, these are always on,
/// and `notice` lines are kept on disk by the system, so they survive the app ending. Questions and answers are never
/// logged, only their sizes. See docs/testing.md, "Reading the log after a crash".
public enum Diagnostics {
    public static let subsystem = "com.manualbot.app"
    /// The steps of answering a question.
    public static let chat = Logger(subsystem: subsystem, category: "chat")
    /// Retrieval for a question.
    public static let retrieval = Logger(subsystem: subsystem, category: "retrieval")
    /// The language model: loading, and each request.
    public static let generation = Logger(subsystem: subsystem, category: "generation")
    /// Database queries.
    public static let database = Logger(subsystem: subsystem, category: "database")
    /// Intervals shown in Instruments' Points of Interest.
    public static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
}
