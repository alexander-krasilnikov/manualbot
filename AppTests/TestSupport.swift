import Foundation

/// Waits until `condition` holds, polling, and says whether it did within `timeout`. A passing test never waits the whole
/// time, so the generous default only slows a test that is about to fail.
@MainActor
func eventually(_ timeout: Duration = .seconds(30), _ condition: @MainActor () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
