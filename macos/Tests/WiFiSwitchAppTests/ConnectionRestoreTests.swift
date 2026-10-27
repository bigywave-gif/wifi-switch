import Foundation
import CoreWLAN
import Testing
import WiFiSwitchCore
@testable import WiFiSwitch

@MainActor
struct ConnectionRestoreTests {
    @Test(arguments: [true, false])
    func completedAssociationUsesRequestedAccountRegardlessOfSystemDefault(sameDefault: Bool) async throws {
        let f = try RestoreFixture()
        let reader = RecoveryIdentityReader()
        reader.username = sameDefault ? f.second.username : f.first.username
        let model = try f.model(reader: reader)
        await model.switchAccount(f.second, on: f.network)?.value
        #expect(model.menuNetworkStatus == .registered)
        #expect(model.connectionAccountLabel == "Studio")
        #expect(model.notice?.text.contains("当前账号：Studio") == true)
        #expect(f.service.lastUsername == f.second.username)
        #expect(model.connectionEvidence?.requestedUsername == f.second.username)
        #expect(model.connectionEvidence?.savedUsername == reader.username)
        #expect(model.connectionEvidence?.savedAccount == (sameDefault ? "Studio" : "Group"))
        #expect(!model.canAddMenuSystemConnection)
        #expect(!model.menuNetworkStatus.hasSystemConfigurationAction)
        await model.refresh()
        #expect(model.menuNetworkStatus == .registered)
        #expect(model.systemImportCandidate == nil && model.systemPasswordComparison == nil)
        #expect(try f.storage.load().currentConnection?.accountID == f.second.id)
    }

    @Test func unreadableSystemDefaultDoesNotInvalidateCompletedAssociation() async throws {
        let f = try RestoreFixture()
        let reader = RecoveryIdentityReader()
        let model = try f.model(reader: reader)
        await model.switchAccount(f.second, on: f.network)?.value
        #expect(model.menuNetworkStatus == .registered)
        #expect(model.connectionEvidence?.savedUsername == nil)
        #expect(model.connectionEvidence?.detail.contains("暂未读取到") == true)
        #expect(reader.configurationReads == 0)
        f.service.current.ssid = nil
        await model.refresh()
        #expect(model.menuNetworkStatus == .disconnected)
        #expect(model.connectionEvidence == nil)
    }

