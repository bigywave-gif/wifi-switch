import Foundation
import Testing
import WiFiSwitchCore
@testable import WiFiSwitch

@MainActor
struct SystemConnectionImportTests {
    @Test(arguments: [true, false])
    func failedIdentityReadNeverSuggestsAddingConfiguration(existingAccounts: Bool) async throws {
        let f = try ImportFixture(withAccounts: existingAccounts)
        f.reader.identityUnavailable = true
        await f.model.refresh()
        await f.model.refresh()
        #expect(f.model.systemImportCandidate == nil)
        #expect(f.model.selectedAccount == nil)
        #expect(f.reader.secretReads == 0 && f.wifi.connections == 0)
        // A failed read must not suppress a later genuinely missing configuration.
        f.reader.identityUnavailable = false
        f.reader.value = .init(identity: .init(ssid: "Office", authentication: .enterprise, username: "new-user"), password: nil)
        await f.model.refresh()
        #expect(f.model.systemImportCandidate?.automatic == true)
    }

    @Test func successfulMatchDismissesEarlierAutomaticProposal() async throws {
        let f = try ImportFixture(withAccounts: true)
        f.reader.value = .init(identity: .init(ssid: "Office", authentication: .enterprise, username: "new-user"), password: nil)
        await f.model.refresh()
        #expect(f.model.systemImportCandidate != nil)
        f.reader.value = .init(identity: .init(ssid: "Office", authentication: .enterprise, username: "alice"), password: nil)
        await f.model.refresh()
        #expect(f.model.selectedAccount?.username == "alice")
        #expect(f.model.systemImportCandidate == nil)
        #expect(f.reader.secretReads == 0)
    }

    @Test func manualImportRemainsOpenWhenExistingAccountMatches() async throws {
        let f = try ImportFixture(withAccounts: true)
        await f.model.refresh()
        f.model.beginSystemImport()
        await f.model.refresh()
        #expect(f.model.systemImportCandidate?.automatic == false)
    }

    @Test func missingUsernameWrongSSIDOrConflictingAuthenticationDoesNotPrompt() async throws {
        let f = try ImportFixture(withAccounts: true)
        for identity in [SystemConnectionIdentity(ssid: "Office", authentication: .enterprise, username: nil),
                         .init(ssid: "Other", authentication: .enterprise, username: "new-user"),
                         .init(ssid: "Office", authentication: .personal, username: nil),
                         .init(ssid: "Office", authentication: .unknown, username: "new-user")] {
            f.reader.value = .init(identity: identity, password: nil)
            await f.model.refresh()
            #expect(f.model.systemImportCandidate == nil)
        }
    }

    @Test func consentAndLabelRequiredAndCancellationDoesNotNag() async throws {
        let f = try ImportFixture()
        await f.model.refresh()
        #expect(f.model.systemImportCandidate?.ssid == "Office")
        #expect(f.reader.secretReads == 0)
        await f.model.confirmSystemImport(label: "   ")
        #expect(f.reader.secretReads == 0)
        f.model.cancelSystemImport()
        await f.model.refresh()
        #expect(f.model.systemImportCandidate == nil)
        f.model.beginSystemImport()
        #expect(f.model.systemImportCandidate != nil)
        #expect(f.wifi.connections == 0)
    }

    @Test(arguments: [WiFiAuthentication.enterprise, .personal, .open])
    func importAddsConfigurationAndSecretWithoutConnecting(mode: WiFiAuthentication) async throws {
        let f = try ImportFixture()
        f.reader.value = .init(identity: .init(ssid: "Office", authentication: mode, username: mode == .enterprise ? "alice" : nil),
                              password: mode == .open ? nil : "synthetic-secret")
        await f.model.refresh()
        await f.model.confirmSystemImport(label: "测试账号")
        #expect(f.model.accounts.count == 1)
        let account = try #require(f.model.accounts.first)
        #expect(account.label == "测试账号")
        #expect(account.username == (mode == .enterprise ? "alice" : ""))
        #expect(f.vault.values[account.id] == (mode == .open ? nil : "synthetic-secret"))
        #expect(f.model.connectedAccountID == account.id)
        #expect(f.model.accountSelection?.source == .systemSavedCredentials)
        #expect(f.model.systemImportCandidate == nil)
        #expect(f.wifi.connections == 0)
        let data = try JSONEncoder().encode(f.storage.value)
        #expect(!String(decoding: data, as: UTF8.self).contains("synthetic-secret"))
    }

