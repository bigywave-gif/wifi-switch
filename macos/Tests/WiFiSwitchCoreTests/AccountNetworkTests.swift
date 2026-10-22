import Foundation
import Testing
@testable import WiFiSwitchCore

struct AccountNetworkTests {
    @Test func personalAndOpenAccountsPersistWithoutEnterpriseUsername() throws {
        let storage = LinkStorage(); let vault = LinkVault()
        let repository = try AccountRepository(storage: storage, vault: vault)
        let personal = try repository.saveAccount(label: "Phone", username: "", newPassword: "synthetic", networkSSIDs: ["Hotspot"], networkAuthentications: ["Hotspot": .personal])
        let vaultCalls = vault.reads + vault.writes
        let open = try repository.saveAccount(label: "Guest", username: "", newPassword: nil, networkSSIDs: ["Guest"], networkAuthentications: ["Guest": .open])
        #expect(vault.reads + vault.writes == vaultCalls)
        #expect(try repository.password(for: open) == "")
        #expect(vault.reads + vault.writes == vaultCalls)
        let restarted = try AccountRepository(storage: storage, vault: vault)
        #expect(restarted.configuration.accounts.first(where: { $0.id == open })?.hasStoredSecret == false)
        #expect(restarted.configuration.networks.map(\.authentication) == [.personal, .open])
        #expect(try restarted.password(for: personal) == "synthetic")
        let beforeDelete = vault.reads + vault.writes
        try restarted.deleteAccount(accountID: open)
        #expect(vault.reads + vault.writes == beforeDelete)
        #expect(vault.values.count == 1)
    }

