import Foundation
import Testing
import WiFiSwitchCore
@testable import WiFiSwitch

@MainActor struct SystemPasswordUpdateTests {
    @Test(arguments: [WiFiAuthentication.enterprise, .personal])
    func changedPasswordUpdatesExistingAccountWithoutReconnecting(mode: WiFiAuthentication) async throws {
        let f = try PasswordFixture(mode: mode)
        let before = f.repository.configuration.accounts[0]
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .passwordChanged)
        #expect(f.reader.reads == 0 && f.comparer.reads == 1)
        f.model.beginMenuSystemImport()
        #expect(f.model.systemImportCandidate?.updatingAccount == before)
        f.model.cancelSystemImport()
        #expect(f.vault.values[before.id] == "old-secret")
        #expect(f.model.menuNetworkStatus == .passwordChanged)
        f.model.beginMenuSystemImport()
        await f.model.confirmSystemImport(label: "must-not-rename")
        #expect(f.model.accounts == [before])
        #expect(f.model.menuNetworkStatus == .registered)
        #expect(f.vault.values[before.id] == "new-secret")
        #expect(f.reader.reads == 1 && f.wifi.connections == 0)
        #expect(f.model.systemImportCandidate == nil)
        #expect(!String(decoding: try JSONEncoder().encode(f.storage.value), as: UTF8.self).contains("new-secret"))
    }

    @Test(arguments: [WiFiAuthentication.enterprise, .personal])
    func startupAuthorizesEqualCredentialsWithoutImportWindow(mode: WiFiAuthentication) async throws {
        let f = try PasswordFixture(mode: mode)
        f.connectionGate = ConnectionCredentialVerificationGate(); f.comparer.result = .unavailable
        f.reader.value = .init(identity: f.reader.value.identity, password: "old-secret")
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .registered && f.model.systemPasswordComparison == .same)
        #expect(f.reader.reads == 1 && f.vault.writes == 1 && f.wifi.connections == 0)
        #expect(f.model.systemImportCandidate == nil)
        f.clock.date += 31; await f.model.refresh()
        #expect(f.reader.reads == 1 && f.model.menuNetworkStatus == .registered)
    }

    @Test func interactiveCheckShowsTheActualCredentialBeingRead() async throws {
        let f = try PasswordFixture()
        f.connectionGate = ConnectionCredentialVerificationGate()
        f.comparer.result = .unavailable
        f.reader.value = .init(identity: f.reader.value.identity, password: "old-secret")
        var systemStages: [CredentialAccessContext.Stage?] = []
        var accountStages: [CredentialAccessContext.Stage?] = []
        f.reader.onRead = { _ in systemStages.append(f.model.credentialAccessContext?.stage) }
        f.vault.onRead = { accountStages.append(f.model.credentialAccessContext?.stage) }
        await f.model.refresh()
        #expect(systemStages == [.systemWiFi])
        #expect(accountStages == [.appAccount])
        #expect(f.model.menuNetworkStatus == .registered)
        let system = CredentialAccessContext(ssid: "Office", accountName: "Company", username: "alice")
        var app = system; app.stage = .appAccount
        #expect(system.message.contains("系统 Wi-Fi 凭据"))
        #expect(app.message.contains("WiFi Switch 账号密码"))
        #expect(!app.message.contains("old-secret"))
    }

    @Test func overlappingRefreshesShareOneSilentComparison() async throws {
        let f = try PasswordFixture()
        f.comparer.result = .same
        f.comparer.hold = true
        let first = Task { await f.model.refresh() }
        for _ in 0..<1000 where f.comparer.continuation == nil { await Task.yield() }
        let pending = try #require(f.comparer.continuation)
        let second = Task { await f.model.refresh() }
        for _ in 0..<30 { await Task.yield() }
        #expect(f.comparer.reads == 1)
        f.comparer.hold = false; f.comparer.continuation = nil
        pending.resume()
        await first.value; await second.value
        #expect(f.comparer.reads == 1)
        #expect(f.model.menuNetworkStatus == .registered)
    }

    @Test func pendingAppAuthorizationKeepsItsAccountVisibleAndDoesNotStartAnotherRead() async throws {
        let f = try PasswordFixture()
        f.connectionGate = ConnectionCredentialVerificationGate()
        f.comparer.result = .unavailable
        f.reader.value = .init(identity: f.reader.value.identity, password: "old-secret")
        f.vault.holdAsyncRead = true
        let checking = Task { await f.model.refresh() }
        for _ in 0..<1000 where f.vault.continuation == nil { await Task.yield() }
        let pending = try #require(f.vault.continuation)
        #expect(f.model.credentialAccessContext?.stage == .appAccount)
        #expect(f.model.credentialAccessContext?.accountName == "Company")
        #expect(f.model.credentialAccessContext?.username == "alice")
        #expect(f.model.credentialAccessContext?.message.contains("不是 Wi-Fi 密码") == true)
        #expect(f.model.isVerifyingConnectionCredentials && !f.model.canEdit)
        await f.model.refresh()
        #expect(f.vault.asyncReads == 1 && f.reader.reads == 1 && f.comparer.reads == 1)
        f.vault.holdAsyncRead = false
        pending.resume()
        await checking.value
        #expect(f.model.menuNetworkStatus == .registered && f.model.credentialAccessContext == nil)
        #expect(f.vault.writes == 1 && f.wifi.connections == 0)
    }

    @Test(arguments: [SystemCredentialSource.user, .system, .standardPersonal])
    func explanationMatchesDomainBeforeSystemRead(source: SystemCredentialSource) async throws {
        let f = try PasswordFixture()
        f.connectionGate = ConnectionCredentialVerificationGate()
        f.comparer.result = .unavailable
        f.reader.value = .init(identity: f.reader.value.identity, password: "old-secret", source: source)
        f.reader.onRead = { _ in
            let context = f.model.credentialAccessContext
            #expect(context?.stage == CredentialAccessContext.Stage(source: source))
            #expect(context?.accountName == "Company" && context?.ssid == "Office" && context?.username == "alice")
            #expect(context?.message.contains("不是 Wi-Fi 密码") == true)
            if source == .system {
                #expect(context?.message.contains("管理员用户名和密码") == true)
                #expect(context?.message.contains("通常是 Mac 登录密码") == false)
            }
        }
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .registered && f.reader.reads == 1)
    }

    @Test func accountChangeDuringAppAuthorizationDiscardsTheReadBeforeReadingAgain() async throws {
        let f = try PasswordFixture()
        f.connectionGate = ConnectionCredentialVerificationGate()
        f.comparer.result = .unavailable
        f.vault.holdAsyncRead = true
        let checking = Task { await f.model.refresh() }
        for _ in 0..<1000 where f.vault.continuation == nil { await Task.yield() }
        let pending = try #require(f.vault.continuation)
        try f.repository.saveAccount(accountID: f.id, label: "Changed", username: "alice", newPassword: nil)
        f.vault.holdAsyncRead = false
        pending.resume()
        await checking.value
        #expect(f.model.systemPasswordComparison == .unavailable)
        #expect(f.reader.reads == 1 && f.vault.asyncReads == 1)
        #expect(f.vault.values[f.id] == "old-secret" && f.vault.writes == 1)
        #expect(!f.model.isVerifyingConnectionCredentials && f.model.credentialAccessContext == nil)
    }

    @Test func deniedAppAuthorizationDoesNotRepeatOrChangePasswords() async throws {
        let f = try PasswordFixture()
        f.connectionGate = ConnectionCredentialVerificationGate()
        f.comparer.result = .unavailable
        f.vault.failAsyncRead = true
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .passwordUnverified)
        for _ in 0..<3 { f.clock.date += 31; await f.model.refresh() }
        #expect(f.vault.asyncReads == 1 && f.reader.reads == 1)
        #expect(f.vault.values[f.id] == "old-secret" && f.vault.writes == 1)
        #expect(f.model.credentialAccessContext == nil && !f.model.isVerifyingConnectionCredentials)
    }

    @Test func systemRejoinDoesNotPromptForCredentialsDuringGracePeriod() async throws {
        let f = try PasswordFixture()
        f.autoReconnectEnabled = true
        f.connectionGate = ConnectionCredentialVerificationGate()
        f.comparer.result = .same
        f.reader.value = .init(identity: f.reader.value.identity, password: "old-secret")
        await f.model.refresh()
        f.wifi.ssid = nil
        await f.model.connectionDidChange()
        f.comparer.result = .unavailable
        f.wifi.ssid = "Office"
        await f.model.connectionDidChange()
        #expect(f.reader.reads == 0)
        #expect(f.model.credentialAccessContext == nil)
        #expect(f.wifi.connections == 0)
        f.clock.date += 2
        await f.model.refresh()
        #expect(f.reader.reads == 0)
        f.clock.date += 2
        await f.model.refresh()
        #expect(f.reader.reads == 1)
        #expect(f.model.menuNetworkStatus == .registered)
    }

    @Test func startupMismatchRequiresUpdateConfirmation() async throws {
        let f = try PasswordFixture()
        f.connectionGate = ConnectionCredentialVerificationGate(); f.comparer.result = .unavailable
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .passwordChanged && f.reader.reads == 2)
        #expect(f.vault.values[f.id] == "old-secret" && f.vault.writes == 1)
        #expect(f.model.systemImportCandidate == nil)
    }

    @Test func denialDoesNotLoopWithinConnectionAndRelaunchCanVerify() async throws {
        let f = try PasswordFixture()
        f.connectionGate = ConnectionCredentialVerificationGate(); f.comparer.result = .unavailable; f.reader.fail = true
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .passwordUnverified && f.model.notice?.isError == true)
        for _ in 0..<3 { f.clock.date += 31; await f.model.connectionDidChange() }
        f.connectionGate = ConnectionCredentialVerificationGate()
        let relaunched = f.makeModel(); await relaunched.refresh()
        #expect(f.reader.reads == 2 && f.vault.writes == 1)
        #expect(relaunched.menuNetworkStatus == .passwordUnverified)
        f.reader.fail = false; relaunched.beginMenuSystemImport()
        await relaunched.confirmSystemImport(label: "")
        #expect(relaunched.menuNetworkStatus == .passwordChanged)
    }

    @Test func silentStartupSuccessStillAutomaticallyChecksLaterUnreadableConnection() async throws {
        let f = try PasswordFixture()
        f.connectionGate = ConnectionCredentialVerificationGate(); f.comparer.result = .same
        await f.model.refresh()
        f.comparer.result = .unavailable; await f.model.connectionDidChange()
        #expect(f.reader.reads == 2 && f.model.menuNetworkStatus == .passwordChanged)
    }

    @Test func pendingStartupReadBlocksActionsAndDiscardsChangedNetwork() async throws {
        let f = try PasswordFixture()
        f.connectionGate = ConnectionCredentialVerificationGate(); f.comparer.result = .unavailable; f.reader.hold = true
        let pending = Task { await f.model.refresh() }
        while f.reader.continuation == nil { await Task.yield() }
        #expect(f.model.isVerifyingConnectionCredentials && !f.model.canEdit)
        #expect(f.model.credentialAccessContext?.username == "alice")
        #expect(f.model.menuNetworkStatus == .checking)
        await f.model.refresh(); #expect(f.reader.reads == 1)
        f.wifi.ssid = "Other"; await f.model.connectionDidChange()
        f.reader.hold = false; f.reader.continuation?.resume(); f.reader.continuation = nil
        await pending.value; await f.model.refresh()
        #expect(f.model.systemPasswordComparison != .same && f.model.menuNetworkStatus != .registered)
        #expect(f.reader.reads == 1 && f.vault.writes == 1)
    }

    @Test func notificationDuringDeniedReadDoesNotTriggerAnotherAuthorization() async throws {
        let f = try PasswordFixture(mode: .personal)
        f.connectionGate = ConnectionCredentialVerificationGate()
        f.comparer.result = .unavailable; f.reader.hold = true; f.reader.fail = true
        let pending = Task { await f.model.refresh() }
        while f.reader.continuation == nil { await Task.yield() }
        await f.model.connectionDidChange()
        f.reader.hold = false; f.reader.continuation?.resume(); f.reader.continuation = nil
        await pending.value
        for _ in 0..<3 { f.clock.date += 31; await f.model.connectionDidChange() }
        #expect(f.reader.reads == 1 && f.model.menuNetworkStatus == .passwordUnverified)
        #expect(f.model.credentialAccessContext == nil)
    }

    @Test func notificationDuringSuccessfulReadRetriesOnceAgainstLatestConnection() async throws {
        let f = try PasswordFixture(mode: .personal)
        f.connectionGate = ConnectionCredentialVerificationGate()
        f.reader.value = .init(identity: f.reader.value.identity, password: "old-secret")
        f.comparer.result = .unavailable; f.reader.hold = true
        let pending = Task { await f.model.refresh() }
        while f.reader.continuation == nil { await Task.yield() }
        await f.model.connectionDidChange()
        f.reader.hold = false; f.reader.continuation?.resume(); f.reader.continuation = nil
        await pending.value
        await f.model.refresh()
        #expect(f.reader.reads == 2 && f.model.menuNetworkStatus == .registered)
        #expect(f.model.credentialAccessContext == nil)
    }

    @Test func explicitAccountSwitchUsesSavedPasswordUntilExternalConnectionEvent() async throws {
        let f = try PasswordFixture()
        f.connectionGate = ConnectionCredentialVerificationGate(); f.comparer.result = .unavailable
        let id = try f.repository.saveAccount(label: "Other", username: "bob", newPassword: "other-secret",
                    networkSSIDs: ["Office"], networkAuthentications: ["Office": .enterprise])
        let model = f.model
        let account = try #require(model.accounts.first { $0.id == id })
        let network = try #require(model.networks.first { $0.ssid == "Office" })
        await model.switchAccount(account, on: network)?.value
        await model.refresh()
        #expect(f.reader.reads == 0 && f.wifi.connections == 1)
        await model.connectionDidChange()
        #expect(f.reader.reads == 2) // A subsequent external connection event rechecks the system account.
    }

    @Test func startupUnstableDifferenceStaysGrayWithoutWriting() async throws {
        let f = try PasswordFixture()
        f.connectionGate = ConnectionCredentialVerificationGate(); f.comparer.result = .unavailable
        f.reader.onRead = { count in
            if count == 2 { f.reader.value = .init(identity: f.reader.value.identity, password: "changed-during-read") }
        }
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .passwordUnverified)
        #expect(f.reader.reads == 2 && f.vault.writes == 1)
        #expect(f.vault.values[f.id] == "old-secret")
        f.reader.onRead = nil
    }

    @Test func connectionGateRetriesOnlyAfterDepartureOrSuccessfulReconnect() throws {
        let f = try PasswordFixture()
        let gate = ConnectionCredentialVerificationGate()
        let identity = f.reader.value.identity
        let account = f.repository.configuration.accounts[0]
        gate.observe(ssid: identity.ssid)
        #expect(gate.claim(identity: identity, account: account))
        gate.completed(result: .unavailable)
        gate.connectionChanged(); f.clock.date += 30
        #expect(!gate.claim(identity: identity, account: account))
        gate.observe(ssid: nil); gate.observe(ssid: identity.ssid)
        #expect(gate.claim(identity: identity, account: account))
        gate.completed(result: .same)
        gate.connectionChanged()
        #expect(gate.claim(identity: identity, account: account))
        #expect(!gate.claim(identity: identity, account: account))
    }

    @Test func hotspotReturnAutomaticallyRechecksAndShowsAccountContext() async throws {
        let f = try PasswordFixture(mode: .personal)
        f.connectionGate = ConnectionCredentialVerificationGate()
        f.comparer.result = .same
        await f.model.refresh()
        f.reader.value = .init(identity: f.reader.value.identity, password: "old-secret")
        f.comparer.result = .unavailable
        f.wifi.ssid = "Other"; await f.model.connectionDidChange()
        f.wifi.ssid = "Office"; f.reader.hold = true
        let returning = Task { await f.model.connectionDidChange() }
        while f.reader.continuation == nil { await Task.yield() }
        #expect(f.model.credentialAccessContext?.accountName == "Company")
        #expect(f.model.credentialAccessContext?.ssid == "Office")
        #expect(f.reader.prompt?.contains("Company") == true && f.reader.prompt?.contains("Office") == true)
        #expect(f.reader.prompt?.contains("old-secret") == false)
        f.reader.hold = false; f.reader.continuation?.resume(); f.reader.continuation = nil
        await returning.value
        #expect(f.model.menuNetworkStatus == .registered && f.model.credentialAccessContext == nil)
        #expect(f.reader.reads == 1 && f.vault.writes == 1)
        f.clock.date += 31; await f.model.refresh()
        #expect(f.reader.reads == 1 && f.model.menuNetworkStatus == .registered)
    }

    @Test func importedHotspotReturnChecksFreshPasswordAndDoesNotOverwriteDifference() async throws {
        let f = try PasswordFixture(mode: .personal)
        f.connectionGate = ConnectionCredentialVerificationGate()
        await f.model.refresh()
        f.model.beginMenuSystemImport(); await f.model.confirmSystemImport(label: "")
        #expect(f.model.menuNetworkStatus == .registered && f.vault.values[f.id] == "new-secret")
        f.wifi.ssid = nil; await f.model.refresh()
        f.wifi.ssid = "Office"; f.comparer.result = .unavailable
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .registered && f.reader.reads == 2)
        f.wifi.ssid = nil; await f.model.refresh()
        f.wifi.ssid = "Office"
        f.reader.value = .init(identity: f.reader.value.identity, password: "changed-again")
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .passwordChanged && f.reader.reads == 4)
        #expect(f.vault.values[f.id] == "new-secret")
    }

    @Test func unavailableBackgroundReadNeverRequestsInteractiveCredentials() async throws {
        let f = try PasswordFixture()
        f.comparer.result = .unavailable
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .passwordUnverified)
        #expect(f.reader.reads == 0 && f.vault.writes == 1)
        #expect(f.model.systemImportCandidate == nil)
        for _ in 0..<4 {
            f.clock.date += 31
            await f.model.connectionDidChange()
        }
        #expect(f.reader.reads == 0 && f.wifi.connections == 0)
    }

    @Test func notificationBurstRunsOneSilentComparison() async throws {
        let f = try PasswordFixture()
        f.eventDelay = .milliseconds(20)
        f.comparer.result = .unavailable
        async let first: Void = f.model.connectionDidChange()
        async let second: Void = f.model.connectionDidChange()
        async let third: Void = f.model.connectionDidChange()
        _ = await (first, second, third)
        #expect(f.comparer.reads == 1 && f.reader.reads == 0)
    }

    @Test(arguments: [WiFiAuthentication.enterprise, .personal])
    func updateRemainsSavedWhenExpiredBackgroundCheckCannotRead(mode: WiFiAuthentication) async throws {
        let f = try PasswordFixture(mode: mode)
        await f.model.refresh()
        f.model.beginMenuSystemImport()
        await f.model.confirmSystemImport(label: "")
        let writes = f.vault.writes
        #expect(f.model.menuNetworkStatus == .registered)
        f.comparer.result = .unavailable
        f.clock.date += 29
        await f.model.refresh()
        #expect(f.comparer.reads == 1 && f.model.menuNetworkStatus == .registered)
        f.clock.date += 1
        await f.model.refresh()
        #expect(f.comparer.reads == 2)
        #expect(f.model.systemPasswordComparison == .same)
        #expect(f.model.menuNetworkStatus == .registered)
        #expect(f.vault.values[f.id] == "new-secret" && f.vault.writes == writes)
        f.model.beginMenuSystemImport()
        #expect(f.model.systemImportCandidate == nil)
        await f.model.confirmSystemImport(label: "")
        #expect(f.model.menuNetworkStatus == .registered && f.model.systemImportCandidate == nil)
        #expect(f.vault.writes == writes) // A second write is neither necessary nor attempted.
        #expect(f.reader.reads == 1)
        f.comparer.result = .same
        f.clock.date += 31
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .registered && f.comparer.reads == 3)
        // A real later password change must still be detected; the cache cannot pin green forever.
        f.comparer.result = .different
        f.clock.date += 31
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .passwordChanged && f.comparer.reads == 4)
        #expect(f.vault.writes == writes && f.wifi.connections == 0)
    }

    @Test func reconnectInvalidatesImportedEquality() async throws {
        let f = try PasswordFixture(mode: .personal)
        await f.model.refresh()
        f.model.beginMenuSystemImport()
        await f.model.confirmSystemImport(label: "")
        f.reader.value = .init(identity: f.reader.value.identity, password: "changed-again")
        f.comparer.result = .unavailable
        await f.model.connectionDidChange()
        #expect(f.model.menuNetworkStatus == .passwordUnverified)
        #expect(f.reader.reads == 1)
        #expect(f.vault.values[f.id] == "new-secret")
    }

    @Test func readRecoveryRestoresNormalWithoutASecondUserUpdate() async throws {
        let f = try PasswordFixture()
        await f.model.refresh()
        f.model.beginMenuSystemImport()
        await f.model.confirmSystemImport(label: "")
        let writes = f.vault.writes
        f.comparer.result = .unavailable
        f.clock.date += 30
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .registered)
        f.comparer.result = .same
        f.clock.date += 30
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .registered)
        #expect(f.reader.reads == 1 && f.vault.writes == writes && f.wifi.connections == 0)
    }

    @Test func firstUnknownHotspotImportStaysVerifiedAfterSilentReadDenial() async throws {
        let f = try PasswordFixture(mode: .personal)
        try f.repository.deleteAccount(accountID: f.id)
        f.comparer.result = .unavailable
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .unregistered)
        f.model.beginMenuSystemImport()
        await f.model.confirmSystemImport(label: "My hotspot")
        let imported = try #require(f.model.accounts.first)
        let writes = f.vault.writes
        f.clock.date += 33
        f.reader.fail = true
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .registered)
        #expect(f.model.systemImportCandidate == nil)
        #expect(f.reader.reads == 1 && f.vault.writes == writes)
        #expect(f.vault.values[imported.id] == "new-secret")
    }

    @Test func connectionChangeDuringSilentComparisonDiscardsOldEquality() async throws {
        let f = try PasswordFixture()
        f.comparer.result = .same
        f.comparer.hold = true
        let pending = Task { await f.model.refresh() }
        while f.comparer.continuation == nil { await Task.yield() }
        f.wifi.ssid = nil
        await f.model.connectionDidChange()
        f.comparer.continuation?.resume()
        await pending.value
        #expect(f.model.menuNetworkStatus == .disconnected)
        #expect(f.model.systemPasswordComparison == nil)
        #expect(f.reader.reads == 0 && f.vault.writes == 1)
    }

    @Test func explicitTwoStepImportReusesAuthorizedSnapshot() async throws {
        let f = try PasswordFixture()
        f.comparer.result = .unavailable
        await f.model.refresh()
        f.model.beginSystemImport(updating: f.model.accounts[0])
        await f.model.confirmSystemImport(label: "")
        #expect(f.model.systemImportCandidate?.differenceConfirmed == true)
        #expect(f.reader.reads == 1)
        await f.model.confirmSystemImport(label: "")
        #expect(f.reader.reads == 1)
        #expect(f.vault.values[f.id] == "new-secret")
    }

    @Test func expiredImportSnapshotRequiresFreshExplicitRead() async throws {
        let f = try PasswordFixture()
        f.comparer.result = .unavailable
        await f.model.refresh()
        f.model.beginSystemImport(updating: f.model.accounts[0])
        await f.model.confirmSystemImport(label: "")
        f.clock.date += 31
        await f.model.confirmSystemImport(label: "")
        #expect(f.reader.reads == 2)
    }

    @Test func cancelDiscardsAuthorizedImportSnapshot() async throws {
        let f = try PasswordFixture()
        f.comparer.result = .unavailable
        await f.model.refresh()
        f.model.beginSystemImport(updating: f.model.accounts[0])
        await f.model.confirmSystemImport(label: "")
        f.model.cancelSystemImport()
        f.model.beginSystemImport(updating: f.model.accounts[0])
        await f.model.confirmSystemImport(label: "")
        #expect(f.reader.reads == 2)
    }

    @Test func connectionEventDiscardsPendingImportSnapshot() async throws {
        let f = try PasswordFixture()
        f.comparer.result = .unavailable
        await f.model.refresh()
        f.model.beginSystemImport(updating: f.model.accounts[0])
        await f.model.confirmSystemImport(label: "")
        await f.model.connectionDidChange()
        await f.model.confirmSystemImport(label: "")
        #expect(f.reader.reads == 2)
    }

    @Test func editorReadsOnlyTheApplicationsSavedPassword() async throws {
        let f = try PasswordFixture(mode: .personal)
        f.comparer.result = .unavailable
        await f.model.refresh()
        let value = try f.model.savedPassword(for: .init(account: f.model.accounts[0]))
        #expect(value == "old-secret")
        #expect(f.reader.reads == 0 && f.wifi.connections == 0)
    }

    @Test func ownSwitchNotificationsDoNotStartCompetingCredentialChecks() async throws {
        let f = try PasswordFixture(mode: .personal)
        f.comparer.result = .unavailable
        f.wifi.onSwitch = {
            for _ in 0..<3 { await f.model.connectionDidChange() }
        }
        let account = try #require(f.model.accounts.first)
        let network = try #require(f.model.networks.first(where: { $0.ssid == "Office" }))
        await f.model.switchAccount(account, on: network)?.value
        #expect(f.model.menuNetworkStatus == .registered)
        #expect(f.reader.reads == 0 && f.comparer.reads == 0)
        #expect(f.wifi.connections == 1)
    }

    @Test func grayMenuActionVerifiesEqualCredentialsWithoutRewriting() async throws {
        let f = try PasswordFixture()
        f.comparer.result = .unavailable
        f.reader.value = .init(identity: f.reader.value.identity, password: "old-secret")
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .passwordUnverified)
        #expect(f.model.canAddMenuSystemConnection && f.reader.reads == 0)
        var savedReads = 0
        f.vault.onRead = { savedReads += 1 }
        f.model.beginMenuSystemImport()
        #expect(f.model.systemImportCandidate?.isPasswordVerification == true)
        #expect(f.reader.reads == 0) // Opening is not consent to read.
        await f.model.confirmSystemImport(label: "")
        #expect(f.model.menuNetworkStatus == .registered)
        #expect(f.model.systemImportCandidate == nil)
        #expect(f.reader.reads == 1 && f.vault.writes == 1)
        #expect(savedReads == 1)
    }

    @Test func grayMenuCancelAndDenialStayGrayAndDifferenceNeedsUpdate() async throws {
        let f = try PasswordFixture(mode: .personal)
        f.comparer.result = .unavailable
        await f.model.refresh()
        f.model.beginMenuSystemImport()
        f.model.cancelSystemImport()
        #expect(f.model.menuNetworkStatus == .passwordUnverified && f.reader.reads == 0)
        f.model.beginMenuSystemImport()
        f.reader.fail = true
        await f.model.confirmSystemImport(label: "")
        #expect(f.model.menuNetworkStatus == .passwordUnverified)
        #expect(f.model.systemImportError != nil && f.vault.writes == 1)
        f.reader.fail = false
        await f.model.confirmSystemImport(label: "")
        #expect(f.model.menuNetworkStatus == .passwordChanged)
        #expect(f.model.systemImportCandidate?.isPasswordUpdate == true)
        #expect(f.vault.values[f.id] == "old-secret")
        await f.model.confirmSystemImport(label: "")
        #expect(f.model.menuNetworkStatus == .registered)
        #expect(f.vault.values[f.id] == "new-secret")
        #expect(f.reader.reads == 2) // Failed read + successful read; update reuses the snapshot.
    }

    @Test func savedValueMustBeReadBackBeforeReportingSuccess() async throws {
        let f = try PasswordFixture()
        await f.model.refresh()
        f.model.beginMenuSystemImport()
        f.vault.ignoreWrites = true
        await f.model.confirmSystemImport(label: "")
        #expect(f.model.systemImportError?.contains("保存后的密码未能核验") == true)
        #expect(f.model.menuNetworkStatus != .registered)
        #expect(f.vault.values[f.id] == "old-secret")
        #expect(f.model.systemImportCandidate != nil)
    }

    @Test func importedSourceIsPassedToLaterComparisonsAndClearedOnDisconnect() async throws {
        let f = try PasswordFixture()
        f.reader.value.source = .user
        await f.model.refresh()
        #expect(f.comparer.expectedSource == nil)
        f.model.beginMenuSystemImport()
        await f.model.confirmSystemImport(label: "")
        f.clock.date += 30
        f.comparer.result = .same
        await f.model.refresh()
        #expect(f.comparer.expectedSource == .user)
        // A fast reconnect can finish before polling observes a disconnected snapshot.
        await f.model.connectionDidChange()
        #expect(f.comparer.expectedSource == nil)
        f.wifi.ssid = nil
        await f.model.refresh()
        f.wifi.ssid = "Office"
        await f.model.refresh()
        #expect(f.comparer.expectedSource == nil)
    }

    @Test func staleDifferenceCannotOverwriteSuccessfulPasswordUpdate() async throws {
        let f = try PasswordFixture()
        await f.model.refresh()
        f.model.beginMenuSystemImport()
        f.clock.date += 31
        f.comparer.hold = true
        let pending = Task { await f.model.refresh() }
        while f.comparer.continuation == nil { await Task.yield() }
        await f.model.confirmSystemImport(label: "")
        f.comparer.continuation?.resume() // Returns the old "different" result after the save.
        await pending.value
        #expect(f.model.systemPasswordComparison == .same)
        #expect(f.model.menuNetworkStatus == .registered)
        #expect(f.vault.values[f.id] == "new-secret" && f.vault.writes == 2)
        await f.model.refresh()
        #expect(f.comparer.reads == 2 && f.model.menuNetworkStatus == .registered)
    }

    @Test func pollingDuringInteractiveUpdateDoesNotPublishAnOlderSnapshot() async throws {
        let f = try PasswordFixture()
        await f.model.refresh()
        f.model.beginMenuSystemImport()
        f.reader.hold = true
        let updating = Task { await f.model.confirmSystemImport(label: "") }
        while f.reader.continuation == nil { await Task.yield() }
        let snapshotReads = f.wifi.snapshotReads
        await f.model.refresh()
        #expect(f.wifi.snapshotReads == snapshotReads && f.comparer.reads == 1)
        f.reader.continuation?.resume()
        await updating.value
        #expect(f.model.menuNetworkStatus == .registered && f.vault.values[f.id] == "new-secret")
    }

    @Test func silentComparisonCacheExpiresOnConnectionEventAndExplicitSessionIsPreserved() async throws {
        let f = try PasswordFixture()
        await f.model.refresh()
        await f.model.refresh()
        #expect(f.comparer.reads == 1)
        f.comparer.result = .same
        await f.model.connectionDidChange()
        #expect(f.comparer.reads == 2 && f.model.menuNetworkStatus == .registered)
        let task = try #require(f.model.reconnectAccount(f.model.accounts[0], on: f.model.networks[0]))
        await task.value
        f.comparer.result = .different
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .registered)
        #expect(f.comparer.reads == 2)
        #expect(f.wifi.connections == 1)
    }

    @Test(arguments: ["cancel", "network", "identity", "account", "storage", "denied"])
    func failuresNeverOverwriteSavedSecretOrDuplicateAccount(reason: String) async throws {
        let f = try PasswordFixture()
        await f.model.refresh()
        f.model.beginMenuSystemImport()
        f.reader.hold = true
        let task = Task { await f.model.confirmSystemImport(label: "") }
        while f.reader.continuation == nil { await Task.yield() }
        switch reason {
        case "cancel": f.model.cancelSystemImport()
        case "network": f.wifi.ssid = "Other"
        case "identity": f.reader.value = .init(identity: .init(ssid: "Office", authentication: .enterprise, username: "different-user"), password: "new-secret")
        case "account": try f.repository.saveAccount(accountID: f.id, label: "Changed", username: "alice", newPassword: nil)
        case "storage": f.storage.fail = true
        case "denied": f.reader.fail = true
        default: break
        }
        f.reader.continuation?.resume()
        await task.value
        #expect(f.vault.values[f.id] == "old-secret")
        #expect(f.repository.configuration.accounts.count == 1)
        #expect(f.wifi.connections == 0)
        if reason != "cancel" { #expect(f.model.systemImportError != nil) }
    }

    @Test func staleComparisonCannotPublishAfterNetworkChange() async throws {
        let f = try PasswordFixture()
        f.comparer.hold = true
        let task = Task { await f.model.refresh() }
        while f.comparer.continuation == nil { await Task.yield() }
        f.wifi.ssid = nil
        await f.model.refresh()
        f.comparer.continuation?.resume()
        await task.value
        #expect(f.model.menuNetworkStatus == .disconnected)
        #expect(f.model.systemPasswordComparison == nil)
    }

    @Test(arguments: [false, true])
    func existingEnterpriseAccountGetsNewWiFiInsteadOfDuplicate(changedPassword: Bool) async throws {
        let f = try PasswordFixture()
        f.wifi.ssid = "Branch"
        f.reader.value = .init(identity: .init(ssid: "Branch", authentication: .enterprise, username: "alice"),
                               password: changedPassword ? "new-secret" : "old-secret")
        await f.model.refresh()
        #expect(f.model.menuNetworkStatus == .unregistered)
        #expect(f.model.systemImportCandidate?.linkingNetwork == true)
        #expect(f.model.systemImportCandidate?.updatingAccount?.id == f.id)
        await f.model.confirmSystemImport(label: "")
        if changedPassword {
            #expect(f.model.systemImportCandidate?.differenceConfirmed == true)
            #expect(f.model.systemImportCandidate?.isPasswordUpdate == true)
            #expect(f.repository.configuration.networks.count == 2)
            #expect(f.vault.values[f.id] == "old-secret")
            await f.model.confirmSystemImport(label: "")
        }
        #expect(f.model.accounts.count == 1)
        #expect(f.model.accounts[0].id == f.id && f.model.accounts[0].label == "Company")
        #expect(f.model.accounts[0].networkIDs.count == 3)
        #expect(Set(f.model.networks.map(\.ssid)) == ["Office", "Backup", "Branch"])
        #expect(f.model.menuNetworkStatus == .registered && f.model.systemImportCandidate == nil)
        #expect(f.vault.values[f.id] == (changedPassword ? "new-secret" : "old-secret"))
        #expect(f.wifi.connections == 0)
    }

    @Test func linkingFailureRollsBackPasswordAndAssociationTogether() async throws {
        let f = try PasswordFixture()
        f.wifi.ssid = "Branch"
        f.reader.value = .init(identity: .init(ssid: "Branch", authentication: .enterprise, username: "alice"), password: "new-secret")
        await f.model.refresh()
        await f.model.confirmSystemImport(label: "")
        f.storage.fail = true
        await f.model.confirmSystemImport(label: "")
        #expect(f.vault.values[f.id] == "old-secret")
        #expect(f.repository.configuration.networks.count == 2)
        #expect(f.model.systemImportError != nil)
    }

    @Test(arguments: [WiFiAuthentication.enterprise, .personal])
    func newIdentityCreatesNewAccountAndPersonalNeverGuessesByEqualPassword(mode: WiFiAuthentication) async throws {
        let f = try PasswordFixture(mode: mode)
        f.wifi.ssid = "New WiFi"
        f.reader.value = .init(identity: .init(ssid: "New WiFi", authentication: mode,
            username: mode == .enterprise ? "bob" : nil), password: "old-secret")
        await f.model.refresh()
        #expect(f.model.systemImportCandidate?.updatingAccount == nil)
        await f.model.confirmSystemImport(label: "New account")
        #expect(f.model.accounts.count == 2)
        let created = try #require(f.model.accounts.first { $0.id != f.id })
        #expect(created.networkIDs.count == 1 && created.label == "New account")
        #expect(f.model.accounts.first(where: { $0.id == f.id })?.networkIDs.count == 2)
    }

    @Test func conflictingUsernamesAcrossAccountsNeverPickArbitraryTarget() async throws {
        let f = try PasswordFixture()
        try f.repository.saveAccount(label: "Other account", username: "alice", newPassword: "other", networkSSIDs: ["Elsewhere"])
        let model = f.makeModel()
        f.wifi.ssid = "New WiFi"
        f.reader.value = .init(identity: .init(ssid: "New WiFi", authentication: .enterprise, username: "alice"), password: "new-secret")
        await model.refresh()
        model.beginSystemImport()
        await model.confirmSystemImport(label: "No duplicate")
        #expect(model.systemImportError != nil)
        #expect(f.repository.configuration.accounts.count == 2)
        #expect(!f.repository.configuration.networks.contains { $0.ssid == "New WiFi" })
    }

    @Test func comparisonReportsOnlyEqualityAndFailsClosedOnIdentityOrReadError() throws {
        let identity = SystemConnectionIdentity(ssid: "Office", authentication: .enterprise, username: "alice")
        let request = SystemCredentialComparisonRequest(identity: identity, accountID: UUID())
        let configuration = SystemConnectionConfiguration(identity: identity, password: "secret-a")
        #expect(SystemCredentialComparator.compare(request: request, system: { configuration }, savedPassword: { "secret-a" }) == .same)
        #expect(SystemCredentialComparator.compare(request: request, system: { configuration }, savedPassword: { "secret-b" }) == .different)
        #expect(SystemCredentialComparator.compare(request: request, system: { configuration }, savedPassword: { nil }) == .unavailable)
        #expect(SystemCredentialComparator.compare(request: request, system: { throw SystemImportError.unavailable }, savedPassword: { "secret-a" }) == .unavailable)
        let wrong = SystemConnectionConfiguration(identity: .init(ssid: "Office", authentication: .enterprise, username: "bob"), password: "secret-a")
        #expect(SystemCredentialComparator.compare(request: request, system: { wrong }, savedPassword: { "secret-a" }) == .unavailable)
        let wire = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!wire.contains("secret") && !wire.contains("password"))
        #expect(String(decoding: try JSONEncoder().encode(SystemCredentialComparison.different), as: UTF8.self) == "\"different\"")
    }
}