    @Test func evidenceReadCannotFollowAnExpiredConnection() async throws {
        let f = try RestoreFixture()
        let reader = RecoveryIdentityReader()
        reader.username = f.first.username
        let model = try f.model(reader: reader)
        await model.switchAccount(f.second, on: f.network)?.value
        reader.hold = true
        let task = Task { await model.refreshConnectionEvidence() }
        for _ in 0..<100 {
            if reader.continuation != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let pending = try #require(reader.continuation)
        f.service.current.ssid = nil
        await model.refresh()
        reader.hold = false; reader.continuation = nil; pending.resume()
        await task.value
        #expect(model.connectionEvidence == nil && model.notice == nil)
        #expect(model.menuNetworkStatus == .disconnected)
    }

    @Test func missingAddressAfterAssociationDoesNotReportSuccess() async throws {
        let f = try RestoreFixture()
        f.service.usableAddressAfterAssociation = false
        let model = try f.model()
        await model.switchAccount(f.second, on: f.network)?.value
        #expect(model.menuNetworkStatus != .registered)
        #expect(model.connectedAccountID == nil)
        #expect(model.notice?.isError == true)
        #expect(model.notice?.text.contains("连接成功") == false)
    }

    @Test(arguments: [true, false])
    func applicationAssociationRequiresInternetForGreen(reachable: Bool) async throws {
        let f = try RestoreFixture()
        let checker = FixedInternet(result: reachable)
        let model = try f.model(internet: checker)
        await model.switchAccount(f.second, on: f.network)?.value
        for _ in 0..<1000 {
            if model.internetStatus != .checking { break }
            await Task.yield()
        }
        #expect(model.connectedAccountID == f.second.id)
        #expect(model.menuNetworkStatus == (reachable ? .registered : .internetUnavailable))
    }

    @Test func recoveryTargetDoesNotBecomeConfirmedAccountAndNoticeFollowsSystemIdentity() async throws {
        let f = try RestoreFixture()
        f.service.recoveryResult = .systemRecovered
        let reader = RecoveryIdentityReader()
        reader.username = f.first.username
        let model = try f.model(automaticReconnect: true, reader: reader)
        await model.switchAccount(f.second, on: f.network)?.value
        reader.hold = true
        f.service.current.hasUsableAddress = false
        await model.refresh()
        for _ in 0..<100 {
            if reader.continuation != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let pending = try #require(reader.continuation)
        #expect(f.service.reconnections == 1)
        #expect(f.service.authentications == 1)
        #expect(f.service.lastUsername == f.second.username)
        #expect(model.connectedAccountID == nil)
        #expect(model.notice?.text.contains("正在确认") == true)
        #expect(model.notice?.text.contains("Studio") == false)
        reader.hold = false; reader.continuation = nil; pending.resume()
        for _ in 0..<100 {
            if model.notice?.connection != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(model.connectedAccountID == f.first.id)
        #expect(model.notice?.text.contains("Group") == true)
        #expect(model.notice?.text.contains("Studio") == false)
        #expect(try f.storage.load().currentConnection?.accountID == f.first.id)
        // A later system change invalidates only the stale success notice.
        reader.username = f.second.username
        await model.connectionDidChange()
        #expect(model.connectedAccountID == f.second.id && model.notice == nil)
        model.notice = AppNotice(text: "Unrelated persistence error", isError: true)
        reader.username = f.first.username
        await model.refresh()
        #expect(model.notice?.text == "Unrelated persistence error")
    }

    @Test func recoveredNetworkWithUnknownIdentityNeverClaimsTargetAccount() async throws {
        let f = try RestoreFixture()
        f.service.recoveryResult = .systemRecovered
        let reader = RecoveryIdentityReader()
        let model = try f.model(automaticReconnect: true, reader: reader)
        await model.switchAccount(f.second, on: f.network)?.value
        f.service.current.hasUsableAddress = false; await model.refresh()
        for _ in 0..<100 {
            if model.notice?.text.contains("尚未确认") == true { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(model.connectedAccountID == nil)
        #expect(model.notice?.text.contains("尚未确认") == true)
        #expect(model.notice?.text.contains("Studio") == false)
        f.service.current.ssid = "Other"
        await model.refresh()
        #expect(model.notice == nil)
    }

    @Test func manualSuccessNoticeExpiresWhenSystemSelectsAnotherAccount() async throws {
        let f = try RestoreFixture()
        let reader = RecoveryIdentityReader()
        reader.username = f.first.username
        let model = try f.model(reader: reader)
        await model.switchAccount(f.second, on: f.network)?.value
        #expect(model.notice?.text.contains("Studio") == true)
        await model.connectionDidChange()
        #expect(model.connectedAccountID == f.first.id)
        #expect(model.notice == nil)
    }

    @Test func applicationRecoveryRetainsLastAccountEvenWhenSystemDefaultIsDifferent() async throws {
        let f = try RestoreFixture()
        let reader = RecoveryIdentityReader()
        reader.username = f.first.username // Saved system default, not the application's live session.
        let model = try f.model(automaticReconnect: true, reader: reader)
        await model.switchAccount(f.second, on: f.network)?.value
        f.service.current.hasUsableAddress = false
        await model.refresh()
        for _ in 0..<100 {
            if f.service.reconnections == 1 && !model.isSwitching { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(f.service.lastUsername == f.second.username)
        #expect(model.connectedAccountID == f.second.id)
        #expect(model.notice?.text.contains("重新连接成功，当前账号：Studio") == true)
        #expect(model.menuNetworkStatus == .registered)
        #expect(model.connectionEvidence?.automatic == true)
        #expect(model.connectionEvidence?.savedAccount == "Group")
        await model.refresh()
        #expect(model.connectedAccountID == f.second.id)
        #expect(try f.storage.load().currentConnection?.accountID == f.second.id)
    }

    @Test func powerCycleLeavesSystemInControlUntilItJoins() async throws {
        let f = try RestoreFixture()
        let reader = RecoveryIdentityReader()
        reader.username = f.first.username
        let model = try f.model(automaticReconnect: true, reader: reader)
        await model.switchAccount(f.second, on: f.network)?.value
        f.service.current.poweredOn = false
        f.service.current.ssid = nil
        await model.connectionDidChange()
        f.service.current.poweredOn = true
        await model.connectionDidChange()
        try await Task.sleep(for: .milliseconds(30))
        #expect(f.service.reconnections == 0)
        f.service.current.ssid = f.network.ssid
        f.service.current.hasUsableAddress = true
        await model.connectionDidChange()
        #expect(f.service.reconnections == 0)
        #expect(model.connectedAccountID == f.first.id)
        #expect(model.notice == nil)
    }

    @Test func informationAccessFollowsOnlyTheConfirmedAccountAndNetwork() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        await model.refresh()
        #expect(!model.canViewWiFiInformation(for: fixture.first, on: fixture.network))
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        #expect(model.canViewWiFiInformation(for: fixture.first, on: fixture.network))
        #expect(!model.canViewWiFiInformation(for: fixture.second, on: fixture.network))
        #expect(!model.canViewWiFiInformation(for: fixture.first, on: SavedWiFi(ssid: "Other", accounts: [fixture.first])))
        await model.switchAccount(fixture.second, on: fixture.network)?.value
        #expect(!model.canViewWiFiInformation(for: fixture.first, on: fixture.network))
        #expect(model.canViewWiFiInformation(for: fixture.second, on: fixture.network))
    }

    @Test func informationAccessIsRevokedWhenConnectionIsLost() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        fixture.service.current.ssid = nil
        fixture.service.current.hasUsableAddress = false
        await model.refresh()
        #expect(!model.canViewWiFiInformation(for: fixture.first, on: fixture.network))
    }

    @Test(arguments: [1, -3912, -3924])
    func firstAuthenticationFailureStopsAutomaticRetryAndOffersEditing(code: Int) async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model(automaticReconnect: true)
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        let saved = try fixture.storage.load().currentConnection
        fixture.service.current.hasUsableAddress = false
        fixture.service.connectionError = NSError(domain: CWErrorDomain, code: code)
        await model.refresh()
        for _ in 0..<2000 {
            if model.automaticReconnectNeedsCredentialReview && !model.isSwitching { break }
            await Task.yield()
        }
        let reads = fixture.vault.reads
        for _ in 0..<20 { await model.refresh(); await Task.yield() }
        #expect(fixture.service.reconnections == 1)
        #expect(model.automaticReconnectFailures == 1)
        #expect(fixture.vault.reads == reads)
        #expect(model.notice?.text.contains("已停止自动重试") == true)
        #expect(model.notice?.text.contains("失败 3 次") == false)
        #expect(model.notice?.accountEditor?.account?.id == fixture.first.id)
        #expect(model.accountConnectionStatus(for: fixture.first, on: fixture.network)?.isNormal == false)
        #expect(try fixture.storage.load().currentConnection == saved)
        #expect(try fixture.storage.load().automaticReconnectFailure?.requiresCredentialReview == true)
    }

    @Test func authenticationStopSurvivesDiskRestartSleepHealthySnapshotAndDescriptionEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try RestoreFixture(storage: JSONConfigurationStorage(url: directory.appendingPathComponent("accounts.json")))
        let model = try fixture.model(automaticReconnect: true)
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        fixture.service.current.hasUsableAddress = false
        fixture.service.connectionError = NSError(domain: CWErrorDomain, code: 1)
        await model.refresh()
        for _ in 0..<2000 {
            if model.automaticReconnectNeedsCredentialReview && !model.isSwitching { break }
            await Task.yield()
        }
        let reads = fixture.vault.reads
        let reopened = try fixture.model(automaticReconnect: true)
        #expect(reopened.notice?.accountEditor?.account?.id == fixture.first.id)
        #expect(reopened.notice?.text.contains("已停止自动重试") == true)
        reopened.suspendConnectionForSleep()
        await reopened.resumeConnectionAfterWake()
        fixture.service.current.ssid = fixture.network.ssid
        fixture.service.current.hasUsableAddress = true
        await reopened.refresh()
        #expect(reopened.connectedAccountID == nil)
        #expect(reopened.automaticReconnectNeedsCredentialReview)
        #expect(try reopened.saveAccount(editor: AccountEditor(account: fixture.first), label: "Renamed",
                                        username: fixture.first.username, password: "") == nil)
        fixture.service.current.ssid = nil
        for _ in 0..<20 { await reopened.refresh(); await Task.yield() }
        #expect(reopened.automaticReconnectFailures == 1)
        #expect(fixture.service.reconnections == 1)
        #expect(fixture.vault.reads == reads)
        #expect(try fixture.storage.load().automaticReconnectFailure?.requiresCredentialReview == true)
    }

    @Test(arguments: [true, false])
    func credentialCorrectionOrManualReconnectResumesAfterAuthenticationStop(editCredentials: Bool) async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model(automaticReconnect: true)
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        fixture.service.current.hasUsableAddress = false
        fixture.service.connectionError = NSError(domain: CWErrorDomain, code: 1)
        await model.refresh()
        for _ in 0..<2000 {
            if model.automaticReconnectNeedsCredentialReview && !model.isSwitching { break }
            await Task.yield()
        }
        #expect(model.automaticReconnectNeedsCredentialReview)
        fixture.service.connectionError = nil
        if editCredentials {
            let task = try #require(try model.saveAccount(editor: AccountEditor(account: fixture.first), label: "Group",
                                                         username: fixture.first.username, password: "updated-secret"))
            await task.value
            #expect(fixture.service.lastPassword == "updated-secret")
        } else {
            await model.reconnectAccount(fixture.first, on: fixture.network)?.value
        }
        #expect(!model.automaticReconnectNeedsCredentialReview)
        #expect(model.automaticReconnectFailures == 0)
        #expect(model.connectedAccountID == fixture.first.id)
        #expect(fixture.service.authentications == 3)
        #expect(fixture.service.reconnections == 1)
        #expect(try fixture.storage.load().automaticReconnectFailure == nil)
    }

    @Test func manualAuthenticationFailureDoesNotStartAutomaticRecovery() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model(automaticReconnect: true)
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        fixture.service.current.ssid = nil
        fixture.service.connectionError = NSError(domain: CWErrorDomain, code: 1)
        await model.reconnectAccount(fixture.first, on: fixture.network)?.value
        for _ in 0..<20 { await model.refresh(); await Task.yield() }
        #expect(fixture.service.authentications == 2)
        #expect(fixture.service.reconnections == 0)
        #expect(model.notice?.text.contains("已停止自动重试") == true)
        #expect(model.notice?.accountEditor?.account?.id == fixture.first.id)
    }

    @Test func missingSavedPasswordStopsBeforeAnyAuthenticationAndDoesNotReadAgain() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model(automaticReconnect: true)
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        fixture.service.current.hasUsableAddress = false
        fixture.vault.values.removeValue(forKey: fixture.first.id)
        await model.refresh()
        for _ in 0..<2000 {
            if model.automaticReconnectNeedsCredentialReview && !model.isSwitching { break }
            await Task.yield()
        }
        let reads = fixture.vault.reads
        for _ in 0..<20 { await model.refresh(); await Task.yield() }
        #expect(model.automaticReconnectNeedsCredentialReview)
        #expect(fixture.service.reconnections == 0)
        #expect(fixture.vault.reads == reads)
    }

    @Test(arguments: [-3905, -3925])
    func systemTimeoutStopsAfterSingleConfirmedAttempt(code: Int) async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model(automaticReconnect: true)
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        fixture.service.current.hasUsableAddress = false
        fixture.service.connectionError = NSError(domain: CWErrorDomain, code: code)
        await model.refresh()
        for _ in 0..<2000 {
            if model.automaticReconnectFailures == 1 && !model.isSwitching { break }
            await Task.yield()
        }
        #expect(fixture.service.reconnections == 1)
        #expect(model.automaticReconnectFailures == 1)
        #expect(!model.automaticReconnectNeedsCredentialReview)
    }

    @Test func savedCredentialsRemainSavedWhenReconnectCannotStartInDemo() throws {
        let model = AppModel(demoMode: true)
        let network = try #require(model.networks.first)
        let account = network.accounts[0]
        model.markCurrentAccount(account, on: network)
        #expect(try model.saveAccount(editor: AccountEditor(account: account), label: account.label,
                                     username: "updated-demo-user", password: "") == nil)
        #expect(model.accounts.first?.username == "updated-demo-user")
        #expect(model.notice?.text.contains("账号已保存，但未能开始重新连接") == true)
        #expect(!model.isSwitching)
    }

    @Test func savingChangedCredentialsReconnectsOnceWithNewValuesAfterPersistence() async throws {
        for changes in [("updated-user", ""), ("synthetic-first", "updated-secret"), ("updated-user", "updated-secret")] {
            let fixture = try RestoreFixture()
            let model = try fixture.model()
            await model.switchAccount(fixture.first, on: fixture.network)?.value
            let task = try #require(try model.saveAccount(editor: AccountEditor(account: fixture.first), label: "Updated",
                                                     username: changes.0, password: changes.1))
            #expect(model.isSwitching)
            #expect(model.accountSelection == nil)
            #expect(try fixture.storage.load().accounts[0].username == changes.0)
            #expect(try fixture.storage.load().currentConnection == nil)
            #expect(model.notice?.text.contains("账号已保存") == true)
            await task.value
            #expect(fixture.service.authentications == 2)
            #expect(fixture.service.reconnections == 0) // Changed credentials require fresh authentication, not passive recovery.
            #expect(fixture.service.lastUsername == changes.0)
            #expect(fixture.service.lastPassword == (changes.1.isEmpty ? "synthetic-secret" : changes.1))
            #expect(model.connectedAccountID == fixture.first.id)
            #expect(model.notice?.text.contains("账号已保存并重新连接成功") == true)
            let reopened = try fixture.model()
            await reopened.refresh()
            #expect(reopened.selectedAccount?.username == changes.0)
        }
    }

    @Test func unchangedCredentialsAndDescriptionDoNotReconnect() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        let selection = try fixture.storage.load().currentConnection
        for password in ["", "synthetic-secret"] {
            let task = try model.saveAccount(editor: AccountEditor(account: fixture.first), label: "Updated description",
                                             username: "  synthetic-first  ", password: password)
            #expect(task == nil)
            #expect(try fixture.storage.load().currentConnection == selection)
            #expect(model.connectedAccountID == fixture.first.id)
        }
        #expect(fixture.service.authentications == 1)
    }

    @Test func savingReconnectsOnlyThePreviouslyActiveNetworkNotEveryLinkedSSID() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        try model.addNetwork(ssid: "Second Enterprise", to: fixture.first)
        let network = try #require(model.networks.first(where: { $0.ssid == "Second Enterprise" }))
        await model.switchAccount(network.accounts[0], on: network)?.value
        let task = try #require(try model.saveAccount(editor: AccountEditor(account: fixture.first), label: "Group",
                                                 username: "updated-user", password: ""))
        await task.value
        #expect(fixture.service.authentications == 2)
        #expect(fixture.service.lastSSID == "Second Enterprise")
        #expect(try fixture.storage.load().currentConnection?.networkID == network.id)
    }

    @Test func savingOtherAccountOrUnlinkedCurrentNetworkDoesNotSwitchWiFi() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        #expect(try model.saveAccount(editor: AccountEditor(account: fixture.second), label: "Studio",
                                     username: "updated-other-user", password: "updated-secret") == nil)
        #expect(model.connectedAccountID == fixture.first.id)
        #expect(try model.saveAccount(editor: AccountEditor(account: fixture.first), label: "Group",
                                     username: "updated-user", password: "updated-secret", networkIDs: []) == nil)
        #expect(fixture.service.authentications == 1)
        #expect(try fixture.storage.load().currentConnection == nil)
    }

    @Test func saveDoesNotPullUserBackFromAnotherNetwork() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        fixture.service.current.ssid = "Other"
        await model.refresh()
        #expect(try model.saveAccount(editor: AccountEditor(account: fixture.first), label: "Group",
                                     username: "updated-user", password: "updated-secret") == nil)
        #expect(fixture.service.authentications == 1)
        #expect(fixture.service.current.ssid == "Other")
    }

    @Test func failedSaveNeverReconnectsAndRestoresPreviousSecretAndMarker() async throws {
        let storage = RestoreStorage()
        let fixture = try RestoreFixture(storage: storage)
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        let selection = storage.value.currentConnection
        storage.failWrites = true
        #expect(throws: (any Error).self) {
            try model.saveAccount(editor: AccountEditor(account: fixture.first), label: "Group",
                                  username: "updated-user", password: "updated-secret")
        }
        #expect(fixture.service.authentications == 1)
        #expect(model.connectedAccountID == fixture.first.id)
        #expect(storage.value.currentConnection == selection)
        #expect(fixture.vault.values[fixture.first.id] == "synthetic-secret")
    }

    @Test func failedReconnectAfterSaveRetainsNewCredentialsAndReportsBothOutcomes() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        fixture.service.failAuthentication = true
        let task = try #require(try model.saveAccount(editor: AccountEditor(account: fixture.first), label: "Group",
                                                 username: "updated-user", password: "updated-secret"))
        await task.value
        #expect(model.notice?.isError == true)
        #expect(model.notice?.text.contains("账号已保存，但重新连接未完成") == true)
        #expect(try fixture.storage.load().accounts[0].username == "updated-user")
        #expect(fixture.vault.values[fixture.first.id] == "updated-secret")
        #expect(try fixture.storage.load().currentConnection == nil)
        #expect(model.connectedAccountID == nil)
        #expect(fixture.service.authentications == 2)
    }

    @Test func credentialCorrectionAfterConfirmedFailureReconnects() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model(automaticReconnect: true)
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        fixture.service.current.hasUsableAddress = false
        fixture.service.failAuthentication = true
        await model.refresh()
        for _ in 0..<2000 {
            if model.automaticReconnectFailures == 1 && !model.isSwitching { break }
            await Task.yield()
        }
        #expect(model.automaticReconnectFailures == 1)
        fixture.service.failAuthentication = false
        let task = try #require(try model.saveAccount(editor: AccountEditor(account: fixture.first), label: "Group",
                                                 username: fixture.first.username, password: "updated-secret"))
        await task.value
        #expect(model.automaticReconnectFailures == 0)
        #expect(model.connectedAccountID == fixture.first.id)
        #expect(fixture.service.authentications == 3)
        #expect(try fixture.storage.load().automaticReconnectFailure == nil)
    }

    @Test func confirmedFailureIsNotRetriedAcrossRestartWithoutAction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try RestoreFixture(storage: JSONConfigurationStorage(url: directory.appendingPathComponent("accounts.json")))
        let model = try fixture.model(automaticReconnect: true)
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        let saved = try fixture.storage.load().currentConnection
        fixture.service.current.hasUsableAddress = false
        fixture.service.failAuthentication = true
        await model.refresh()
        for _ in 0..<2000 {
            if model.automaticReconnectFailures == 1 && !model.isSwitching { break }
            await Task.yield()
        }
        #expect(model.automaticReconnectFailures == 1)
        #expect(fixture.service.reconnections == 1)
        #expect(try fixture.storage.load().currentConnection == saved)
        let reopened = try fixture.model(automaticReconnect: true)
        for _ in 0..<10 { await reopened.refresh(); await Task.yield() }
        #expect(reopened.automaticReconnectFailures == 1)
        #expect(fixture.service.reconnections == 1)
        fixture.service.failAuthentication = false
        await reopened.reconnectAccount(fixture.first, on: fixture.network)?.value
        #expect(reopened.connectedAccountID == fixture.first.id)
        #expect(reopened.automaticReconnectFailures == 0)
        #expect(try fixture.storage.load().automaticReconnectFailure == nil)
        #expect(fixture.service.reconnections == 1)
    }

    @Test func automaticRecoveryUsesRecoveryAPIAndStopsAfterSuccess() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model(automaticReconnect: true)
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        let saved = try fixture.storage.load().currentConnection
        let lastUsed = try fixture.storage.load().accounts[0].lastUsedAt
        fixture.service.current.hasUsableAddress = false
        await model.refresh()
        for _ in 0..<2000 {
            if fixture.service.reconnections > 0 && !model.isSwitching { break }
            await Task.yield()
        }
        #expect(model.connectedAccountID == fixture.first.id)
        #expect(fixture.service.reconnections == 1)
        #expect(model.automaticReconnectFailures == 0)
        #expect(try fixture.storage.load().currentConnection == saved)
        #expect(try fixture.storage.load().accounts[0].lastUsedAt == lastUsed)
        #expect(model.notice?.text.contains("重新连接成功") == true)
        for _ in 0..<10 { await model.refresh() }
        #expect(fixture.service.reconnections == 1)
    }

    @Test(arguments: [true, false])
    func disconnectedNetworkRequiresExplicitUserAction(switchAccount: Bool) async throws {
        let f = try RestoreFixture()
        let model = try f.model(automaticReconnect: true, delay: .milliseconds(10), prompt: { _, _ in false })
        await model.switchAccount(f.first, on: f.network)?.value
        let reads = f.vault.reads
        f.service.current.ssid = nil
        f.service.current.hasUsableAddress = false
        await model.connectionDidChange()
        try await Task.sleep(for: .milliseconds(60))
        for _ in 0..<3 { await model.refresh() }
        #expect(f.service.reconnections == 0)
        #expect(f.vault.reads == reads)
        #expect(model.menuNetworkStatus == .disconnected)
        #expect(model.accountConnectionStatus(for: f.first, on: f.network)?.isNormal == false)
        let target = switchAccount ? f.second : f.first
        if switchAccount { await model.switchAccount(target, on: f.network)?.value }
        else { await model.reconnectAccount(target, on: f.network)?.value }
        #expect(model.connectedAccountID == target.id)
        #expect(f.service.authentications == 2)
    }

    @Test func disconnectedDuringPendingPromptCanBeCancelled() async throws {
        let f = try RestoreFixture()
        let model = try f.model(automaticReconnect: true, delay: .milliseconds(60), prompt: { _, _ in false })
        await model.switchAccount(f.first, on: f.network)?.value
        f.service.current.hasUsableAddress = false
        await model.refresh()
        f.service.current.ssid = nil
        await model.connectionDidChange()
        try await Task.sleep(for: .milliseconds(120))
        #expect(f.service.reconnections == 0)
        #expect(model.menuNetworkStatus == .disconnected)
    }

    @Test func disconnectedAtRestartDoesNotResumeAutomatically() async throws {
        let f = try RestoreFixture()
        let old = try f.model()
        await old.switchAccount(f.first, on: f.network)?.value
        f.service.current.ssid = nil
        f.service.current.hasUsableAddress = false
        let model = try f.model(automaticReconnect: true, delay: .milliseconds(10))
        await model.refresh()
        try await Task.sleep(for: .milliseconds(60))
        #expect(f.service.reconnections == 0)
        #expect(model.menuNetworkStatus == .disconnected)
        #expect(try f.storage.load().currentConnection?.accountID == f.first.id)
    }

    @Test func cancellingPromptDoesNotReadCredentialsOrPromptAgain() async throws {
        let f = try RestoreFixture()
        let decision = ReconnectDecision(answer: false)
        let model = try f.model(automaticReconnect: true, prompt: { account, network in
            await decision.ask(account: account, network: network)
        })
        await model.switchAccount(f.second, on: f.network)?.value
        let reads = f.vault.reads
        f.service.current.ssid = nil
        f.service.current.hasUsableAddress = false
        await model.connectionDidChange()
        for _ in 0..<100 where decision.count == 0 { await Task.yield() }
        for _ in 0..<5 { await model.refresh(); await Task.yield() }
        #expect(decision.count == 1)
        #expect(decision.accountID == f.second.id)
        #expect(decision.ssid == f.network.ssid)
        #expect(f.vault.reads == reads)
        #expect(f.service.reconnections == 0)
        #expect(model.menuNetworkStatus == .disconnected)
    }

    @Test func confirmingPromptReconnectsLastAccountOnce() async throws {
        let f = try RestoreFixture()
        let decision = ReconnectDecision(answer: true)
        let model = try f.model(automaticReconnect: true, prompt: { account, network in
            await decision.ask(account: account, network: network)
        })
        await model.switchAccount(f.second, on: f.network)?.value
        f.service.current.ssid = nil
        f.service.current.hasUsableAddress = false
        await model.connectionDidChange()
        for _ in 0..<1000 where f.service.reconnections == 0 || model.isSwitching { await Task.yield() }
        #expect(decision.count == 1)
        #expect(decision.accountID == f.second.id)
        #expect(f.service.reconnections == 1)
        #expect(f.service.lastUsername == f.second.username)
        #expect(model.connectedAccountID == f.second.id)
        #expect(model.menuNetworkStatus == .registered)
    }

    @Test func confirmationAfterSystemRecoveryCannotReconnectStaleAccount() async throws {
        let f = try RestoreFixture()
        let decision = ReconnectDecision(answer: nil)
        let model = try f.model(automaticReconnect: true, prompt: { account, network in
            await decision.ask(account: account, network: network)
        })
        await model.switchAccount(f.second, on: f.network)?.value
        f.service.current.ssid = nil
        f.service.current.hasUsableAddress = false
        await model.connectionDidChange()
        for _ in 0..<1000 where decision.pending == nil { await Task.yield() }
        let pending = try #require(decision.pending)
        f.service.current.ssid = "Other"
        f.service.current.hasUsableAddress = true
        await model.connectionDidChange()
        decision.pending = nil
        pending.resume(returning: true)
        for _ in 0..<30 { await Task.yield() }
        #expect(f.service.reconnections == 0)
        #expect(model.snapshot.ssid == "Other")
    }

    @Test func defaultPromptDelayIsAboutThreeSecondsAndRequiresConfirmation() async throws {
        let f = try RestoreFixture()
        let decision = ReconnectDecision(answer: false)
        let repository = try AccountRepository(storage: f.storage, vault: f.vault)
        let model = AppModel(demoMode: true, wifi: f.service, repository: repository,
                             automaticReconnectEnabled: true,
                             reconnectPromptDecision: { account, network in await decision.ask(account: account, network: network) })
        await model.switchAccount(f.first, on: f.network)?.value
        f.service.current.ssid = nil
        f.service.current.hasUsableAddress = false
        let start = ContinuousClock.now
        await model.connectionDidChange()
        try await Task.sleep(for: .milliseconds(1000))
        #expect(decision.count == 0)
        for _ in 0..<50 {
            if decision.count > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let elapsed = start.duration(to: .now)
        #expect(decision.count == 1)
        #expect(elapsed >= .seconds(2) && elapsed < .seconds(6))
        #expect(f.service.reconnections == 0)
    }

    @Test func systemRecoveryDuringGracePeriodDoesNotReadPasswordOrReconnect() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model(automaticReconnect: true, delay: .milliseconds(50))
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        let reads = fixture.vault.reads
        fixture.service.current.hasUsableAddress = false
        await model.refresh()
        fixture.service.current.hasUsableAddress = true
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.service.reconnections == 0)
        #expect(fixture.vault.reads == reads)
        #expect(model.connectedAccountID == fixture.first.id)
    }

    @Test func automaticRecoveryRespectsPowerPermissionOtherNetworkAndSleep() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model(automaticReconnect: true, delay: .milliseconds(50))
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        for observation in [
            WiFiSnapshot(ssid: nil, poweredOn: false, available: true),
            WiFiSnapshot(ssid: nil, poweredOn: true, available: false),
            WiFiSnapshot(ssid: nil, poweredOn: true, available: true, ssidIsReadable: false),
            WiFiSnapshot(ssid: "Other", poweredOn: true, available: true, hasUsableAddress: true)
        ] {
            fixture.service.current = observation
            await model.refresh()
        }
        fixture.service.current = WiFiSnapshot(ssid: nil, poweredOn: true, available: true)
        await model.refresh()
        model.suspendConnectionForSleep()
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.service.reconnections == 0)
        fixture.service.current = WiFiSnapshot(ssid: fixture.network.ssid, poweredOn: true, available: true, hasUsableAddress: true)
        await model.resumeConnectionAfterWake()
        #expect(model.connectedAccountID == fixture.first.id)
        #expect(fixture.service.reconnections == 0)
    }

    @Test func manualAccountChangeCancelsPendingAutomaticRecovery() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model(automaticReconnect: true, delay: .milliseconds(50))
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        fixture.service.current.ssid = nil
        await model.refresh()
        await model.switchAccount(fixture.second, on: fixture.network)?.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.connectedAccountID == fixture.second.id)
        #expect(fixture.service.reconnections == 0)
        #expect(try fixture.storage.load().currentConnection?.accountID == fixture.second.id)
    }

    @Test func connectedAccountIsPinnedAndRestoredWithoutChangingStoredOrder() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        let originalOrder = model.accounts.map(\.id)
        await model.switchAccount(fixture.second, on: fixture.network)?.value
        #expect(model.connectedAccountID == fixture.second.id)
        #expect(model.displayAccounts.map(\.id) == [fixture.second.id, fixture.first.id])
        #expect(model.accounts.map(\.id) == originalOrder)
        #expect(try fixture.storage.load().accounts.map(\.id) == originalOrder)

        let reopened = try fixture.model()
        #expect(reopened.connectedAccountID == nil)
        await reopened.refresh()
        #expect(reopened.connectedAccountID == fixture.second.id)
        #expect(reopened.displayAccounts.map(\.id) == [fixture.second.id, fixture.first.id])
        #expect(fixture.service.authentications == 1)

        fixture.service.failAuthentication = true
        let task = try #require(reopened.reconnectAccount(fixture.second, on: fixture.network))
        #expect(reopened.connectedAccountID == nil)
        await task.value
        #expect(reopened.connectedAccountID == nil)
        #expect(reopened.displayAccounts.map(\.id) == originalOrder)
    }

    @Test func explicitReconnectUsesCurrentAccountAndPersistsOnlyAfterSuccess() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        #expect(model.switchAccount(fixture.first, on: fixture.network) == nil)

        let task = try #require(model.reconnectAccount(fixture.first, on: fixture.network))
        #expect(model.isSwitching)
        #expect(model.accountSelection == nil)
        #expect(try fixture.storage.load().currentConnection == nil)
        #expect(model.reconnectAccount(fixture.first, on: fixture.network) == nil)
        #expect(model.reconnectAccount(fixture.second, on: fixture.network) == nil)
        await task.value

        #expect(fixture.service.authentications == 2)
        #expect(model.isCurrentAccount(fixture.first, on: fixture.network))
        #expect(try fixture.storage.load().currentConnection?.accountID == fixture.first.id)
        #expect(model.notice?.isError == false)
    }

    @Test func failedExplicitReconnectCannotRestorePreviousSuccess() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        let lastUsedAt = try fixture.storage.load().accounts.first?.lastUsedAt
        fixture.service.failAuthentication = true
        await model.reconnectAccount(fixture.first, on: fixture.network)?.value
        #expect(fixture.service.authentications == 2)
        #expect(model.notice?.isError == true)
        #expect(model.accountSelection == nil)
        #expect(try fixture.storage.load().currentConnection == nil)
        #expect(try fixture.storage.load().accounts.first?.lastUsedAt == lastUsedAt)
        let reopened = try fixture.model()
        await reopened.refresh()
        #expect(reopened.selectedAccount == nil)
        #expect(fixture.service.authentications == 2)
    }

    @Test func explicitReconnectStillRejectsInvalidLinksAndDemoAuthentication() throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        model.unlinkNetwork(fixture.network, from: fixture.first)
        #expect(model.reconnectAccount(fixture.first, on: fixture.network) == nil)
        #expect(fixture.vault.reads == 0)
        #expect(fixture.service.authentications == 0)
        let demo = AppModel(demoMode: true)
        let network = try #require(demo.networks.first)
        #expect(demo.reconnectAccount(network.accounts[0], on: network) == nil)
        #expect(demo.notice?.isError == true)
    }

    @Test func statusRequiresUsableIPAndRecoversWithoutReauthentication() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        #expect(model.accountConnectionStatus(for: fixture.first, on: fixture.network) == .normal)
        #expect(model.accountConnectionStatus(for: fixture.second, on: fixture.network) == nil)
        fixture.service.current.hasUsableAddress = false
        await model.refresh()
        let status = model.accountConnectionStatus(for: fixture.first, on: fixture.network)
        #expect(status?.isNormal == false)
        #expect(status?.detail.contains("IP 地址") == true)
        #expect(fixture.service.authentications == 1)
        fixture.service.current.hasUsableAddress = true
        await model.refresh()
        #expect(model.accountConnectionStatus(for: fixture.first, on: fixture.network) == .normal)
        #expect(fixture.service.authentications == 1)
    }

    @Test func interruptedConnectionHasSpecificReasonAndCanRetryExplicitly() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        fixture.service.current.ssid = nil
        await model.refresh()
        #expect(model.accountSelection == nil)
        #expect(try fixture.storage.load().currentConnection?.accountID == fixture.first.id)
        #expect(model.accountConnectionStatus(for: fixture.first, on: fixture.network)?.detail.contains("已断开") == true)
        await model.refresh()
        #expect(model.accountConnectionStatus(for: fixture.first, on: fixture.network)?.isNormal == false)
        fixture.service.current.poweredOn = false
        await model.refresh()
        #expect(model.accountConnectionStatus(for: fixture.first, on: fixture.network)?.detail.contains("已关闭") == true)
        fixture.service.current.available = false
        await model.refresh()
        #expect(model.accountConnectionStatus(for: fixture.first, on: fixture.network)?.detail.contains("网卡") == true)
        #expect(fixture.service.authentications == 1)
        fixture.service.current.available = true
        fixture.service.current.poweredOn = true
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        #expect(model.accountConnectionStatus(for: fixture.first, on: fixture.network) == .normal)
        #expect(fixture.service.authentications == 2)
    }

    @Test func abnormalIPAllowsRetryButHealthyAccountRejectsIt() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        #expect(model.switchAccount(fixture.first, on: fixture.network) == nil)
        fixture.service.current.hasUsableAddress = false
        await model.refresh()
        let retry = model.switchAccount(fixture.first, on: fixture.network)
        #expect(retry != nil)
        await retry?.value
        #expect(fixture.service.authentications == 2)
    }

    @Test func changingNetworkOrClearingMarkRemovesInterruptedIndicator() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        fixture.service.current.ssid = nil
        await model.refresh()
        fixture.service.current.ssid = "Other"
        await model.refresh()
        #expect(model.accountConnectionStatus(for: fixture.first, on: fixture.network) == nil)
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        fixture.service.current.ssid = nil
        await model.refresh()
        model.clearAccountSelection()
        #expect(model.accountConnectionStatus(for: fixture.first, on: fixture.network) == nil)
    }

    @Test func permissionRedactionDoesNotReportFalseConnectionFailure() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        fixture.service.current.ssid = nil
        fixture.service.current.ssidIsReadable = false
        await model.refresh()
        #expect(model.accountConnectionStatus(for: fixture.first, on: fixture.network) == nil)
        #expect(try fixture.storage.load().currentConnection != nil)
        #expect(fixture.service.authentications == 1)
    }

    @Test func diskRestartRestoresCurrentWithoutAuthenticationOrReadingPassword() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = JSONConfigurationStorage(url: directory.appendingPathComponent("accounts.json"))
        let fixture = try RestoreFixture(storage: storage)
        var original: AppModel? = try fixture.model()
        await original?.switchAccount(fixture.first, on: fixture.network)?.value
        let reads = fixture.vault.reads
        original = nil

        let reopened = try fixture.model()
        #expect(reopened.isCheckingConnection)
        #expect(reopened.switchAccount(fixture.second, on: fixture.network) == nil)
        await reopened.refresh()

        #expect(reopened.selectedAccount?.id == fixture.first.id)
        #expect(reopened.accountSelection?.source == .restoredConnection)
        #expect(reopened.isCurrentAccount(fixture.first, on: fixture.network))
        #expect(reopened.switchAccount(fixture.first, on: fixture.network) == nil)
        #expect(fixture.service.authentications == 1)
        #expect(fixture.vault.reads == reads)
        let json = try String(contentsOf: storage.url, encoding: .utf8)
        #expect(!json.contains("synthetic-secret"))
        #expect(!json.contains("password"))
        #expect(try FileManager.default.attributesOfItem(atPath: storage.url.path)[.posixPermissions] as? Int == 0o600)

        let reopenedAgain = try fixture.model()
        await reopenedAgain.refresh()
        #expect(reopenedAgain.selectedAccount?.id == fixture.first.id)
        #expect(fixture.service.authentications == 1)
        #expect(fixture.vault.reads == reads)
    }

    @Test func permissionRedactionPreservesRecordUntilSSIDCanBeChecked() async throws {
        let fixture = try RestoreFixture()
        let original = try fixture.model()
        await original.switchAccount(fixture.first, on: fixture.network)?.value
        fixture.service.current.ssid = nil
        fixture.service.current.ssidIsReadable = false
        let reopened = try fixture.model()
        await reopened.refresh()

        #expect(reopened.accountSelection == nil)
        #expect(try fixture.storage.load().currentConnection?.accountID == fixture.first.id)
        #expect(reopened.accountStatusDetail.contains("不需要为此重新连接"))
        let reads = fixture.vault.reads
        fixture.service.current.ssid = fixture.network.ssid
        fixture.service.current.ssidIsReadable = true
        await reopened.refresh()
        #expect(reopened.selectedAccount?.id == fixture.first.id)
        #expect(fixture.service.authentications == 1)
        #expect(fixture.vault.reads == reads)
    }

    @Test func startupWaitsForReadableConnectionWithoutDeletingSavedAccount() async throws {
        let observations = [
            WiFiSnapshot(ssid: nil, poweredOn: true, available: true),
            WiFiSnapshot(ssid: "Enterprise", poweredOn: false, available: true),
            WiFiSnapshot(ssid: "Enterprise", poweredOn: true, available: false)
        ]
        for observation in observations {
            let fixture = try RestoreFixture()
            let original = try fixture.model()
            await original.switchAccount(fixture.first, on: fixture.network)?.value
            fixture.service.current = observation
            let reopened = try fixture.model()
            await reopened.refresh()
            #expect(reopened.accountSelection == nil)
            #expect(reopened.connectedAccountID == nil)
            #expect(try fixture.storage.load().currentConnection?.accountID == fixture.first.id)
            fixture.service.current = WiFiSnapshot(ssid: fixture.network.ssid, poweredOn: true, available: true, hasUsableAddress: true)
            let reads = fixture.vault.reads
            await reopened.refresh()
            #expect(reopened.connectedAccountID == fixture.first.id)
            let later = try fixture.model()
            await later.refresh()
            #expect(later.connectedAccountID == fixture.first.id)
            #expect(fixture.service.authentications == 1)
            #expect(fixture.vault.reads == reads)
        }
    }

    @Test func differentSSIDAtStartupHidesCurrentWithoutErasingSavedAccount() async throws {
        let fixture = try RestoreFixture()
        let original = try fixture.model()
        await original.switchAccount(fixture.first, on: fixture.network)?.value
        fixture.service.current.ssid = "Other"
        let reopened = try fixture.model()
        await reopened.refresh()
        #expect(reopened.accountSelection == nil)
        #expect(try fixture.storage.load().currentConnection?.accountID == fixture.first.id)
        fixture.service.current.ssid = fixture.network.ssid
        let later = try fixture.model()
        await later.refresh()
        #expect(later.connectedAccountID == fixture.first.id)
    }

    @Test func runtimeNetworkChangesNeverRewriteSavedConnection() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        let saved = try fixture.storage.load().currentConnection
        let reads = fixture.vault.reads
        let observations = [
            WiFiSnapshot(ssid: nil, poweredOn: true, available: true),
            WiFiSnapshot(ssid: nil, poweredOn: false, available: true),
            WiFiSnapshot(ssid: nil, poweredOn: false, available: false),
            WiFiSnapshot(ssid: "Other", poweredOn: true, available: true, hasUsableAddress: true)
        ]
        for observation in observations {
            fixture.service.current = observation
            await model.connectionDidChange()
            #expect(model.connectedAccountID == nil)
            #expect(try fixture.storage.load().currentConnection == saved)
            let reopened = try fixture.model()
            await reopened.refresh()
            #expect(reopened.connectedAccountID == nil)
            #expect(try fixture.storage.load().currentConnection == saved)
            fixture.service.current = WiFiSnapshot(ssid: fixture.network.ssid, poweredOn: true, available: true, hasUsableAddress: true)
            await model.refresh()
            await reopened.refresh()
            #expect(model.connectedAccountID == fixture.first.id)
            #expect(reopened.connectedAccountID == fixture.first.id)
        }
        #expect(fixture.service.authentications == 1)
        #expect(fixture.vault.reads == reads)
    }

    @Test func credentialEditWhileOfflineAuthenticatesNewCredentialsBeforeRestoringIdentity() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        fixture.service.current.ssid = nil
        await model.refresh()
        let task = try #require(try model.saveAccount(editor: AccountEditor(account: fixture.first), label: fixture.first.label,
                              username: fixture.first.username, password: "changed-synthetic-secret"))
        #expect(model.accountSelection == nil)
        #expect(try fixture.storage.load().currentConnection == nil)
        await task.value
        #expect(model.connectedAccountID == fixture.first.id)
        #expect(fixture.service.lastPassword == "changed-synthetic-secret")
        #expect(fixture.service.authentications == 2)
    }

    @Test func sleepAndDelayedWakeRestoreFromDiskWithoutAuthenticationOrSecretAccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = JSONConfigurationStorage(url: directory.appendingPathComponent("accounts.json"))
        let fixture = try RestoreFixture(storage: storage)
        let model = try fixture.model()
        await model.switchAccount(fixture.second, on: fixture.network)?.value
        let before = try Data(contentsOf: storage.url)
        let reads = fixture.vault.reads

        model.suspendConnectionForSleep()
        fixture.service.current = WiFiSnapshot(ssid: nil, poweredOn: false, available: false)
        await model.connectionDidChange()
        #expect(model.connectedAccountID == nil)
        await model.resumeConnectionAfterWake()
        await model.refresh()
        #expect(model.accountSelection == nil)
        #expect(try Data(contentsOf: storage.url) == before)

        fixture.service.current = WiFiSnapshot(ssid: fixture.network.ssid, poweredOn: true, available: true, hasUsableAddress: true)
        await model.refresh()
        #expect(model.connectedAccountID == fixture.second.id)
        #expect(model.displayAccounts.first?.id == fixture.second.id)
        let reopened = try fixture.model()
        await reopened.refresh()
        #expect(reopened.connectedAccountID == fixture.second.id)
        #expect(try Data(contentsOf: storage.url) == before)
        #expect(fixture.service.authentications == 1)
        #expect(fixture.vault.reads == reads)
    }

    @Test func wakeOnDifferentWiFiKeepsRecordUntilMatchingNetworkReturns() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        model.suspendConnectionForSleep()
        fixture.service.current.ssid = "Other"
        await model.resumeConnectionAfterWake()
        #expect(model.connectedAccountID == nil)
        #expect(try fixture.storage.load().currentConnection?.accountID == fixture.first.id)
        fixture.service.current.ssid = fixture.network.ssid
        await model.refresh()
        #expect(model.connectedAccountID == fixture.first.id)
    }

    @Test func refreshStartedBeforeSleepCannotDeleteRememberedAccount() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        var pending: CheckedContinuation<WiFiSnapshot, Never>?
        fixture.service.nextSnapshot = { await withCheckedContinuation { pending = $0 } }
        let oldRefresh = Task { await model.refresh() }
        while pending == nil { await Task.yield() }
        model.suspendConnectionForSleep()
        pending?.resume(returning: WiFiSnapshot(ssid: nil, poweredOn: true, available: true))
        await oldRefresh.value
        #expect(try fixture.storage.load().currentConnection?.accountID == fixture.first.id)
        #expect(model.connectedAccountID == nil)
        await model.resumeConnectionAfterWake()
        #expect(model.connectedAccountID == fixture.first.id)
    }

    @Test func newerRefreshWinsOverLateDisconnectedSnapshot() async throws {
        let fixture = try RestoreFixture()
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        var pending: CheckedContinuation<WiFiSnapshot, Never>?
        fixture.service.nextSnapshot = { await withCheckedContinuation { pending = $0 } }
        let oldRefresh = Task { await model.refresh() }
        while pending == nil { await Task.yield() }
        await model.refresh()
        pending?.resume(returning: WiFiSnapshot(ssid: nil, poweredOn: true, available: true))
        await oldRefresh.value
        #expect(model.connectedAccountID == fixture.first.id)
        #expect(try fixture.storage.load().currentConnection?.accountID == fixture.first.id)
        #expect(fixture.service.authentications == 1)
    }

    @Test func failedConnectionCannotRestorePreviousSuccessAfterRestart() async throws {
        let fixture = try RestoreFixture()
        let original = try fixture.model()
        await original.switchAccount(fixture.first, on: fixture.network)?.value
        fixture.service.failAuthentication = true
        await original.switchAccount(fixture.second, on: fixture.network)?.value
        #expect(try fixture.storage.load().currentConnection == nil)

        let reopened = try fixture.model()
        await reopened.refresh()
        #expect(reopened.accountSelection == nil)
        #expect(fixture.service.authentications == 2)
    }

    @Test func legacyHistoryMigratesOnceWithoutConnectingAndClearCannotReviveIt() async throws {
        let storage = RestoreStorage()
        let fixture = try RestoreFixture(storage: storage)
        storage.value.version = 1
        storage.value.accounts[0].lastUsedAt = Date(timeIntervalSince1970: 10)
        storage.value.accounts[1].lastUsedAt = Date(timeIntervalSince1970: 20)
        let model = try fixture.model()
        await model.refresh()
        #expect(model.selectedAccount?.id == fixture.second.id)
        #expect(model.accountSelection?.source == .restoredConnection)
        #expect(storage.value.version == 4)
        #expect(storage.value.currentConnection?.accountID == fixture.second.id)
        #expect(fixture.service.authentications == 0)
        #expect(fixture.vault.reads == 0)

        model.clearAccountSelection()
        let reopened = try fixture.model()
        await reopened.refresh()
        #expect(reopened.accountSelection == nil)
        #expect(storage.value.currentConnection == nil)
    }

    @Test func legacyMigrationWaitsForPermissionAndRejectsAmbiguousHistory() async throws {
        let storage = RestoreStorage()
        let fixture = try RestoreFixture(storage: storage)
        storage.value.version = 1
        storage.value.accounts[0].lastUsedAt = Date(timeIntervalSince1970: 20)
        storage.value.accounts[1].lastUsedAt = Date(timeIntervalSince1970: 20)
        fixture.service.current.ssid = nil
        fixture.service.current.ssidIsReadable = false
        let model = try fixture.model()
        await model.refresh()
        #expect(storage.value.version == 1)
        fixture.service.current.ssid = fixture.network.ssid
        fixture.service.current.ssidIsReadable = true
        await model.refresh()
        #expect(storage.value.version == 4)
        #expect(model.accountSelection == nil)
        #expect(fixture.service.authentications == 0)
    }

    @Test func manualMarkRestoresWithExplicitSourceWithoutNetworkOrSecretAccess() async throws {
        let fixture = try RestoreFixture()
        let original = try fixture.model()
        await original.refresh()
        original.markCurrentAccount(fixture.first, on: fixture.network)
        let reopened = try fixture.model()
        await reopened.refresh()
        #expect(reopened.selectedAccount?.id == fixture.first.id)
        #expect(reopened.accountSelection?.source == .manual)
        #expect(fixture.service.authentications == 0)
        #expect(fixture.vault.reads == 0)
        #expect(try fixture.storage.load().networks[0].accounts[0].lastUsedAt == nil)
    }

    @Test func descriptionEditPreservesConnectionAndCredentialEditReconnects() async throws {
        let fixture = try RestoreFixture()
        let original = try fixture.model()
        await original.switchAccount(fixture.first, on: fixture.network)?.value
        let editor = AccountEditor(account: fixture.first)
        try original.saveAccount(editor: editor, label: "Updated description", username: fixture.first.username, password: "")
        let reopened = try fixture.model()
        await reopened.refresh()
        #expect(reopened.selectedAccount?.displayName == "Updated description")
        let task = try #require(try reopened.saveAccount(editor: editor, label: "Updated description", username: "different-user", password: ""))
        await task.value
        let afterCredentialEdit = try fixture.model()
        await afterCredentialEdit.refresh()
        #expect(afterCredentialEdit.selectedAccount?.username == "different-user")
        #expect(try fixture.storage.load().currentConnection?.username == "different-user")
    }

    @Test func deletingCurrentAccountRemovesRememberedSelection() async throws {
        let fixture = try RestoreFixture()
        let original = try fixture.model()
        await original.switchAccount(fixture.first, on: fixture.network)?.value
        original.deleteAccount(AccountDeletion(account: fixture.first))
        let reopened = try fixture.model()
        await reopened.refresh()
        #expect(reopened.accountSelection == nil)
        #expect(reopened.networks[0].accounts.map(\.id) == [fixture.second.id])
        #expect(try fixture.storage.load().currentConnection == nil)
    }

    @Test func failureToInvalidateSavedRecordPreventsAnotherAuthentication() async throws {
        let storage = RestoreStorage()
        let fixture = try RestoreFixture(storage: storage)
        let model = try fixture.model()
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        storage.failWrites = true
        #expect(model.switchAccount(fixture.second, on: fixture.network) == nil)
        #expect(fixture.service.authentications == 1)
        #expect(model.selectedAccount?.id == fixture.first.id)
        #expect(model.notice?.isError == true)
    }

    @Test func failureToSaveSuccessReportsThatRestartCannotRestore() async throws {
        let storage = RestoreStorage()
        let fixture = try RestoreFixture(storage: storage)
        let model = try fixture.model()
        storage.failWrites = true
        await model.switchAccount(fixture.first, on: fixture.network)?.value
        #expect(model.selectedAccount?.id == fixture.first.id)
        #expect(model.notice?.isError == true)
        #expect(model.notice?.text.contains("重开后可能无法恢复") == true)
        #expect(storage.value.currentConnection == nil)
        let reopened = try fixture.model()
        await reopened.refresh()
        #expect(reopened.accountSelection == nil)
        #expect(fixture.service.authentications == 1)
    }
}