    @Test func addingProtectedNetworksRequiresCredentialsAndSaveFailurePreservesOpenAccount() throws {
        let storage = LinkStorage(); let vault = LinkVault()
        let repository = try AccountRepository(storage: storage, vault: vault)
        let id = try repository.saveAccount(label: "Guest", username: "", newPassword: nil, networkSSIDs: ["Guest"], networkAuthentications: ["Guest": .open])
        let original = repository.configuration
        #expect(throws: (any Error).self) { try repository.linkNetwork(accountID: id, ssid: "Office", authentication: .enterprise) }
        #expect(throws: (any Error).self) { try repository.linkNetwork(accountID: id, ssid: "Phone", authentication: .personal) }
        #expect(repository.configuration == original && vault.values.isEmpty)
        storage.fail = true
        #expect(throws: (any Error).self) {
            try repository.saveAccount(accountID: id, label: "Guest", username: "", newPassword: "synthetic", networkSSIDs: ["Guest", "Phone"], networkAuthentications: ["Phone": .personal])
        }
        #expect(repository.configuration == original && vault.values.isEmpty)
        storage.fail = false
        try repository.saveAccount(accountID: id, label: "Guest", username: "", newPassword: "synthetic", networkSSIDs: ["Guest", "Phone"], networkAuthentications: ["Phone": .personal])
        #expect(repository.configuration.accounts[0].hasStoredSecret)
        #expect(try repository.password(for: id) == "synthetic")
    }

    @Test func v3MigrationPreservesIDsAndSecretsWithoutVaultAccess() throws {
        let account = WiFiAccount(label: "Work", username: "alice")
        let network = SavedWiFi(ssid: "Office", accounts: [account])
        var legacy = AccountConfiguration(networks: [network]); legacy.version = 3
        legacy.currentConnection = SessionAccountSelection(network: network, account: account, source: .successfulSwitch)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        var networks = try #require(json["networks"] as? [[String: Any]])
        for i in networks.indices { networks[i].removeValue(forKey: "authentication") }
        var accounts = try #require(json["accounts"] as? [[String: Any]])
        for i in accounts.indices { accounts[i].removeValue(forKey: "hasStoredSecret") }
        json["networks"] = networks; json["accounts"] = accounts
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storage = JSONConfigurationStorage(url: directory.appendingPathComponent("accounts.json"))
        let original = try JSONSerialization.data(withJSONObject: json)
        try original.write(to: storage.url)
        let vault = LinkVault(); vault.values[account.id] = "synthetic"
        let repository = try AccountRepository(storage: storage, vault: vault)
        #expect(repository.configuration.version == 4)
        #expect(repository.configuration.accounts[0].id == account.id && repository.configuration.accounts[0].hasStoredSecret)
        #expect(repository.configuration.networks[0].authentication == .enterprise)
        #expect(repository.configuration.currentConnection == legacy.currentConnection)
        #expect(vault.reads == 0 && vault.writes == 0)
        let backup = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("accounts-pre-v4-") })
        #expect(try Data(contentsOf: backup) == original)
    }

    @Test func creatingAccountWithSavedAndNewSSIDsPublishesOneCompleteSelection() throws {
        let storage = LinkStorage(); let vault = LinkVault()
        let repository = try AccountRepository(storage: storage, vault: vault)
        let office = try repository.addNetwork(ssid: "Office")
        let id = try repository.saveAccount(label: "Work", username: "new-user", newPassword: "synthetic",
                                           networkSSIDs: ["Office", "Campus", "Hidden", "Campus"])
        #expect(repository.configuration.accounts.count == 1)
        #expect(repository.configuration.networks.map(\.ssid) == ["Office", "Campus", "Hidden"])
        #expect(repository.configuration.accounts[0].networkIDs.first == office)
        #expect(repository.configuration.accounts[0].networkIDs.count == 3)
        #expect(repository.configuration.networks.allSatisfy { $0.accounts.map(\.id) == [id] })
        let restarted = try AccountRepository(storage: storage, vault: vault)
        #expect(restarted.configuration == repository.configuration)
        #expect(try restarted.password(for: id) == "synthetic")
        #expect(vault.values.count == 1)
    }

    @Test func failedSaveWithNewSSIDsLeavesNoOrphanNetworksOrCredentials() throws {
        let storage = LinkStorage(); let vault = LinkVault()
        let repository = try AccountRepository(storage: storage, vault: vault)
        let original = repository.configuration
        storage.fail = true
        #expect(throws: (any Error).self) {
            try repository.saveAccount(label: "New", username: "new", newPassword: "synthetic", networkSSIDs: ["Office", "Campus"])
        }
        #expect(repository.configuration == original && storage.value == original)
        #expect(vault.values.isEmpty)
        storage.fail = false
        let id = try repository.saveAccount(label: "Work", username: "alice", newPassword: "original", networkSSIDs: ["Office"])
        let saved = repository.configuration
        storage.fail = true
        #expect(throws: (any Error).self) {
            try repository.saveAccount(accountID: id, label: "Changed", username: "bob", newPassword: "changed", networkSSIDs: ["Campus", "Hidden"])
        }
        #expect(repository.configuration == saved && storage.value == saved)
        #expect(vault.values[id] == "original")
    }

    @Test func invalidOrConflictingSSIDSelectionDoesNotTouchVaultOrCreateNetworks() throws {
        let storage = LinkStorage(); let vault = LinkVault()
        let repository = try AccountRepository(storage: storage, vault: vault)
        try repository.saveAccount(label: "First", username: "same", newPassword: "original", networkSSIDs: ["Office"])
        let original = repository.configuration
        let calls = vault.reads + vault.writes
        for ssids in [["Campus", "Office"], ["Campus", " "], ["Campus", String(repeating: "网", count: 11)]] {
            #expect(throws: (any Error).self) {
                try repository.saveAccount(label: "Second", username: "same", newPassword: "other", networkSSIDs: ssids)
            }
            #expect(repository.configuration == original && storage.value == original)
            #expect(vault.reads + vault.writes == calls)
        }
    }

    @Test func changingSSIDSelectionPreservesPasswordAndOnlyInvalidatesRemovedCurrentNetwork() throws {
        let storage = LinkStorage(); let vault = LinkVault()
        let repository = try AccountRepository(storage: storage, vault: vault)
        let id = try repository.saveAccount(label: "Work", username: "alice", newPassword: "synthetic", networkSSIDs: ["Office"])
        let office = repository.configuration.networks[0]
        try repository.rememberConnection(SessionAccountSelection(network: office, account: office.accounts[0], source: .successfulSwitch))
        let calls = vault.reads + vault.writes
        try repository.saveAccount(accountID: id, label: "Work", username: "alice", newPassword: nil, networkSSIDs: ["Office", "Campus"])
        #expect(repository.configuration.currentConnection?.networkID == office.id)
        try repository.saveAccount(accountID: id, label: "Work", username: "alice", newPassword: nil, networkSSIDs: ["Campus"])
        #expect(repository.configuration.currentConnection == nil)
        #expect(vault.values[id] == "synthetic")
        #expect(vault.reads + vault.writes == calls)
    }

    @Test func oneCredentialServesMultipleNetworksAndCanExistWithoutNetworks() throws {
        let storage = LinkStorage(); let vault = LinkVault()
        let repository = try AccountRepository(storage: storage, vault: vault)
        let id = try repository.saveAccount(label: "Work", username: "alice", newPassword: "synthetic-one")
        #expect(repository.configuration.accounts.count == 1)
        #expect(repository.configuration.accounts[0].networkIDs.isEmpty)
        let mutations = vault.writes
        try repository.linkNetwork(accountID: id, ssid: "Office")
        try repository.linkNetwork(accountID: id, ssid: "Campus")
        #expect(repository.configuration.networks.count == 2)
        #expect(repository.configuration.networks.allSatisfy { $0.accounts[0].id == id })
        #expect(vault.writes == mutations)
        #expect(vault.values.count == 1)
        let reopened = try AccountRepository(storage: storage, vault: vault)
        #expect(try reopened.password(for: id) == "synthetic-one")
        #expect(reopened.configuration.accounts[0].networkIDs.count == 2)
        try reopened.saveAccount(accountID: id, label: "Renamed", username: "alice2", newPassword: "synthetic-two")
        #expect(reopened.configuration.networks.allSatisfy { $0.accounts[0].label == "Renamed" && $0.accounts[0].username == "alice2" })
        #expect(vault.values.count == 1)
        #expect(try reopened.password(for: id) == "synthetic-two")
    }

    @Test func unlinkRetainsPasswordAndOtherUsersWhileClearingOnlyMatchingConnection() throws {
        let storage = LinkStorage(); let vault = LinkVault()
        let repository = try AccountRepository(storage: storage, vault: vault)
        let one = try repository.saveAccount(label: "One", username: "one", newPassword: "synthetic-one")
        let two = try repository.saveAccount(label: "Two", username: "two", newPassword: "synthetic-two")
        try repository.linkNetwork(accountID: one, ssid: "Office")
        try repository.linkNetwork(accountID: one, ssid: "Campus")
        try repository.linkNetwork(accountID: two, ssid: "Office")
        let office = repository.configuration.networks[0]
        let campus = repository.configuration.networks[1]
        try repository.rememberConnection(SessionAccountSelection(network: office, account: office.accounts[0], source: .successfulSwitch))
        let accessCount = vault.reads + vault.writes
        try repository.unlinkNetwork(accountID: one, networkID: campus.id)
        #expect(repository.configuration.currentConnection?.networkID == office.id)
        try repository.unlinkNetwork(accountID: one, networkID: office.id)
        #expect(repository.configuration.currentConnection == nil)
        #expect(repository.configuration.accounts.count == 2)
        #expect(repository.configuration.accounts[0].networkIDs.isEmpty)
        #expect(repository.configuration.networks[0].accounts.map(\.id) == [two])
        #expect(vault.reads + vault.writes == accessCount)
        #expect(try repository.password(for: one) == "synthetic-one")
        try repository.deleteAccount(accountID: one)
        #expect(vault.values[one] == nil)
        #expect(try repository.password(for: two) == "synthetic-two")
    }

    @Test func failedRelationAndSharedCredentialEditsAreAtomic() throws {
        let storage = LinkStorage(); let vault = LinkVault()
        let repository = try AccountRepository(storage: storage, vault: vault)
        let id = try repository.saveAccount(label: "Work", username: "alice", newPassword: "synthetic-one")
        try repository.linkNetwork(accountID: id, ssid: "Office")
        try repository.linkNetwork(accountID: id, ssid: "Campus")
        let original = repository.configuration
        storage.fail = true
        #expect(throws: (any Error).self) { try repository.linkNetwork(accountID: id, ssid: "New") }
        #expect(throws: (any Error).self) { try repository.unlinkNetwork(accountID: id, networkID: original.networks[0].id) }
        #expect(throws: (any Error).self) {
            try repository.saveAccount(accountID: id, label: "Changed", username: "bob", newPassword: "synthetic-new", networkIDs: [])
        }
        #expect(repository.configuration == original)
        #expect(storage.value == original)
        #expect(try repository.password(for: id) == "synthetic-one")
    }

    @Test func duplicateLinkAndConflictingUsernamesAreRejectedBeforeChangingSecrets() throws {
        let storage = LinkStorage(); let vault = LinkVault()
        let repository = try AccountRepository(storage: storage, vault: vault)
        let one = try repository.saveAccount(label: "One", username: "same", newPassword: "synthetic-one")
        let two = try repository.saveAccount(label: "Two", username: "same", newPassword: "synthetic-two")
        try repository.linkNetwork(accountID: one, ssid: "Office")
        #expect(throws: (any Error).self) { try repository.linkNetwork(accountID: one, ssid: "Office") }
        #expect(throws: (any Error).self) { try repository.linkNetwork(accountID: two, ssid: "Office") }
        #expect(repository.configuration.accounts[1].networkIDs.isEmpty)
        #expect(vault.values.count == 2)
        #expect(throws: (any Error).self) { try repository.linkNetwork(accountID: two, ssid: String(repeating: "网", count: 11)) }
    }

    @Test func v2MigrationPreservesIDsCurrentSelectionAndDistinctSecretsWithoutVaultAccess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let one = WiFiAccount(label: "First", username: "same", lastUsedAt: Date(timeIntervalSince1970: 10))
        let two = WiFiAccount(label: "Second", username: "same")
        let first = SavedWiFi(ssid: "Office", accounts: [one])
        let second = SavedWiFi(ssid: "Campus", accounts: [two])
        var old = AccountConfiguration(networks: [first, second])
        old.version = 2
        old.currentConnection = SessionAccountSelection(network: first, account: one, source: .successfulSwitch)
        // Real v2 did not contain networkIDs. Strip that field to exercise the original format.
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        var networks = try #require(json["networks"] as? [[String: Any]])
        for index in networks.indices {
            var accounts = try #require(networks[index]["accounts"] as? [[String: Any]])
            for ai in accounts.indices { accounts[ai].removeValue(forKey: "networkIDs") }
            networks[index]["accounts"] = accounts
        }
        json["networks"] = networks
        let original = try JSONSerialization.data(withJSONObject: json)
        let storage = JSONConfigurationStorage(url: directory.appendingPathComponent("accounts.json"))
        try original.write(to: storage.url)
        let vault = LinkVault(); vault.values = [one.id: "synthetic-one", two.id: "synthetic-two"]
        let repository = try AccountRepository(storage: storage, vault: vault)
        #expect(repository.configuration.version == 4)
        #expect(repository.configuration.accounts.map(\.id) == [one.id, two.id])
        #expect(repository.configuration.accounts[0].networkIDs == [first.id])
        #expect(repository.configuration.accounts[1].networkIDs == [second.id])
        #expect(repository.configuration.currentConnection == old.currentConnection)
        #expect(vault.reads == 0 && vault.writes == 0)
        #expect(try storage.load().accounts.count == 2)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("accounts-pre-v4-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: backups[0]) == original)
        #expect((try FileManager.default.attributesOfItem(atPath: backups[0].path)[.posixPermissions] as? Int) == 0o600)
        _ = try AccountRepository(storage: storage, vault: vault)
        #expect(vault.reads == 0 && vault.writes == 0)
    }

    @Test func accountWithoutNetworksRoundTripsAndInvalidReferencesAreRejected() throws {
        let storage = LinkStorage(); let vault = LinkVault()
        let repository = try AccountRepository(storage: storage, vault: vault)
        let id = try repository.saveAccount(label: "Work", username: "alice", newPassword: "synthetic")
        let data = try JSONEncoder().encode(repository.configuration)
        let restored = try JSONDecoder().decode(AccountConfiguration.self, from: data)
        #expect(restored.accounts.map(\.id) == [id])
        #expect(restored.networks.isEmpty)
        var invalid = restored
        invalid.accounts[0].networkIDs = [UUID()]
        #expect(throws: (any Error).self) { try invalid.validate() }
    }
}

private final class LinkStorage: ConfigurationStorage {
    var value = AccountConfiguration()
    var fail = false
    func load() -> AccountConfiguration { value }
    func save(_ configuration: AccountConfiguration) throws {
        if fail { throw CocoaError(.fileWriteNoPermission) }
        value = configuration
    }
}
private final class LinkVault: CredentialVault {
    var values: [UUID: String] = [:]
    var reads = 0
    var writes = 0
    func password(for accountID: UUID) -> String? { reads += 1; return values[accountID] }
    func setPassword(_ password: String, for accountID: UUID) { writes += 1; values[accountID] = password }
    func deletePassword(for accountID: UUID) { writes += 1; values.removeValue(forKey: accountID) }
}
