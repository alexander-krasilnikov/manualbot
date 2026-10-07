import Foundation
import Observation
import Ports

/// Everything the demo needs, created once at launch and shared with the services.
@MainActor
final class DemoSession {
    let tracer: DemoTracer
    let xray: XrayModel
    let explorer = ExplorerModel()

    init() {
        tracer = DemoTracer()
        tracer.isEnabled = true
        xray = XrayModel(tracer: tracer)
        xray.openInExplorer = { [explorer] collection, id in
            explorer.present(ExplorerTarget(collection: collection, documentID: id))
        }
    }
}