@MainActor
private final class RestoreFixture {
    let storage: any ConfigurationStorage
    let vault = RestoreVault()
    let service = RestoreWiFi()
    let network: SavedWiFi
    var first: WiFiAccount { network.accounts[0] }
    var second: WiFiAccount { network.accounts[1] }

    init(storage: any ConfigurationStorage = RestoreStorage()) throws {
        self.storage = storage
        let repository = try AccountRepository(storage: storage, vault: vault)
        let networkID = try repository.addNetwork(ssid: "Enterprise")
        try repository.saveAccount(networkID: networkID, label: "Group", username: "synthetic-first", newPassword: "synthetic-secret")
        try repository.saveAccount(networkID: networkID, label: "Studio", username: "synthetic-second", newPassword: "synthetic-secret")
        network = repository.configuration.networks[0]
        vault.reads = 0
    }

    func model(automaticReconnect: Bool = false, delay: Duration = .zero, reader: RecoveryIdentityReader? = nil, internet: (any InternetChecking)? = nil, prompt: @escaping (WiFiAccount, SavedWiFi) async -> Bool = { _, _ in true }) throws -> AppModel {
        AppModel(demoMode: true, wifi: service, repository: try AccountRepository(storage: storage, vault: vault),
                 automaticReconnectEnabled: automaticReconnect, automaticReconnectDelay: delay, systemReader: reader,
                 credentialComparator: reader == nil ? nil : RecoveryComparator(), internetChecker: internet, reconnectPromptDecision: prompt)
    }
}

