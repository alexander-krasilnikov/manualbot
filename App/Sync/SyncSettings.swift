import Foundation
import Observation
import Ports

/// What the user entered for sync: the server, the account, and whether sync is on. All of it is remembered across
/// launches; the password lives in the Keychain, the rest in the app's defaults. Sync is off until the user turns it on.
@MainActor @Observable
final class SyncSettings {
    /// The database every iPad of a library shares on a Sync Gateway.
    static let databaseName = "manualbot"
    private static let passwordAccount = "library-sync"

    var address: String { didSet { defaults.set(address, forKey: Keys.address) } }
    var username: String { didSet { defaults.set(username, forKey: Keys.username) } }
    var password: String { didSet { secrets.setSecret(password, for: Self.passwordAccount) } }
    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Keys.enabled) } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: any SecretStore

    private enum Keys {
        static let address = "sync.address"
        static let username = "sync.username"
        static let enabled = "sync.enabled"
    }

    init(defaults: UserDefaults = .standard, secrets: any SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
        address = defaults.string(forKey: Keys.address) ?? ""
        username = defaults.string(forKey: Keys.username) ?? ""
        password = secrets.secret(for: Self.passwordAccount) ?? ""
        isEnabled = defaults.bool(forKey: Keys.enabled)
    }

    /// What the replicator needs, or `nil` while the address does not read as a server or there is no user name.
    var configuration: SyncConfiguration? {
        guard let endpoint = Self.endpoint(from: address), !username.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return SyncConfiguration(
            endpoint: endpoint, username: username.trimmingCharacters(in: .whitespaces), password: password)
    }

    /// Reads what a person types for a server: `192.168.1.20:4984`, `localhost:4984`, or a full address such as
    /// `ws://host:4984/manualbot` or `wss://sync.example.com/manualbot`. A missing scheme is `ws`, and a missing database is
    /// the one the app uses. Anything that is not a WebSocket address of a host is `nil`.
    static func endpoint(from address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "ws://" + text }
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
            ["ws", "wss"].contains(scheme), let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        if components.path.isEmpty || components.path == "/" { components.path = "/" + databaseName }
        return components.url
    }
}
