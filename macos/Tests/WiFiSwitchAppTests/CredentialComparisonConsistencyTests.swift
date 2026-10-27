import Foundation
import Testing
import WiFiSwitchCore
@testable import WiFiSwitch

struct CredentialComparisonConsistencyTests {
    private let identity = SystemConnectionIdentity(ssid: "Synthetic", authentication: .enterprise, username: "example")

    @Test(arguments: ["system", "application", "source", "identity", "denied"])
    func changingInputsNeverProduceAConfirmedDifference(changing: String) {
        var systemReads = 0, appReads = 0
        let evidence = SystemCredentialComparator.evidence(
            request: .init(identity: identity, accountID: UUID(), expectedSource: .user), system: {
                systemReads += 1
                if systemReads == 2 && changing == "denied" { throw SystemImportError.unavailable }
                let value = SystemConnectionConfiguration(
                    identity: systemReads == 2 && changing == "identity" ?
                        .init(ssid: "Other", authentication: .enterprise, username: "example") : identity,
                    password: systemReads == 2 && changing == "system" ? "new" : "old",
                    source: systemReads == 2 && changing == "source" ? .system : .user)
                return value
            }, savedPassword: {
                appReads += 1
                return appReads == 2 && changing == "application" ? "newer" : "new"
            })
        #expect(evidence.result == .unavailable)
        #expect(evidence.reason == (changing == "denied" ? .unreadable : .changedDuringRead))
    }

    @Test func anotherKeychainDomainCannotMasqueradeAsAPasswordChange() {
        var appReads = 0
        let evidence = SystemCredentialComparator.evidence(
            request: .init(identity: identity, accountID: UUID(), expectedSource: .user), system: {
                .init(identity: identity, password: "old-system-copy", source: .system)
            }, savedPassword: { appReads += 1; return "new-user-copy" })
        #expect(evidence.result == .unavailable && evidence.reason == .sourceChanged)
        #expect(appReads == 0)
    }

    @Test func diagnosticEvidenceKeepsErrorCodeWithoutErrorDescription() throws {
        let value = SystemCredentialComparator.evidence(request: .init(identity: identity, accountID: UUID()), system: {
            throw SystemImportError.keychain(stage: "private-user-input", code: -25308)
        }, savedPassword: { "private-secret" })
        #expect(value.result == .unavailable && value.errorCode == -25308)
        let wire = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        #expect(!wire.contains("private"))
    }

    @Test(arguments: [true, false])
    func stableReadsKeepRealChangesDetectable(equal: Bool) throws {
        var systemReads = 0, appReads = 0
        let evidence = SystemCredentialComparator.evidence(
            request: .init(identity: identity, accountID: UUID(), expectedSource: .user), system: {
                systemReads += 1
                return .init(identity: identity, password: "synthetic-secret", source: .user)
            }, savedPassword: { appReads += 1; return equal ? "synthetic-secret" : "other-secret" })
        #expect(evidence.result == (equal ? .same : .different))
        #expect(evidence.reason == (equal ? .equal : .stableDifference))
        #expect(systemReads == (equal ? 1 : 2) && appReads == systemReads)
        let wire = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
        #expect(!wire.contains("secret") && !wire.contains(identity.ssid) && !wire.contains(identity.username!))
    }

    @Test(arguments: [SystemCredentialSource.user, .system, .standardPersonal])
    func readerReportsTheSourceItActuallyUsed(source: SystemCredentialSource) throws {
        var reported: SystemCredentialSource?
        let credential = SystemWiFiCredential(username: "example", password: "synthetic")
        _ = try SystemConnectionReader.readCredentials(authentication: source == .standardPersonal ? .personal : .enterprise,
            personal: { [credential] }, coreWLAN: { domain in
                source == .system && domain == .user ? nil : credential
            }, selectedSource: { reported = $0 })
        #expect(reported == source)
    }
}