private final class RestoreStorage: ConfigurationStorage {
    var value = AccountConfiguration()
    var failWrites = false
    func load() throws -> AccountConfiguration {
        try JSONDecoder().decode(AccountConfiguration.self, from: JSONEncoder().encode(value))
    }
    func save(_ configuration: AccountConfiguration) throws {
        if failWrites { throw CocoaError(.fileWriteNoPermission) }
        value = configuration
    }
}

private final class RestoreVault: CredentialVault {
    var values: [UUID: String] = [:]
    var reads = 0
    func password(for accountID: UUID) -> String? { reads += 1; return values[accountID] }
    func setPassword(_ password: String, for accountID: UUID) { values[accountID] = password }
    func deletePassword(for accountID: UUID) { values.removeValue(forKey: accountID) }
}

@MainActor
private final class RestoreWiFi: WiFiServicing {
    var current = WiFiSnapshot(ssid: "Enterprise", poweredOn: true, available: true, hasUsableAddress: true)
    var authentications = 0
    var reconnections = 0
    var recoveryResult: WiFiReconnectResult = .associated
    var lastUsername: String?
    var lastPassword: String?
    var lastSSID: String?
    var failAuthentication = false
    var usableAddressAfterAssociation = true
    var connectionError: Error?
    var nextSnapshot: (() async -> WiFiSnapshot)?
    func snapshot() async -> WiFiSnapshot {
        if let next = nextSnapshot {
            nextSnapshot = nil
            return await next()
        }
        return current
    }
    func scan() async throws -> [NearbyWiFi] { [] }
    func reconnectAccount(ssid: String, username: String, password: String, progress: @escaping (SwitchPhase) -> Void) async throws -> WiFiReconnectResult {
        reconnections += 1
        if recoveryResult == .systemRecovered {
            current.ssid = ssid
            current.hasUsableAddress = true
            return .systemRecovered
        }
        try await switchAccount(ssid: ssid, username: username, password: password, progress: progress)
        return recoveryResult
    }
    func switchAccount(ssid: String, username: String, password: String,
                       progress: @escaping (SwitchPhase) -> Void) async throws {
        authentications += 1
        lastUsername = username
        lastPassword = password
        lastSSID = ssid
        if let connectionError { throw connectionError }
        if failAuthentication { throw WiFiError.verificationTimeout }
        current.ssid = ssid
        current.hasUsableAddress = usableAddressAfterAssociation
        progress(.verifying)
    }
}