@MainActor private final class PasswordFixture {
    let storage = PasswordStorage()
    let vault = PasswordVault()
    let clock = PasswordClock()
    let wifi = PasswordWiFi()
    let reader = PasswordReader()
    let comparer = PasswordComparer()
    var connectionGate: ConnectionCredentialVerificationGate?
    var eventDelay: Duration = .zero
    var autoReconnectEnabled = false
    let repository: AccountRepository
    let id: UUID
    lazy var model = makeModel()
    init(mode: WiFiAuthentication = .enterprise) throws {
        repository = try AccountRepository(storage: storage, vault: vault)
        id = try repository.saveAccount(label: "Company", username: mode == .enterprise ? "alice" : "", newPassword: "old-secret",
            networkSSIDs: ["Office", "Backup"], networkAuthentications: ["Office": mode, "Backup": mode])
        reader.value = .init(identity: .init(ssid: "Office", authentication: mode, username: mode == .enterprise ? "alice" : nil), password: "new-secret")
    }
    func makeModel() -> AppModel {
        AppModel(demoMode: true, wifi: wifi, repository: repository, automaticReconnectEnabled: autoReconnectEnabled,
                 systemReader: reader, credentialComparator: comparer, passwordCheckDate: { [clock] in clock.date },
                 connectionEventDelay: eventDelay, connectionVerificationGate: connectionGate, syncPreferenceDecision: { _, _ in false })
    }
}
private final class PasswordClock {
    var date = Date(timeIntervalSince1970: 100)
}
private final class PasswordVault: CredentialVault {
    var values: [UUID: String] = [:]
    var writes = 0
    var ignoreWrites = false
    var onRead: (() -> Void)?
    var asyncReads = 0, holdAsyncRead = false, failAsyncRead = false
    var continuation: CheckedContinuation<Void, Never>?
    @MainActor func readPassword(for accountID: UUID) async throws -> String? {
        asyncReads += 1
        if holdAsyncRead { await withCheckedContinuation { continuation = $0 } }
        if failAsyncRead { throw SystemImportError.unavailable }
        return password(for: accountID)
    }
    func password(for accountID: UUID) -> String? { onRead?(); return values[accountID] }
    func setPassword(_ password: String, for accountID: UUID) { writes += 1; if !ignoreWrites { values[accountID] = password } }
    func deletePassword(for accountID: UUID) { values.removeValue(forKey: accountID) }
}
private final class PasswordStorage: ConfigurationStorage {
    var value = AccountConfiguration()
    var fail = false
    func load() -> AccountConfiguration { value }
    func save(_ configuration: AccountConfiguration) throws {
        if fail { throw SystemImportError.storage }
        value = configuration
    }
}
private final class PasswordReader: SystemConnectionReading {
    var value = SystemConnectionConfiguration(identity: .init(ssid: "Office", authentication: .enterprise, username: "alice"), password: "new-secret")
    var prompt: String?
    func configuration(ssid: String, authorizationPrompt: String,
                       prepareAccess: @escaping @MainActor (SystemCredentialSource) async throws -> Void) async throws -> SystemConnectionConfiguration {
        try await prepareAccess(value.source ?? .user)
        return try await configuration(ssid: ssid, authorizationPrompt: authorizationPrompt)
    }
    func configuration(ssid: String, authorizationPrompt: String) async throws -> SystemConnectionConfiguration {
        prompt = authorizationPrompt
        return try await configuration(ssid: ssid)
    }
    var onRead: ((Int) -> Void)?
    var reads = 0, fail = false, hold = false
    var continuation: CheckedContinuation<Void, Never>?
    func identity(ssid: String) async -> SystemConnectionIdentity? { value.identity }
    func configuration(ssid: String) async throws -> SystemConnectionConfiguration {
        reads += 1
        onRead?(reads)
        if hold { await withCheckedContinuation { continuation = $0 } }
        if fail { throw SystemImportError.unavailable }
        return value
    }
}
private final class PasswordComparer: SystemCredentialComparing {
    var result = SystemCredentialComparison.different
    var reads = 0, hold = false
    var continuation: CheckedContinuation<Void, Never>?
    var expectedSource: SystemCredentialSource?
    func compare(identity: SystemConnectionIdentity, accountID: UUID, expectedSource: SystemCredentialSource?) async -> SystemCredentialComparison {
        self.expectedSource = expectedSource
        return await compare(identity: identity, accountID: accountID)
    }
    func compare(identity: SystemConnectionIdentity, accountID: UUID) async -> SystemCredentialComparison {
        reads += 1
        if hold { await withCheckedContinuation { continuation = $0 } }
        return result
    }
}
private final class PasswordWiFi: WiFiServicing {
    var ssid: String? = "Office"
    var connections = 0
    var snapshotReads = 0
    var onSwitch: (() async -> Void)?
    func snapshot() async -> WiFiSnapshot {
        snapshotReads += 1
        return .init(ssid: ssid, poweredOn: true, available: true, hasUsableAddress: ssid != nil)
    }
    func scan() async throws -> [NearbyWiFi] { [] }
    func switchAccount(ssid: String, username: String, password: String, progress: @escaping (SwitchPhase) -> Void) async throws { connections += 1; self.ssid = ssid; await onSwitch?() }
    func switchAccount(ssid: String, username: String, password: String, synchronizeSystemCredentials: Bool,
                       progress: @escaping (SwitchPhase) -> Void) async throws {
        try await switchAccount(ssid: ssid, username: username, password: password, progress: progress)
    }
    func reconnectAccount(ssid: String, username: String, password: String, progress: @escaping (SwitchPhase) -> Void) async throws -> WiFiReconnectResult { connections += 1; self.ssid = ssid; return .associated }
}
