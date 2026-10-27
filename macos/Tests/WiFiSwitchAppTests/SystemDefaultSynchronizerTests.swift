import CoreWLAN
import Foundation
import Testing
import WiFiSwitchCore
@testable import WiFiSwitch

struct SystemDefaultSynchronizerTests {
    @Test func noSyncRestoresNativeWritesWithoutChangingNetworkPreferences() throws {
        let store = FakeDefaultStore()
        store.values[.user] = old
        let backup = try SystemCredentialBackup(store: store, ssid: ssid, credentials: .enterprise(username: "art", password: "new-secret"))
        store.values = [.user: new, .system: new]
        try backup.restore()
        #expect(store.values[.user] == old && store.values[.system] == nil)
        #expect(store.commits == 0 && store.profiles == ["Other", "Office"])
    }

    @Test func noSyncDoesNotRewriteUnchangedCredentialsOrOverwriteExternalChange() throws {
        let store = FakeDefaultStore(); store.values[.user] = old
        let backup = try SystemCredentialBackup(store: store, ssid: ssid, credentials: .enterprise(username: "art", password: "new-secret"))
        try backup.restore()
        #expect(store.writes.isEmpty)
        let external = SystemWiFiCredential(username: "external", password: "other")
        store.values[.user] = external
        #expect(throws: SystemCredentialPreservationError.self) { try backup.restore() }
        #expect(store.values[.user] == external && store.writes.isEmpty)
    }

