import Foundation
import Testing
@testable import WiFiSwitchCore

final class AccountRepositoryTests {
    private var storage: FakeStorage!
    private var vault: FakeVault!
    private var repository: AccountRepository!

    init() throws {
        storage = FakeStorage()
        vault = FakeVault()
        repository = try AccountRepository(storage: storage, vault: vault)
    }

    @Test func testCredentialsPersistAcrossRestartButNeverEnterJSON() throws {
        let network = try repository.addNetwork(ssid: "Enterprise")
        let account = try repository.saveAccount(networkID: network, label: "Work", username: "alice", newPassword: "distinct-secret")
        let restarted = try AccountRepository(storage: storage, vault: vault)
        #expect(try restarted.password(for: account) == "distinct-secret")
        let data = try JSONEncoder().encode(storage.value)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("distinct-secret"))
        #expect(!json.contains("password"))
    }

    @Test func oldRetryRecordsWithoutAuthenticationFlagStillLoad() throws {
        let networkID = try repository.addNetwork(ssid: "Enterprise")
        try repository.saveAccount(networkID: networkID, label: "Work", username: "alice", newPassword: "synthetic-secret")
        let network = repository.configuration.networks[0]
        let selection = SessionAccountSelection(network: network, account: network.accounts[0], source: .successfulSwitch)
        try repository.rememberConnection(selection)
        try repository.recordAutomaticReconnectFailure(for: selection, reason: "timeout")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(repository.configuration)) as? [String: Any])
        var failure = try #require(json["automaticReconnectFailure"] as? [String: Any])
        failure.removeValue(forKey: "requiresCredentialReview")
        json["automaticReconnectFailure"] = failure
        let old = try JSONDecoder().decode(AccountConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        try old.validate()
        #expect(old.currentConnection == selection)
        #expect(old.automaticReconnectFailure?.count == 1)
        #expect(old.automaticReconnectFailure?.requiresCredentialReview == false)
    }

    @Test func testEditWithoutNewPasswordPreservesSecretAndIdentity() throws {
        let network = try repository.addNetwork(ssid: "Enterprise")
        let account = try repository.saveAccount(networkID: network, label: "Work", username: "alice", newPassword: " secret ")
        try repository.saveAccount(networkID: network, accountID: account, label: "Test", username: "alice2", newPassword: nil)
        #expect(try repository.password(for: account) == " secret ")
        #expect(repository.configuration.networks[0].accounts[0].username == "alice2")
    }

    @Test func testSameUsernameCanHaveDifferentSecretsOnDifferentNetworks() throws {
        let first = try repository.addNetwork(ssid: "Office")
        let second = try repository.addNetwork(ssid: "Campus")
        let a = try repository.saveAccount(networkID: first, label: "", username: "alice", newPassword: "one")
        let b = try repository.saveAccount(networkID: second, label: "", username: "alice", newPassword: "two")
        #expect(try repository.password(for: a) == "one")
        #expect(try repository.password(for: b) == "two")
        #expect(throws: (any Error).self) { try repository.saveAccount(networkID: first, label: "", username: "alice", newPassword: "three") }
    }

    @Test func passwordWritesAndRollbackUseTheMatchingAccountName() throws {
        let network = try repository.addNetwork(ssid: "Office")
        let account = try repository.saveAccount(networkID: network, label: "办公账号", username: "alice", newPassword: "one")
        #expect(vault.names[account] == "办公账号")
        storage.fail = true
        #expect(throws: (any Error).self) {
            try repository.saveAccount(networkID: network, accountID: account, label: "新名称", username: "alice", newPassword: "two")
        }
        #expect(vault.names[account] == "办公账号")
        #expect(try repository.password(for: account) == "one")
    }

    @Test func testFailureToPersistNewAccountRollsBackCredential() throws {
        let network = try repository.addNetwork(ssid: "Office")
        storage.fail = true
        #expect(throws: (any Error).self) { try repository.saveAccount(networkID: network, label: "", username: "alice", newPassword: "one") }
        #expect(vault.values.isEmpty)
        #expect(repository.configuration.networks[0].accounts.isEmpty)
    }

    @Test func testFailureToPersistEditRestoresOldPasswordAndMetadata() throws {
        let network = try repository.addNetwork(ssid: "Office")
        let account = try repository.saveAccount(networkID: network, label: "Before", username: "alice", newPassword: "one")
        storage.fail = true
        #expect(throws: (any Error).self) { try repository.saveAccount(networkID: network, accountID: account, label: "After", username: "bob", newPassword: "two") }
        #expect(try repository.password(for: account) == "one")
        #expect(repository.configuration.networks[0].accounts[0].label == "Before")
    }

    @Test func testFailedDeleteRestoresCredentialThenSuccessfulDeleteRemovesIt() throws {
        let network = try repository.addNetwork(ssid: "Office")
        let account = try repository.saveAccount(networkID: network, label: "", username: "alice", newPassword: "one")
        storage.fail = true
        #expect(throws: (any Error).self) { try repository.deleteAccount(networkID: network, accountID: account) }
        #expect(try repository.password(for: account) == "one")
        storage.fail = false
        try repository.deleteAccount(networkID: network, accountID: account)
        #expect(try vault.password(for: account) == nil)
        #expect(repository.configuration.networks[0].accounts.isEmpty)
    }

    @Test func testKeychainFailureDoesNotPublishAccount() throws {
        let network = try repository.addNetwork(ssid: "Office")
        vault.fail = true
        #expect(throws: (any Error).self) { try repository.saveAccount(networkID: network, label: "", username: "alice", newPassword: "one") }
        #expect(storage.value.networks[0].accounts.isEmpty)
    }

    @Test func testDeletingNonemptyNetworkIsRejected() throws {
        let network = try repository.addNetwork(ssid: "Office")
        try repository.saveAccount(networkID: network, label: "", username: "alice", newPassword: "one")
        #expect(throws: (any Error).self) { try repository.removeNetwork(id: network) }
        #expect(repository.configuration.networks.count == 1)
    }

    @Test func testSSIDUsesByteLimitAndPreservesExactName() throws {
        #expect(throws: (any Error).self) { try repository.addNetwork(ssid: String(repeating: "网", count: 11)) }
        try repository.addNetwork(ssid: " Office ")
        try repository.addNetwork(ssid: "Office")
        #expect(repository.configuration.networks[0].ssid == " Office ")
        #expect(throws: (any Error).self) { try repository.addNetwork(ssid: "Office") }
    }

    @Test func testCorruptedFileCannotBeSilentlyReplacedOnLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("accounts.json")
        let corrupted = Data("not-json".utf8)
        try corrupted.write(to: url)
        #expect(throws: (any Error).self) { try AccountRepository(storage: JSONConfigurationStorage(url: url), vault: vault) }
        #expect(try Data(contentsOf: url) == corrupted)
    }

    @Test func testRealFileReplacementPersistsUpdatesWithPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = JSONConfigurationStorage(url: directory.appendingPathComponent("accounts.json"))
        let repo = try AccountRepository(storage: storage, vault: vault)
        let network = try repo.addNetwork(ssid: "Office")
        let account = try repo.saveAccount(networkID: network, label: "", username: "alice", newPassword: "one")
        try repo.markUsed(networkID: network, accountID: account)
        #expect(try storage.load().networks[0].accounts[0].lastUsedAt != nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: storage.url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func testInvalidPersistedDuplicateIDsAreRejected() throws {
        let id = UUID()
        storage.value = AccountConfiguration(networks: [SavedWiFi(id: id, ssid: "One"), SavedWiFi(id: id, ssid: "Two")])
        #expect(throws: (any Error).self) { try AccountRepository(storage: storage, vault: vault) }
    }
}

private struct SimulatedFailure: Error {}
private final class FakeStorage: ConfigurationStorage {
    var value = AccountConfiguration()
    var fail = false
    func load() -> AccountConfiguration { value }
    func save(_ configuration: AccountConfiguration) throws {
        if fail { throw SimulatedFailure() }
        value = configuration
    }
}
private final class FakeVault: CredentialVault {
    var values: [UUID: String] = [:]
    var names: [UUID: String] = [:]
    var fail = false
    func password(for accountID: UUID) throws -> String? {
        if fail { throw SimulatedFailure() }
        return values[accountID]
    }
    func setPassword(_ password: String, for accountID: UUID) throws {
        if fail { throw SimulatedFailure() }
        values[accountID] = password
    }
    func setPassword(_ password: String, for accountID: UUID, accountName: String) throws {
        try setPassword(password, for: accountID)
        names[accountID] = accountName
    }
    func deletePassword(for accountID: UUID) throws {
        if fail { throw SimulatedFailure() }
        values.removeValue(forKey: accountID)
        names.removeValue(forKey: accountID)
    }
}
