import Foundation
import Testing
import WiFiSwitchCore
@testable import WiFiSwitch

@MainActor
struct CurrentAccountTests {
    @Test func oneAccountConnectsToMultipleTargetsWithSamePasswordAndPairSpecificState() async throws {
        let service = MockWiFiService()
        let model = AppModel(demoMode: true, wifi: service)
        let account = try #require(model.accounts.first)
        let first = try #require(model.networks(for: account).first)
        try model.addNetwork(ssid: "Campus", to: account)
        let second = try #require(model.networks(for: account).first(where: { $0.ssid == "Campus" }))
        #expect(model.accountCount == 2)
        await model.switchAccount(account, on: first)?.value
        #expect(model.isCurrentAccount(account, on: first))
        #expect(!model.isCurrentAccount(account, on: second))
        let task = try #require(model.switchAccount(account, on: second))
        #expect(model.switchingNetworkID == second.id)
        await task.value
        #expect(model.isCurrentAccount(account, on: second))
        #expect(!model.isCurrentAccount(account, on: first))
        #expect(service.usernames == [account.username, account.username])
        #expect(service.passwords == ["demo-only", "demo-only"])
        model.unlinkNetwork(first, from: account)
        #expect(model.selectedAccount?.id == account.id)
        model.unlinkNetwork(second, from: account)
        #expect(model.selectedAccount == nil)
        #expect(model.accounts.contains(where: { $0.id == account.id }))
        #expect(model.switchAccount(account, on: second) == nil)
        #expect(service.usernames.count == 2)
    }

    @Test func completedSwitchAutomaticallyUpdatesCurrentAccountAndHistory() async throws {
        let service = MockWiFiService()
        let model = AppModel(demoMode: true, wifi: service)
        let network = try #require(model.networks.first)
        let account = network.accounts[1]

        await model.switchAccount(account, on: network)?.value

        #expect(service.usernames == [account.username])
        #expect(service.passwords == ["demo-only"])
        #expect(model.selectedAccount?.id == account.id)
        #expect(model.accountSelection?.source == .successfulSwitch)
        #expect(model.accountStatusTitle == "当前账号：测试环境")
        #expect(model.accountBadge(for: account, on: network) == "当前账号")
        #expect(model.networks[0].accounts[1].lastUsedAt != nil)
        #expect(!model.isSwitching)
    }

    @Test func secondSuccessfulSwitchReplacesFirstCurrentAccount() async throws {
        let service = MockWiFiService()
        let model = AppModel(demoMode: true, wifi: service)
        let network = try #require(model.networks.first)
        await model.switchAccount(network.accounts[0], on: network)?.value
        await model.switchAccount(network.accounts[1], on: network)?.value

        #expect(model.selectedAccount?.id == network.accounts[1].id)
        #expect(model.accountBadge(for: network.accounts[0], on: network) == nil)
        #expect(model.accountBadge(for: network.accounts[1], on: network) == "当前账号")
        #expect(!model.isCurrentAccount(network.accounts[0], on: network))
        #expect(model.isCurrentAccount(network.accounts[1], on: network))
        #expect(service.usernames == network.accounts.map(\.username))
    }

    @Test func currentAccountRejectsRedundantSwitchWithoutClearingSuccessOrReconnecting() async throws {
        let service = MockWiFiService()
        let model = AppModel(demoMode: true, wifi: service)
        let network = try #require(model.networks.first)
        let account = network.accounts[0]
        await model.switchAccount(account, on: network)?.value
        let selection = model.accountSelection
        let lastUsedAt = model.networks[0].accounts[0].lastUsedAt
        let noticeID = model.notice?.id

        #expect(model.isCurrentAccount(account, on: network))
        #expect(model.switchAccount(account, on: network) == nil)
        model.markCurrentAccount(account, on: network)

        #expect(service.usernames == [account.username])
        #expect(service.passwords.count == 1)
        #expect(model.accountSelection == selection)
        #expect(model.accountSelection?.source == .successfulSwitch)
        #expect(model.networks[0].accounts[0].lastUsedAt == lastUsedAt)
        #expect(model.notice?.id == noticeID)
        #expect(!model.isSwitching)
    }

    @Test func manualCurrentAccountAlsoRejectsSwitchUntilMarkIsCleared() async throws {
        let service = MockWiFiService()
        let model = AppModel(demoMode: true, wifi: service)
        let network = try #require(model.networks.first)
        let account = network.accounts[1]
        model.markCurrentAccount(account, on: network)

        #expect(model.isCurrentAccount(account, on: network))
        #expect(model.accountBadge(for: account, on: network) == "当前账号 · 手动标记")
        #expect(model.switchAccount(account, on: network) == nil)
        #expect(service.usernames.isEmpty)
        #expect(service.passwords.isEmpty)
        #expect(!model.isCurrentAccount(network.accounts[0], on: network))

        model.clearAccountSelection()
        #expect(!model.isCurrentAccount(account, on: network))
        let task = try #require(model.switchAccount(account, on: network))
        await task.value
        #expect(service.usernames == [account.username])
        #expect(model.accountSelection?.source == .successfulSwitch)
    }

    @Test func failedSwitchDoesNotMarkRequestedAccountOrWriteSuccessfulHistory() async throws {
        let service = MockWiFiService()
        let model = AppModel(demoMode: true, wifi: service)
        let network = try #require(model.networks.first)
        await model.switchAccount(network.accounts[0], on: network)?.value
        service.failure = WiFiError.verificationTimeout
        await model.switchAccount(network.accounts[1], on: network)?.value

        #expect(model.accountSelection == nil)
        #expect(model.networks[0].accounts[1].lastUsedAt == nil)
        #expect(model.notice?.isError == true)
    }