    @Test func noSyncReadDenialStopsBeforeAnyWrites() {
        let store = FakeDefaultStore(); store.failRead = true
        #expect(throws: SystemCredentialPreservationError.self) {
            try SystemCredentialBackup(store: store, ssid: ssid, credentials: .enterprise(username: "art", password: "new-secret"))
        }
        #expect(store.writes.isEmpty && store.commits == 0)
    }

    private let ssid = Data("Office".utf8)
    private let old = SystemWiFiCredential(username: "group", password: "old-secret")
    private let new = SystemWiFiCredential(username: "art", password: "new-secret")

    @Test func latestSuccessfulAccountUpdatesCredentialsWithoutChangingPreferredOrder() throws {
        let store = FakeDefaultStore()
        store.values = [.user: old, .system: old]
        store.preferences.requireAdministratorForPower = true
        try save(store)
        #expect(store.values[.user] == new && store.values[.system] == new)
        #expect(store.profiles == ["Other", "Office"] && store.commits == 0)
        #expect(store.preferences.requireAdministratorForPower)
        #expect(store.preferences.rememberJoinedNetworks == false)
        #expect(store.enterpriseCalls.allSatisfy { $0 })
    }

    @Test func noNewSystemWideCredentialIsCreated() throws {
        let store = FakeDefaultStore()
        try save(store)
        #expect(store.values[.user] == new && store.values[.system] == nil)
        #expect(store.writes == [.user])
    }

    @Test func networkChangeRestoresBothCredentialsAndPreservesNetworkOrder() {
        let store = FakeDefaultStore()
        store.values = [.user: old, .system: old]; store.disconnectOnWrite = true
        #expect(throws: SystemDefaultSyncError.self) { try save(store) }
        #expect(store.values[.user] == old && store.values[.system] == old)
        #expect(store.profiles == ["Other", "Office"])
    }

    @Test func denialBeforeWritesPreservesEverything() {
        let store = FakeDefaultStore(); store.values[.user] = old; store.failRead = true
        #expect(throws: SystemDefaultSyncError.self) { try save(store) }
        #expect(store.writes.isEmpty && store.commits == 0 && store.values[.user] == old)
    }

    @Test func systemCredentialDenialRollsBackTheUpdatedUserCredential() {
        let store = FakeDefaultStore(); store.values = [.user: old, .system: old]
        store.failSystemWrite = true
        #expect(throws: SystemDefaultSyncError.self) { try save(store) }
        #expect(store.values[.user] == old && store.values[.system] == old)
        #expect(store.commits == 0)
    }

    @Test func networkChangeRemovesOnlyNewlyCreatedCredential() {
        let store = FakeDefaultStore(); store.disconnectOnWrite = true
        #expect(throws: SystemDefaultSyncError.self) { try save(store) }
        #expect(store.values.isEmpty && store.writes == [.user, .user])
    }

    @Test func readbackMismatchIsFailureEvenIfWriteReturnsSuccess() {
        let store = FakeDefaultStore(); store.values[.user] = old; store.ignoreWrites = true
        #expect(throws: SystemDefaultSyncError.self) { try save(store) }
        #expect(store.values[.user] == old && store.commits == 0)
    }

    @Test func personalNetworkSavesOnlyPasswordAndOpenNetworkNeverAccessesKeychain() throws {
        let personal = FakeDefaultStore(); personal.currentSecurity = .wpa2Personal
        try SystemDefaultSynchronizer(store: personal).save(ssid: ssid, credentials: .personal(password: "hotspot-secret"))
        #expect(personal.values[.user] == SystemWiFiCredential(username: nil, password: "hotspot-secret"))
        #expect(personal.enterpriseCalls.allSatisfy { !$0 })
        let open = FakeDefaultStore(); open.currentSecurity = .none
        try SystemDefaultSynchronizer(store: open).save(ssid: ssid, credentials: .open)
        #expect(open.enterpriseCalls.isEmpty && open.writes.isEmpty && open.profiles == ["Other", "Office"] && open.commits == 0)
    }

    @Test func matchingDefaultsNeedNoWritesOrPreferenceAuthorization() throws {
        let store = FakeDefaultStore(); store.values[.user] = new
        store.preferences.networkProfiles = NSOrderedSet(array: store.preferences.networkProfiles.array.reversed())
        try save(store)
        #expect(store.writes.isEmpty && store.commits == 0)
    }

    @Test func networkChangeDuringCredentialWriteRollsBackAndDoesNotChangePriority() {
        let store = FakeDefaultStore(); store.values[.user] = old; store.disconnectOnWrite = true
        #expect(throws: SystemDefaultSyncError.self) { try save(store) }
        #expect(store.values[.user] == old && store.commits == 0)
    }

    @Test func externalPreferenceChangesAreNotOverwrittenOrTreatedAsSyncFailure() throws {
        let store = FakeDefaultStore(); store.values[.user] = old; store.externalEditOnWrite = true
        try save(store)
        #expect(store.preferences.requireAdministratorForPower)
        #expect(store.values[.user] == new && store.commits == 0)
    }

    @Test func rollbackFailureIsExplicitAndContainsNoNativeSecretText() {
        let store = FakeDefaultStore(); store.values[.user] = old
        store.disconnectOnWrite = true; store.failRollback = true
        do {
            try save(store)
            Issue.record("Should fail")
        } catch let error as SystemDefaultSyncError {
            #expect(error.rollbackFailed)
            #expect(!error.localizedDescription.contains("old-secret"))
            #expect(!error.localizedDescription.contains("new-secret"))
        } catch { Issue.record("Unexpected error") }
    }

    @Test func missingPreferredProfileDoesNotInsertOrReorderNetworks() throws {
        let store = FakeDefaultStore()
        store.preferences.networkProfiles = NSOrderedSet(array: [store.preferences.networkProfiles[0]])
        try save(store)
        let first = try #require(store.preferences.networkProfiles.firstObject as? CWNetworkProfile)
        #expect(store.profiles == ["Other"] && first.security == .wpa2Enterprise && store.commits == 0)
    }

    @Test func synchronizationVerifiesEachDomainOnlyOnceAfterWriting() throws {
        let store = FakeDefaultStore()
        store.values = [.user: old, .system: old]
        try save(store)
        #expect(store.reads == [.user, .system, .user, .system])
        #expect(store.values[.user] == new && store.values[.system] == new)
    }

    private func save(_ store: FakeDefaultStore) throws {
        try SystemDefaultSynchronizer(store: store).save(ssid: ssid, credentials: .enterprise(username: "art", password: "new-secret"))
    }

    @Test func hotspotAndOfficeCredentialsRemainIndependent() throws {
        let store = MultipleNetworkStore()
        let sync = SystemDefaultSynchronizer(store: store)
        let office = Data("Office".utf8), hotspot = Data("Home Hotspot".utf8)
        store.connectedSSID = office
        try sync.save(ssid: office, credentials: .enterprise(username: "group", password: "office-secret"))
        let officeCredential = store.values[office]
        store.connectedSSID = hotspot
        try sync.save(ssid: hotspot, credentials: .personal(password: "hotspot-secret"))
        #expect(store.values[office] == officeCredential)
        #expect(store.values[hotspot] == SystemWiFiCredential(username: nil, password: "hotspot-secret"))
        store.connectedSSID = office
        try sync.save(ssid: office, credentials: .enterprise(username: "art", password: "art-secret"))
        #expect(store.values[office] == SystemWiFiCredential(username: "art", password: "art-secret"))
        #expect(store.values[hotspot] == SystemWiFiCredential(username: nil, password: "hotspot-secret"))
    }
}

