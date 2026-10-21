import Network
import Observation

/// Whether the device currently has a network connection, so the panel can show that everything still works without one.
@MainActor @Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    @ObservationIgnored private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "xray.network", qos: .utility))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    /// For tests.
    func set(online: Bool) { isOnline = online }
}
