import Foundation
import Observation
import Ports

/// Everything the demo needs, created once at launch and shared with the services.
@MainActor
final class DemoSession {
    let tracer: DemoTracer
    let xray: XrayModel
    let explorer = ExplorerModel()
    /// Whether the device is online: the X-ray panel shows it, and the manual catalog needs it to import.
    let network: NetworkMonitor

    init(network: NetworkMonitor = NetworkMonitor()) {
        self.network = network
        tracer = DemoTracer()
        tracer.isEnabled = true
        xray = XrayModel(tracer: tracer, network: network)
        xray.openInExplorer = { [explorer] collection, id in
            explorer.present(ExplorerTarget(collection: collection, documentID: id))
        }
    }
}
