import Foundation
import Observation
import Ports

/// Whether demo mode is on. Off by default; the `-demoMode` launch argument turns it on for one launch, and
/// the switch in the About sheet is remembered.
@MainActor @Observable
final class DemoSettings {
    static let defaultsKey = "xray.demoMode"
    static let launchArgument = "-demoMode"

    var isOn: Bool {
        didSet {
            defaults.set(isOn, forKey: Self.defaultsKey)
            tracer.isEnabled = isOn
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let tracer: DemoTracer

    init(tracer: DemoTracer, defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.tracer = tracer
        self.defaults = defaults
        isOn = arguments.contains(Self.launchArgument) || defaults.bool(forKey: Self.defaultsKey)
        tracer.isEnabled = isOn
    }
}

/// Everything the demo needs, created once at launch and shared with the services.
@MainActor
final class DemoSession {
    let tracer: DemoTracer
    let settings: DemoSettings
    let xray: XrayModel

    init(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) {
        tracer = DemoTracer()
        settings = DemoSettings(tracer: tracer, defaults: defaults, arguments: arguments)
        xray = XrayModel(tracer: tracer)
    }
}