    @Test func systemSwitchToExistingAccountUpdatesMarkerWithoutReadingPasswords() async throws {
        let f = try ImportFixture(withAccounts: true)
        await f.model.refresh()
        #expect(f.model.selectedAccount?.username == "alice")
        f.reader.value = .init(identity: .init(ssid: "Office", authentication: .enterprise, username: "bob"), password: "new")
        await f.model.connectionDidChange()
        #expect(f.model.selectedAccount?.username == "bob")
        #expect(f.model.displayAccounts.first?.username == "bob")
        #expect(f.model.systemImportCandidate == nil)
        #expect(f.reader.secretReads == 0)
        #expect(f.storage.value.currentConnection?.username == "bob")
        f.reader.identityUnavailable = true
        await f.model.refresh()
        #expect(f.model.selectedAccount == nil)
        #expect(f.model.systemImportCandidate == nil)
        #expect(f.reader.secretReads == 0)
    }

    @Test func duplicateReusesExistingWithoutOverwritingNameOrPassword() async throws {
        let f = try ImportFixture(withAccounts: true)
        await f.model.refresh()
        f.model.beginSystemImport()
        await f.model.confirmSystemImport(label: "不能覆盖原名称")
        #expect(f.model.accounts.count == 2)
        #expect(f.model.selectedAccount?.label == "Alice")
        #expect(f.model.systemImportError == nil)
        f.reader.value = .init(identity: f.reader.value.identity, password: "different")
        f.model.beginSystemImport()
        await f.model.confirmSystemImport(label: "新名称")
        #expect(f.model.systemImportError != nil)
        #expect(!f.vault.values.values.contains("different"))
    }

    @Test func missingDeniedAndAmbiguousCredentialsNeverPersist() async throws {
        let f = try ImportFixture()
        await f.model.refresh()
        f.reader.error = SystemImportError.unavailable
        await f.model.confirmSystemImport(label: "Test")
        #expect(f.model.accounts.isEmpty && f.vault.values.isEmpty)
        #expect(f.model.systemImportError != nil)
        #expect(throws: SystemImportError.self) {
            try SystemConnectionReader.resolve(ssid: "Office", authentication: .enterprise, credentials: [
                .init(username: "alice", password: "one"), .init(username: "bob", password: "two")])
        }
        #expect(throws: SystemImportError.self) {
            try SystemConnectionReader.resolve(ssid: "Office", authentication: .personal, credentials: [])
        }
    }

    @Test(arguments: [true, false])
    func cancelOrNetworkChangeDuringKeychainReadDiscardsResult(cancel: Bool) async throws {
        let f = try ImportFixture()
        await f.model.refresh()
        f.reader.hold = true
        let task = Task { await f.model.confirmSystemImport(label: "Test") }
        while f.reader.continuation == nil { await Task.yield() }
        await f.model.confirmSystemImport(label: "Duplicate")
        #expect(f.reader.secretReads == 1)
        if cancel { f.model.cancelSystemImport() }
        else { f.wifi.current.ssid = "Other"; await f.model.refresh() }
        f.reader.continuation?.resume(); f.reader.continuation = nil
        await task.value
        #expect(f.model.accounts.isEmpty && f.vault.values.isEmpty)
        #expect(!f.model.isImporting)
        #expect(f.wifi.connections == 0)
    }

    @Test func failedPersistenceRollsBackSecretAndNetwork() async throws {
        let f = try ImportFixture()
        await f.model.refresh()
        f.storage.fail = true
        await f.model.confirmSystemImport(label: "Test")
        #expect(f.model.accounts.isEmpty && f.model.networks.isEmpty && f.vault.values.isEmpty)
        #expect(f.model.systemImportError != nil)
    }

    @Test(arguments: [true, false])
    func explicitConnectionUsesChoiceAndRetainsLiveMarkerUntilSystemReconnect(sync: Bool) async throws {
        let f = try ImportFixture(withAccounts: true, choice: sync)
        await f.model.refresh()
        let bob = try #require(f.model.accounts.first { $0.username == "bob" })
        await f.model.switchAccount(bob, on: f.model.networks[0])?.value
        #expect(f.wifi.policies == [sync])
        #expect(f.model.selectedAccount?.username == "bob")
        // The stored system identity still says Alice, e.g. after choosing No.
        await f.model.refresh()
        #expect(f.model.selectedAccount?.username == "bob")
        f.wifi.current.ssid = nil
        await f.model.refresh()
        f.wifi.current.ssid = "Office"
        await f.model.refresh()
        #expect(f.model.selectedAccount?.username == "alice")
    }

    @Test func cancelConnectionPromptLeavesConnectionAndRecordUntouched() async throws {
        let f = try ImportFixture(withAccounts: true, choice: nil)
        await f.model.refresh()
        let before = f.storage.value.currentConnection
        let bob = try #require(f.model.accounts.first { $0.username == "bob" })
        #expect(f.model.switchAccount(bob, on: f.model.networks[0]) == nil)
        #expect(f.storage.value.currentConnection == before)
        #expect(f.wifi.connections == 0)
    }
}