    @Test func systemDefaultFailureIsExplicitWithoutSuggestingWrongCredentials() async throws {
        let service = MockWiFiService()
        service.failure = SystemDefaultSyncError(stage: "保存首选 Wi-Fi", code: -60005)
        let model = AppModel(demoMode: true, wifi: service)
        let network = try #require(model.networks.first)
        await model.switchAccount(network.accounts[1], on: network)?.value
        #expect(model.accountSelection == nil)
        #expect(model.networks[0].accounts[1].lastUsedAt == nil)
        #expect(model.notice?.isError == true)
        #expect(model.notice?.text.contains("系统默认连接未同步") == true)
        #expect(model.notice?.accountEditor == nil)
    }

    @Test func pendingSwitchDoesNotMarkSuccessAndRejectsDuplicateClicks() async throws {
        let service = MockWiFiService()
        service.hold = true
        let model = AppModel(demoMode: true, wifi: service)
        let network = try #require(model.networks.first)
        let task = try #require(model.switchAccount(network.accounts[1], on: network))
        await service.waitUntilStarted()

        #expect(model.isSwitching)
        #expect(model.accountSelection == nil)
        #expect(model.switchAccount(network.accounts[0], on: network) == nil)
        await model.connectionDidChange()
        #expect(model.accountSelection == nil)
        #expect(!model.isCurrentAccount(network.accounts[1], on: network))

        service.finish()
        await task.value
        #expect(model.selectedAccount?.id == network.accounts[1].id)
        #expect(service.usernames.count == 1)
    }

    @Test func normalRefreshAndLateConnectionNotificationPreserveSuccessfulAccount() async throws {
        let service = MockWiFiService()
        let model = AppModel(demoMode: true, wifi: service)
        let network = try #require(model.networks.first)
        await model.switchAccount(network.accounts[1], on: network)?.value
        await model.refresh()
        await model.connectionDidChange()

        #expect(model.selectedAccount?.id == network.accounts[1].id)
        #expect(model.accountBadge(for: network.accounts[1], on: network) == "当前账号")
    }

    @Test func detectedDisconnectHidesCurrentAndMatchingReconnectRestoresSavedAccount() async throws {
        let service = MockWiFiService()
        let model = AppModel(demoMode: true, wifi: service)
        let network = try #require(model.networks.first)
        await model.switchAccount(network.accounts[1], on: network)?.value
        service.current.ssid = nil
        await model.connectionDidChange()
        #expect(model.accountSelection == nil)
        service.current.ssid = network.ssid
        await model.refresh()
        #expect(model.selectedAccount?.id == network.accounts[1].id)
        #expect(model.isCurrentAccount(network.accounts[1], on: network))
    }

    @Test func changedNetworkOrPoweredOffInterfaceClearsCurrentAccount() async throws {
        let service = MockWiFiService()
        let model = AppModel(demoMode: true, wifi: service)
        let network = try #require(model.networks.first)
        await model.switchAccount(network.accounts[1], on: network)?.value
        service.current.ssid = "Other"
        await model.connectionDidChange()
        #expect(model.accountSelection == nil)
        await model.switchAccount(network.accounts[1], on: network)?.value
        service.current.poweredOn = false
        await model.refresh()
        #expect(model.accountSelection == nil)
    }

    @Test func successfulReturnWithWrongFinalNetworkIsNotMarkedCurrent() async throws {
        let service = MockWiFiService()
        service.resultSSID = "Other"
        let model = AppModel(demoMode: true, wifi: service)
        let network = try #require(model.networks.first)
        await model.switchAccount(network.accounts[1], on: network)?.value
        #expect(model.accountSelection == nil)
        #expect(model.notice?.isError == true)
        #expect(model.networks[0].accounts[1].lastUsedAt == nil)
    }

    @Test func ordinaryDemoCannotConnectOrInferCurrentFromHistory() throws {
        let model = AppModel(demoMode: true)
        let network = try #require(model.networks.first)
        #expect(network.accounts[0].lastUsedAt != nil)
        #expect(model.selectedAccount == nil)
        #expect(model.switchAccount(network.accounts[1], on: network) == nil)
    }
}

@MainActor
private final class MockWiFiService: WiFiServicing {
    func reconnectAccount(ssid: String, username: String, password: String, progress: @escaping (SwitchPhase) -> Void) async throws -> WiFiReconnectResult {
        try await switchAccount(ssid: ssid, username: username, password: password, progress: progress)
        return .associated
    }
    var current = WiFiSnapshot(ssid: "Office · Enterprise", poweredOn: true, available: true, hasUsableAddress: true)
    var resultSSID: String?
    var failure: Error?
    var hold = false
    var usernames: [String] = []
    var passwords: [String] = []
    private var started: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?

    func snapshot() async -> WiFiSnapshot { current }
    func scan() async throws -> [NearbyWiFi] { [] }
    func switchAccount(ssid: String, username: String, password: String,
                       progress: @escaping (SwitchPhase) -> Void) async throws {
        usernames.append(username)
        passwords.append(password)
        progress(.disconnecting)
        progress(.authenticating)
        started?.resume()
        started = nil
        if hold { await withCheckedContinuation { pending = $0 } }
        if let failure { throw failure }
        current.ssid = resultSSID ?? ssid
        progress(.verifying)
    }

    func waitUntilStarted() async {
        if usernames.isEmpty { await withCheckedContinuation { started = $0 } }
    }

    func finish() { pending?.resume(); pending = nil }
}
