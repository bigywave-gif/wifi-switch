import Foundation
import Testing
@testable import WiFiSwitchCore

final class SwitchEngineTests {
    @Test(arguments: [true, false])
    func noSyncRestoresOriginalCredentialsOnSuccessAndFailure(fails: Bool) throws {
        let driver = FakeDriver()
        driver.states = [.init(ssid: "Office", hasUsableAddress: true)]
        if fails { driver.associateError = WiFiError.verificationTimeout }
        let operation = { try SwitchEngine(driver: driver, wait: { _ in }).switchAccount(ssid: "Office", username: "alice", password: "synthetic", synchronizeSystemCredentials: false, progress: { _ in }) }
        if fails { #expect(throws: WiFiError.self) { try operation() } }
        else { try operation() }
        #expect(driver.calls == ["prepare:Office", "capture", "disconnect", "associate", "restore"])
        #expect(driver.defaultCredentials == nil)
    }

    @Test func noSyncUnreadableOriginalNeverDisconnects() {
        let driver = FakeDriver(); driver.captureError = WiFiError.unavailable
        #expect(throws: WiFiError.self) {
            try SwitchEngine(driver: driver, wait: { _ in }).switchAccount(ssid: "Office", username: "alice", password: "synthetic", synchronizeSystemCredentials: false, progress: { _ in })
        }
        #expect(driver.calls == ["prepare:Office", "capture"])
    }

    @Test func automaticRecoveryNeverDisconnectsAndStillVerifiesIP() throws {
        let driver = FakeDriver()
        let offline = LinkState(ssid: nil, hasUsableAddress: false)
        let ready = LinkState(ssid: "Office", hasUsableAddress: true)
        driver.states = [offline, offline, ready, ready, ready]
        var phases: [SwitchPhase] = []
        try SwitchEngine(driver: driver, wait: { _ in }).reconnectAccount(ssid: "Office", username: "alice", password: "synthetic", progress: { phases.append($0) })
        #expect(!driver.calls.contains("disconnect"))
        #expect(driver.calls.contains("associate"))
        #expect(phases == [.finding, .authenticating, .verifying])
        #expect(driver.stateReads == 5)
    }