@MainActor private final class ImportFixture {
    let storage = ImportStorage()
    let vault = MemoryVault()
    let wifi = ImportWiFi()
    let reader = ImportReader()
    let model: AppModel
    init(withAccounts: Bool = false, choice: Bool? = true) throws {
        let repository = try AccountRepository(storage: storage, vault: vault)
        if withAccounts {
            let network = try repository.addNetwork(ssid: "Office")
            try repository.saveAccount(networkID: network, label: "Alice", username: "alice", newPassword: "synthetic-secret")
            try repository.saveAccount(networkID: network, label: "Bob", username: "bob", newPassword: "bob-secret")
        }
        model = AppModel(demoMode: true, wifi: wifi, repository: repository, automaticReconnectEnabled: false,
                         systemReader: reader, syncPreferenceDecision: { _, _ in choice })
    }
}

private final class ImportStorage: ConfigurationStorage {
    var value = AccountConfiguration()
    var fail = false
    func load() -> AccountConfiguration { value }
    func save(_ configuration: AccountConfiguration) throws {
        if fail { throw SystemImportError.storage }
        value = configuration
    }
}

private final class ImportReader: SystemConnectionReading {
    var value = SystemConnectionConfiguration(identity: .init(ssid: "Office", authentication: .enterprise, username: "alice"), password: "synthetic-secret")
    var secretReads = 0
    var identityUnavailable = false
    var error: Error?
    var hold = false
    var continuation: CheckedContinuation<Void, Never>?
    func identity(ssid: String) async -> SystemConnectionIdentity? { identityUnavailable ? nil : value.identity }
    func configuration(ssid: String) async throws -> SystemConnectionConfiguration {
        secretReads += 1
        if hold { await withCheckedContinuation { continuation = $0 } }
        if let error { throw error }
        return value
    }
}

private final class ImportWiFi: WiFiServicing {
    var current = WiFiSnapshot(ssid: "Office", poweredOn: true, available: true, hasUsableAddress: true)
    var connections = 0
    var policies: [Bool] = []
    func snapshot() async -> WiFiSnapshot { current }
    func scan() async throws -> [NearbyWiFi] { [] }
    func switchAccount(ssid: String, username: String, password: String, synchronizeSystemCredentials: Bool,
                       progress: @escaping (SwitchPhase) -> Void) async throws {
        policies.append(synchronizeSystemCredentials)
        try await switchAccount(ssid: ssid, username: username, password: password, progress: progress)
    }
    func switchAccount(ssid: String, username: String, password: String, progress: @escaping (SwitchPhase) -> Void) async throws {
        connections += 1
        current.ssid = ssid
    }
    func reconnectAccount(ssid: String, username: String, password: String, progress: @escaping (SwitchPhase) -> Void) async throws { connections += 1 }
}