private final class RecoveryIdentityReader: SystemConnectionReading {
    var username: String?
    var hold = false
    var continuation: CheckedContinuation<Void, Never>?
    var configurationReads = 0
    func identity(ssid: String) async -> SystemConnectionIdentity? {
        if hold { await withCheckedContinuation { continuation = $0 } }
        guard let username else { return nil }
        return .init(ssid: ssid, authentication: .enterprise, username: username)
    }
    func configuration(ssid: String) async throws -> SystemConnectionConfiguration {
        configurationReads += 1
        throw SystemImportError.unavailable
    }
}
private struct RecoveryComparator: SystemCredentialComparing {
    func compare(identity: SystemConnectionIdentity, accountID: UUID) async -> SystemCredentialComparison { .same }
}

private struct FixedInternet: InternetChecking {
    let result: Bool
    func isReachable() async -> Bool { result }
}

@MainActor private final class ReconnectDecision {
    let answer: Bool?
    var count = 0
    var accountID: UUID?
    var ssid: String?
    var pending: CheckedContinuation<Bool, Never>?
    init(answer: Bool?) { self.answer = answer }
    func ask(account: WiFiAccount, network: SavedWiFi) async -> Bool {
        count += 1
        accountID = account.id
        ssid = network.ssid
        if let answer { return answer }
        return await withCheckedContinuation { pending = $0 }
    }
}
