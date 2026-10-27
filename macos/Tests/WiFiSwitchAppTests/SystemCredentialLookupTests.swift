import Foundation
import Security
import Testing
import WiFiSwitchCore
@testable import WiFiSwitch

struct SystemCredentialLookupTests {
    @Test func explanationIsPreparedBeforeEachActualKeychainDomainRead() throws {
        var events: [String] = []
        _ = try SystemConnectionReader.readCredentials(authentication: .enterprise, personal: { [] }, coreWLAN: { domain in
            events.append(domain == .user ? "read-user" : "read-system")
            return domain == .user ? nil : .init(username: "alice", password: "synthetic")
        }, prepareAccess: { events.append("explain-\($0.rawValue)") })
        #expect(events == ["explain-user", "read-user", "explain-system", "read-system"])
    }

    @Test func cancelledExplanationNeverStartsTheNextCredentialRead() {
        var reads = 0
        #expect(throws: SystemImportError.self) {
            try SystemConnectionReader.readCredentials(authentication: .enterprise, personal: { [] }, coreWLAN: { _ in
                reads += 1; return nil
            }, prepareAccess: { _ in throw SystemImportError.connectionChanged })
        }
        #expect(reads == 0)
    }

    @Test func personalCredentialExplanationPrecedesReadWithoutUnneededFallback() throws {
        var events: [String] = []
        _ = try SystemConnectionReader.readCredentials(authentication: .personal, personal: {
            events.append("read-personal")
            return [.init(username: nil, password: "synthetic")]
        }, coreWLAN: { _ in Issue.record("Unnecessary fallback"); return nil },
        prepareAccess: { events.append("explain-\($0.rawValue)") })
        #expect(events == ["explain-standardPersonal", "read-personal"])
    }

    @Test(arguments: [WiFiAuthentication.enterprise, .personal])
    func completeUserCredentialNeverRequestsSystemAuthorization(mode: WiFiAuthentication) throws {
        var domains: [SystemCredentialDomain] = []
        let credential = SystemWiFiCredential(username: mode == .enterprise ? "alice" : nil, password: "  synthetic-secret  ")
        let result = try SystemConnectionReader.readCredentials(authentication: mode, personal: { [] }, coreWLAN: { domain in
            domains.append(domain)
            if domain == .system { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAuthFailed)) }
            return credential
        })
        #expect(domains == [.user])
        #expect(result == [credential])
        let configuration = try SystemConnectionReader.resolve(ssid: "Office", authentication: mode, credentials: result)
        #expect(configuration.password == "  synthetic-secret  ")
    }

    @Test(arguments: [WiFiAuthentication.enterprise, .personal])
    func missingUserItemReadsSystemExactlyOnce(mode: WiFiAuthentication) throws {
        var domains: [SystemCredentialDomain] = []
        let credential = SystemWiFiCredential(username: mode == .enterprise ? "alice" : nil, password: "system-secret")
        let result = try SystemConnectionReader.readCredentials(authentication: mode, personal: { [] }, coreWLAN: { domain in
            domains.append(domain)
            return domain == .user ? nil : credential
        })
        #expect(domains == [.user, .system])
        #expect(result == [credential])
    }

    @Test(arguments: [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed, OSStatus(4097)])
    func userReadErrorStopsWithoutFallbackAndPreservesStatus(status: OSStatus) throws {
        var domains: [SystemCredentialDomain] = []
        do {
            _ = try SystemConnectionReader.readCredentials(authentication: .enterprise, personal: { [] }, coreWLAN: { domain in
                domains.append(domain)
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            })
            Issue.record("Expected read failure")
        } catch let error as SystemImportError {
            guard case let .keychain(stage, code) = error else { Issue.record("Lost read status"); return }
            #expect(stage == "读取用户钥匙串" && code == Int(status))
        }
        #expect(domains == [.user])
    }

    @Test func incompleteUserCredentialIsNotReplacedWithAnUnrelatedSystemAccount() throws {
        let cases: [(WiFiAuthentication, SystemWiFiCredential)] = [
            (.enterprise, .init(username: nil, password: "secret")),
            (.enterprise, .init(username: "", password: "secret")),
            (.enterprise, .init(username: "alice", password: nil)),
            (.enterprise, .init(username: "alice", password: "")),
            (.personal, .init(username: nil, password: nil)),
            (.personal, .init(username: nil, password: ""))
        ]
        for (mode, value) in cases {
            var domains: [SystemCredentialDomain] = []
            do {
                _ = try SystemConnectionReader.readCredentials(authentication: mode, personal: { [] }, coreWLAN: { domain in
                    domains.append(domain)
                    return value
                })
                Issue.record("Expected incomplete credential failure")
            } catch let error as SystemImportError {
                guard case .missingCredentials = error else { Issue.record("Wrong failure"); return }
            }
            #expect(domains == [.user])
        }
    }

    @Test func missingBothDomainsAndRequiredSystemAuthorizationRemainExplicit() throws {
        var domains: [SystemCredentialDomain] = []
        let missing = try SystemConnectionReader.readCredentials(authentication: .enterprise, personal: { [] }, coreWLAN: { domain in
            domains.append(domain); return nil
        })
        #expect(missing.isEmpty && domains == [.user, .system])
        #expect(throws: SystemImportError.self) {
            try SystemConnectionReader.resolve(ssid: "Office", authentication: .enterprise, credentials: missing)
        }
        domains = []
        do {
            _ = try SystemConnectionReader.readCredentials(authentication: .enterprise, personal: { [] }, coreWLAN: { domain in
                domains.append(domain)
                if domain == .user { return nil }
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecUserCanceled))
            })
            Issue.record("Expected cancelled System keychain authorization")
        } catch let error as SystemImportError {
            guard case let .keychain(stage, code) = error else { Issue.record("Lost read status"); return }
            #expect(stage == "读取系统钥匙串" && code == Int(errSecUserCanceled))
        }
        #expect(domains == [.user, .system])
    }

    @Test func silentComparisonUsesSameUserFirstLookupAndRejectsWrongIdentity() throws {
        let identity = SystemConnectionIdentity(ssid: "Office", authentication: .enterprise, username: "alice")
        let request = SystemCredentialComparisonRequest(identity: identity, accountID: UUID())
        for username in ["alice", "another-account"] {
            var domains: [SystemCredentialDomain] = []
            let result = SystemCredentialComparator.compare(request: request, system: {
                let credentials = try SystemConnectionReader.readCredentials(authentication: .enterprise, personal: { [] }, coreWLAN: { domain in
                    domains.append(domain)
                    if domain == .system { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed)) }
                    return .init(username: username, password: "new-secret")
                })
                return try SystemConnectionReader.resolve(ssid: identity.ssid, authentication: .enterprise, credentials: credentials)
            }, savedPassword: { "old-secret" })
            #expect(domains == (username == "alice" ? [.user, .user] : [.user]))
            #expect(result == (username == "alice" ? .different : .unavailable))
        }
    }

    @Test func unknownAuthenticationDoesNotTouchEitherKeychain() {
        #expect(throws: SystemImportError.self) {
            try SystemConnectionReader.readCredentials(authentication: .unknown,
                personal: { Issue.record("Unknown network must not read passwords"); return [] },
                coreWLAN: { _ in Issue.record("Unknown network must not query keychains"); return nil })
        }
    }
}