    @Test func automaticRecoveryYieldsToSystemRecoveryAndDifferentNetwork() throws {
        for changedDuringScan in [false, true] {
            for ssid in ["Office", "Other"] {
                let driver = FakeDriver()
                driver.states = changedDuringScan ? [LinkState(ssid: nil, hasUsableAddress: false)] : []
                driver.states.append(LinkState(ssid: ssid, hasUsableAddress: true))
                let engine = SwitchEngine(driver: driver, wait: { _ in })
                if ssid == "Office" {
                    try engine.reconnectAccount(ssid: "Office", username: "alice", password: "synthetic", progress: { _ in })
                } else {
                    #expect(throws: WiFiError.connectionChanged) {
                        try engine.reconnectAccount(ssid: "Office", username: "alice", password: "synthetic", progress: { _ in })
                    }
                }
                #expect(!driver.calls.contains("disconnect"))
                #expect(!driver.calls.contains("associate"))
            }
        }
    }

    @Test func personalWiFiUsesOnlyPasswordAndVerifiesConnection() throws {
        let driver = FakeDriver(); driver.authentication = .personal
        driver.states = [LinkState(ssid: "Hotspot", hasUsableAddress: true)]
        try SwitchEngine(driver: driver, wait: { _ in }).switchAccount(ssid: "Hotspot", username: "ignored-enterprise-name", password: "synthetic", progress: { _ in })
        #expect(driver.receivedCredentials == .personal(password: "synthetic"))
        #expect(driver.receivedUsername == nil)
        #expect(driver.stateReads == 3)
    }

    @Test func openWiFiNeverReceivesStoredCredentials() throws {
        let driver = FakeDriver(); driver.authentication = .open
        driver.states = [LinkState(ssid: "Guest", hasUsableAddress: true)]
        try SwitchEngine(driver: driver, wait: { _ in }).switchAccount(ssid: "Guest", username: "must-not-send", password: "must-not-send", progress: { _ in })
        #expect(driver.receivedCredentials == .open)
        #expect(driver.receivedUsername == nil && driver.receivedPassword == nil)
        let empty = FakeDriver(); empty.authentication = .open
        empty.states = driver.states
        try SwitchEngine(driver: empty, wait: { _ in }).switchAccount(ssid: "Guest", username: "", password: "", progress: { _ in })
        #expect(empty.stateReads == 3)
    }

    @Test func missingPersonalPasswordAndEnterpriseUsernameFailBeforeDisconnect() {
        let personal = FakeDriver(); personal.authentication = .personal
        #expect(throws: (any Error).self) { try SwitchEngine(driver: personal, wait: { _ in }).switchAccount(ssid: "Hotspot", username: "", password: "", progress: { _ in }) }
        #expect(personal.calls == ["prepare:Hotspot"])
        let enterprise = FakeDriver()
        #expect(throws: (any Error).self) { try SwitchEngine(driver: enterprise, wait: { _ in }).switchAccount(ssid: "Office", username: " ", password: "synthetic", progress: { _ in }) }
        #expect(enterprise.calls == ["prepare:Office"])
    }

    @Test func ambiguousAuthenticationNeverDisconnects() {
        let driver = FakeDriver(); driver.prepareError = WiFiError.ambiguousAuthentication
        #expect(throws: (any Error).self) { try SwitchEngine(driver: driver, wait: { _ in }).switchAccount(ssid: "Office", username: "alice", password: "synthetic", progress: { _ in }) }
        #expect(driver.calls == ["prepare:Office"])
    }

    @Test func testMissingEnterpriseCredentialsNeverDisconnect() {
        let driver = FakeDriver()
        #expect(throws: (any Error).self) { try SwitchEngine(driver: driver, wait: { _ in }).switchAccount(ssid: "Office", username: "alice", password: "", progress: { _ in }) }
        #expect(driver.calls == ["prepare:Office"])
    }

    @Test func testUnavailableTargetNeverDisconnectsCurrentNetwork() {
        let driver = FakeDriver()
        driver.prepareError = WiFiError.networkNotFound
        #expect(throws: (any Error).self) { try SwitchEngine(driver: driver, wait: { _ in }).switchAccount(ssid: "Office", username: "alice", password: "one", progress: { _ in }) }
        #expect(driver.calls == ["prepare:Office"])
    }

    @Test func testRejectsUnknownAuthenticationBeforeDisconnecting() {
        let driver = FakeDriver()
        driver.authentication = .unknown
        #expect(throws: (any Error).self) { try SwitchEngine(driver: driver, wait: { _ in }).switchAccount(ssid: "Office", username: "alice", password: "one", progress: { _ in }) }
        #expect(driver.calls == ["prepare:Office"])
    }

    @Test func testCredentialRejectionIsNotReportedAsSuccess() {
        let driver = FakeDriver()
        driver.associateError = NSError(domain: "Test", code: 1)
        var phases: [SwitchPhase] = []
        #expect(throws: (any Error).self) { try SwitchEngine(driver: driver, wait: { _ in }).switchAccount(ssid: "Office", username: "alice", password: "one", progress: { phases.append($0) }) }
        #expect(phases == [.finding, .disconnecting, .authenticating])
        #expect(driver.receivedUsername == "alice")
        #expect(driver.receivedPassword == "one")
    }

    @Test func testAssociationAloneIsNotSuccess() {
        let driver = FakeDriver()
        driver.states = [LinkState(ssid: "Office", hasUsableAddress: false)]
        #expect(throws: (any Error).self) { try SwitchEngine(driver: driver, verificationAttempts: 4, wait: { _ in }).switchAccount(ssid: "Office", username: "alice", password: "one", progress: { _ in }) }
    }

    @Test func testOtherNetworkWithIPAddressIsNotSuccess() {
        let driver = FakeDriver()
        driver.states = [LinkState(ssid: "Other", hasUsableAddress: true)]
        #expect(throws: (any Error).self) { try SwitchEngine(driver: driver, verificationAttempts: 4, wait: { _ in }).switchAccount(ssid: "Office", username: "alice", password: "one", progress: { _ in }) }
    }

    @Test func testRequiresThreeConsecutiveMatchesAfterTransientDisconnect() throws {
        let driver = FakeDriver()
        let ready = LinkState(ssid: "Office", hasUsableAddress: true)
        driver.states = [ready, ready, LinkState(ssid: nil, hasUsableAddress: false), ready, ready, ready]
        var phases: [SwitchPhase] = []
        try SwitchEngine(driver: driver, verificationAttempts: 6, wait: { _ in }).switchAccount(ssid: "Office", username: "alice", password: "one", progress: { phases.append($0) })
        #expect(driver.stateReads == 6)
        #expect(phases == [.finding, .disconnecting, .authenticating, .verifying, .savingSystemDefault])
        #expect(Array(driver.calls.prefix(3)) == ["prepare:Office", "disconnect", "associate"])
    }

    @Test func defaultIsSavedOnlyAfterExplicitConnectionAndThreeIPChecks() throws {
        let driver = FakeDriver()
        driver.states = [LinkState(ssid: "Office", hasUsableAddress: true)]
        try SwitchEngine(driver: driver, wait: { _ in }).switchAccount(ssid: "Office", username: "alice", password: "synthetic", progress: { _ in })
        #expect(driver.defaultSavedAtReadCount == 3)
        #expect(driver.defaultCredentials == .enterprise(username: "alice", password: "synthetic"))
        #expect(driver.calls.last == "saveDefault")
    }

    @Test func failedAuthenticationAndVerificationNeverChangeSystemDefault() {
        for rejected in [true, false] {
            let driver = FakeDriver()
            if rejected { driver.associateError = NSError(domain: "fake", code: 1) }
            #expect(throws: (any Error).self) {
                try SwitchEngine(driver: driver, verificationAttempts: 1, wait: { _ in })
                    .switchAccount(ssid: "Office", username: "alice", password: "synthetic", progress: { _ in })
            }
            #expect(driver.defaultCredentials == nil && !driver.calls.contains("saveDefault"))
        }
    }

    @Test func backgroundRecoveryDoesNotOverwriteUserSystemDefault() throws {
        let driver = FakeDriver()
        driver.states = [LinkState(ssid: nil, hasUsableAddress: false), LinkState(ssid: nil, hasUsableAddress: false),
                         LinkState(ssid: "Office", hasUsableAddress: true)]
        try SwitchEngine(driver: driver, wait: { _ in }).reconnectAccount(ssid: "Office", username: "alice", password: "synthetic", progress: { _ in })
        #expect(driver.calls.contains("associate") && !driver.calls.contains("saveDefault"))
    }

    @Test func defaultSaveFailureIsNotMistakenForCredentialRejectionOrRetried() {
        let driver = FakeDriver()
        driver.states = [LinkState(ssid: "Office", hasUsableAddress: true)]
        driver.defaultError = SystemDefaultSyncError(stage: "保存首选 Wi-Fi", code: -60005)
        #expect(throws: SystemDefaultSyncError.self) {
            try SwitchEngine(driver: driver, wait: { _ in }).switchAccount(ssid: "Office", username: "alice", password: "synthetic", progress: { _ in })
        }
        #expect(!connectionRequiresCredentialReview(driver.defaultError!))
        #expect(driver.calls.filter { $0 == "associate" }.count == 1)
    }
}

