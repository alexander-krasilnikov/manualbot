import Foundation
import Ports
import Testing
@testable import ManualBot

@MainActor @Suite struct SyncSettingsTests {
    private func suite() -> UserDefaults {
        let name = "sync-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func syncIsOffAndEmptyUntilTheUserSetsItUp() {
        let settings = SyncSettings(defaults: suite(), secrets: InMemorySecretStore())
        #expect(!settings.isEnabled)
        #expect(settings.address.isEmpty && settings.username.isEmpty && settings.password.isEmpty)
        #expect(settings.configuration == nil)
    }

    @Test func everythingIsRememberedAcrossLaunches() {
        let defaults = suite()
        let secrets = InMemorySecretStore()
        let first = SyncSettings(defaults: defaults, secrets: secrets)
        first.address = "192.168.1.20:4984"
        first.username = "ipad1"
        first.password = "s3cret"
        first.isEnabled = true

        let relaunched = SyncSettings(defaults: defaults, secrets: secrets)
        #expect(relaunched.address == "192.168.1.20:4984")
        #expect(relaunched.username == "ipad1")
        #expect(relaunched.password == "s3cret")
        #expect(relaunched.isEnabled)
    }

    @Test func thePasswordIsNotKeptInTheDefaults() {
        let defaults = suite()
        let secrets = InMemorySecretStore()
        let settings = SyncSettings(defaults: defaults, secrets: secrets)
        settings.password = "s3cret-value"
        settings.username = "ipad1"

        let stored = defaults.dictionaryRepresentation().values.compactMap { $0 as? String }
        #expect(!stored.contains("s3cret-value"), "the password must only be in the secret store")
        #expect(secrets.secret(for: "library-sync") == "s3cret-value")
    }

    @Test func clearingThePasswordRemovesItFromTheSecretStore() {
        let secrets = InMemorySecretStore()
        let settings = SyncSettings(defaults: suite(), secrets: secrets)
        settings.password = "x"
        settings.password = ""
        #expect(secrets.secret(for: "library-sync") == nil)
    }

    @Test func theKeychainKeepsAndForgetsAPassword() {
        let store = KeychainSecretStore(service: "com.manualbot.tests.\(UUID().uuidString)")
        #expect(store.secret(for: "acct") == nil)
        store.setSecret("first", for: "acct")
        #expect(store.secret(for: "acct") == "first")
        store.setSecret("second", for: "acct")
        #expect(store.secret(for: "acct") == "second")
        store.setSecret(nil, for: "acct")
        #expect(store.secret(for: "acct") == nil)
    }

    // MARK: Reading an address

    @Test(arguments: [
        ("192.168.1.20:4984", "ws://192.168.1.20:4984/manualbot"),
        ("localhost:4984", "ws://localhost:4984/manualbot"),
        ("  localhost:4984/  ", "ws://localhost:4984/manualbot"),
        ("ws://host:4984/manualbot", "ws://host:4984/manualbot"),
        ("ws://host:4984/other", "ws://host:4984/other"),
        ("WSS://sync.example.com/manualbot", "wss://sync.example.com/manualbot"),
        ("sync.example.com", "ws://sync.example.com/manualbot"),
    ])
    func anAddressIsReadAsAServer(typed: String, expected: String) {
        #expect(SyncSettings.endpoint(from: typed)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "http://host:4984/manualbot", "ftp://host", "ws://", "://nothing"])
    func somethingThatIsNotAServerAddressIsRefused(typed: String) {
        #expect(SyncSettings.endpoint(from: typed) == nil)
    }

    @Test func theConfigurationNeedsAnAddressAndAUserName() {
        let settings = SyncSettings(defaults: suite(), secrets: InMemorySecretStore())
        settings.address = "localhost:4984"
        #expect(settings.configuration == nil, "no user name yet")
        settings.username = " ipad1 "
        settings.password = "pw"
        #expect(settings.configuration == SyncConfiguration(
            endpoint: URL(string: "ws://localhost:4984/manualbot")!, username: "ipad1", password: "pw"))
    }

    // MARK: Confirmations (6.6)

    @Test func theDeleteConfirmationSaysEveryDeviceOnlyWhenSyncIsOn() {
        #expect(LibraryView.deleteMessage(syncEnabled: true).contains("every device that shares the library"))
        #expect(!LibraryView.deleteMessage(syncEnabled: true).contains("this iPad"))
        #expect(LibraryView.deleteMessage(syncEnabled: false).contains("from this iPad"))
        #expect(!LibraryView.deleteMessage(syncEnabled: false).contains("every device"))
    }

    @Test func theResetConfirmationSaysEveryDeviceOnlyWhenSyncIsOn() {
        #expect(XrayControls.resetMessage(syncEnabled: true).contains("every device that shares the library"))
        #expect(!XrayControls.resetMessage(syncEnabled: false).contains("every device"))
        #expect(XrayControls.resetMessage(syncEnabled: false).contains("every document and chat in this app"))
    }

    @Test func theEmbedderConfirmationNamesTheSyncPauseOnlyWhenSyncWouldPause() {
        var cost = AppModel.SwitchCost(role: .embedder, documentsToReindex: 3, supportsPhotos: true)
        #expect(!ModelSettingsViewModel.message(for: cost).contains("Sync"))
        cost.pausesSync = true
        let message = ModelSettingsViewModel.message(for: cost)
        #expect(message.contains("Sync pauses while this model is in use"))
        #expect(message.contains("EmbeddingGemma 2"), "it names the fleet model")
        #expect(message.contains("3 documents will be re-indexed"), "the earlier cost is still there")
    }
}