private final class MultipleNetworkStore: SystemDefaultStore {
    var connectedSSID: Data?
    var values: [Data: SystemWiFiCredential] = [:]
    func isConnected(to ssid: Data) -> Bool { connectedSSID == ssid }
    func read(ssid: Data, enterprise: Bool, domain: SystemCredentialDomain) throws -> SystemWiFiCredential? {
        domain == .user ? values[ssid] : nil
    }
    func write(_ value: SystemWiFiCredential?, ssid: Data, enterprise: Bool, domain: SystemCredentialDomain) throws {
        #expect(domain == .user)
        values[ssid] = value
    }
}

private final class FakeDefaultStore: SystemDefaultStore {
    var preferences = CWMutableConfiguration()
    var currentSecurity: CWSecurity = .wpa2Enterprise
    var values: [SystemCredentialDomain: SystemWiFiCredential] = [:]
    var connected = true
    var writes: [SystemCredentialDomain] = []
    var enterpriseCalls: [Bool] = []
    var reads: [SystemCredentialDomain] = []
    var commits = 0
    var failCommit = false, failRead = false, failSystemWrite = false, ignoreWrites = false
    var disconnectOnWrite = false, externalEditOnWrite = false, failRollback = false
    init() {
        preferences.networkProfiles = NSOrderedSet(array: ["Other", "Office"].map {
            let p = CWMutableNetworkProfile(); p.ssidData = Data($0.utf8); p.security = .wpa2Enterprise; return p
        })
    }
    var profiles: [String] { preferences.networkProfiles.array.compactMap { ($0 as? CWNetworkProfile)?.ssid } }
    func isConnected(to ssid: Data) -> Bool { connected && ssid == Data("Office".utf8) }
    func security() -> CWSecurity { currentSecurity }
    func configuration() throws -> CWConfiguration { CWConfiguration(configuration: preferences) }
    func commit(_ configuration: CWConfiguration) throws {
        commits += 1
        if failCommit { throw NSError(domain: "fake", code: -60005, userInfo: [NSLocalizedDescriptionKey: "old-secret new-secret"]) }
        preferences = CWMutableConfiguration(configuration: configuration)
    }
    func read(ssid: Data, enterprise: Bool, domain: SystemCredentialDomain) throws -> SystemWiFiCredential? {
        #expect(ssid == Data("Office".utf8))
        enterpriseCalls.append(enterprise)
        reads.append(domain)
        if failRead { throw NSError(domain: "fake", code: -1) }
        return values[domain]
    }
    func write(_ value: SystemWiFiCredential?, ssid: Data, enterprise: Bool, domain: SystemCredentialDomain) throws {
        #expect(ssid == Data("Office".utf8))
        enterpriseCalls.append(enterprise); writes.append(domain)
        if failSystemWrite && domain == .system || failRollback && writes.count > 1 { throw NSError(domain: "fake", code: -1) }
        if !ignoreWrites { values[domain] = value }
        if disconnectOnWrite { connected = false }
        if externalEditOnWrite { preferences.requireAdministratorForPower = true }
    }
}