private final class FakeDriver: WiFiDriver {
    var calls: [String] = []
    var authentication: WiFiAuthentication = .enterprise
    var receivedCredentials: WiFiAssociationCredentials?
    var prepareError: Error?
    var associateError: Error?
    var states: [LinkState] = []
    var stateReads = 0
    var receivedUsername: String?
    var receivedPassword: String?
    var defaultCredentials: WiFiAssociationCredentials?
    var defaultError: Error?
    var defaultSavedAtReadCount: Int?
    var captureError: Error?
    func captureSystemCredentials(credentials: WiFiAssociationCredentials) throws {
        calls.append("capture")
        if let captureError { throw captureError }
    }
    func restoreSystemCredentials() { calls.append("restore") }
    func saveSystemDefault(credentials: WiFiAssociationCredentials) throws {
        calls.append("saveDefault")
        if let defaultError { throw defaultError }
        defaultCredentials = credentials
        defaultSavedAtReadCount = stateReads
    }
    func prepare(ssid: String) throws -> WiFiAuthentication {
        calls.append("prepare:\(ssid)")
        if let prepareError { throw prepareError }
        return authentication
    }
    func disconnect() { calls.append("disconnect") }
    func associate(credentials: WiFiAssociationCredentials) throws {
        calls.append("associate")
        receivedCredentials = credentials
        switch credentials {
        case let .enterprise(username, password): receivedUsername = username; receivedPassword = password
        case let .personal(password): receivedPassword = password
        case .open: break
        }
        if let associateError { throw associateError }
    }
    func linkState() -> LinkState {
        defer { stateReads += 1 }
        return states.isEmpty ? LinkState(ssid: nil, hasUsableAddress: false) : states[min(stateReads, states.count - 1)]
    }
}
