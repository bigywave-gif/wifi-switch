import Foundation
import Security
import Testing
import WiFiSwitchCore
@testable import WiFiSwitch

struct PersonalWiFiKeychainReaderTests {
    private func record(ssid: String = "热点 Café", reference: Data? = nil, password: Data? = nil) -> [String: Any] {
        var value: [String: Any] = [kSecAttrService as String: "AirPort", kSecAttrAccount as String: ssid]
        if let reference { value[kSecValuePersistentRef as String] = reference }
        if let password { value[kSecValueData as String] = password }
        return value
    }

    @Test func importsExactPersonalNetworkByReferenceWithoutCoreWLAN() throws {
        let reference = Data([1, 2])
        var queries: [[String: Any]] = []
        let reader = PersonalWiFiKeychainReader { query in
            queries.append(query)
            if queries.count == 1 { return (errSecSuccess, [record(reference: reference)] as CFArray) }
            return (errSecSuccess, record(password: Data("  password  ".utf8)) as CFDictionary)
        }
        let values = try SystemConnectionReader.readCredentials(authentication: .personal, personal: {
            try reader.read(ssid: "热点 Café")
        }, coreWLAN: { _ in Issue.record("CoreWLAN must not run when standard Wi-Fi credentials exist"); return nil })
        let configuration = try SystemConnectionReader.resolve(ssid: "热点 Café", authentication: .personal, credentials: values)
        #expect(configuration.password == "  password  " && configuration.identity.username == nil)
        #expect(queries.count == 2)
        #expect(queries[0][kSecAttrAccount as String] as? String == "热点 Café")
        #expect(queries[0][kSecAttrService as String] as? String == "AirPort")
        #expect(queries[0][kSecReturnData as String] == nil)
        #expect(queries[1][kSecMatchItemList as String] as? [Data] == [reference])
        #expect(queries[1][kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
    }

    @Test func promptIdentifiesTargetWithoutChangingKeychainPermissions() throws {
        var queries: [[String: Any]] = []
        let reader = PersonalWiFiKeychainReader { query in
            queries.append(query)
            if queries.count == 1 { return (errSecSuccess, [record(reference: Data([8]))] as CFArray) }
            return (errSecSuccess, record(password: Data("secret".utf8)) as CFDictionary)
        }
        _ = try reader.read(ssid: "热点 Café", authorizationPrompt: "核对个人热点，Wi-Fi：热点 Café")
        #expect(queries[1][kSecUseOperationPrompt as String] as? String == "核对个人热点，Wi-Fi：热点 Café")
        #expect(queries[1][kSecAttrAccess as String] == nil)
        #expect(queries[1][kSecValueData as String] == nil)
    }

    @Test(arguments: [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed])
    func authorizationFailureStopsWithoutFallbackOrRepeatedReads(status: OSStatus) throws {
        var calls = 0
        let reader = PersonalWiFiKeychainReader { _ in
            calls += 1
            if calls == 1 { return (errSecSuccess, [record(reference: Data([1]))] as CFArray) }
            return (status, nil)
        }
        do {
            _ = try SystemConnectionReader.readCredentials(authentication: .personal, personal: { try reader.read(ssid: "热点 Café") },
                coreWLAN: { _ in Issue.record("Denied or cancelled access must not trigger another query"); return nil })
            Issue.record("Expected authorization failure")
        } catch let error as SystemImportError {
            guard case .keychain(_, let code) = error else { Issue.record("Lost keychain status"); return }
            #expect(code == Int(status))
            #expect(!error.localizedDescription.contains("证书认证"))
        }
        #expect(calls == 2)
    }

    @Test func onlyMissingStandardItemAllowsCoreWLANFallback() throws {
        let reader = PersonalWiFiKeychainReader { _ in (errSecItemNotFound, nil) }
        var domains: [SystemCredentialDomain] = []
        let values = try SystemConnectionReader.readCredentials(authentication: .personal, personal: { try reader.read(ssid: "Office") },
            coreWLAN: { domain in domains.append(domain); return domain == .user ? nil : .init(username: nil, password: "system") })
        #expect(domains == [.user, .system])
        #expect(values == [.init(username: nil, password: "system")])
        do {
            _ = try SystemConnectionReader.readCredentials(authentication: .personal, personal: { [] },
                coreWLAN: { _ in throw NSError(domain: NSOSStatusErrorDomain, code: 4097) })
            Issue.record("Expected original system status")
        } catch let error as SystemImportError {
            #expect(error.localizedDescription.contains("4097"))
        }
    }

    @Test func enterpriseAndOpenNetworksDoNotUsePersonalPasswordLookup() throws {
        for authentication in [WiFiAuthentication.enterprise, .open] {
            var calls = 0
            let values = try SystemConnectionReader.readCredentials(authentication: authentication,
                personal: { Issue.record("Personal path is not applicable"); return [] },
                coreWLAN: { _ in calls += 1; return .init(username: "alice", password: "enterprise") })
            #expect(calls == (authentication == .open ? 0 : 1))
            #expect(values.count == calls)
        }
    }

    @Test func differentSavedPasswordsRemainAmbiguousAndRepeatedReferenceIsReadOnce() throws {
        var reads = 0
        let first = record(reference: Data([1]))
        let reader = PersonalWiFiKeychainReader { query in
            if query[kSecReturnData as String] == nil {
                return (errSecSuccess, [first, first, record(reference: Data([2]))] as CFArray)
            }
            reads += 1
            return (errSecSuccess, record(password: Data("password-\(reads)".utf8)) as CFDictionary)
        }
        let values = try reader.read(ssid: "热点 Café")
        #expect(reads == 2)
        #expect(throws: SystemImportError.self) {
            try SystemConnectionReader.resolve(ssid: "热点 Café", authentication: .personal, credentials: values)
        }
    }

    @Test func wrongNetworkOrUnrelatedServiceNeverReadsSecret() {
        var unrelated = record(reference: Data([1]))
        unrelated[kSecAttrService as String] = "org.wifiswitch.WiFiSwitch.accounts"
        for item in [unrelated, record(ssid: "热点 Café-Guest", reference: Data([1])), record()] {
            var calls = 0
            let reader = PersonalWiFiKeychainReader { _ in calls += 1; return (errSecSuccess, [item] as CFArray) }
            #expect(throws: SystemImportError.self) { try reader.read(ssid: "热点 Café") }
            #expect(calls == 1)
        }
    }

    @Test func disappearedChangedOrMalformedPasswordDoesNotImport() {
        let wrong = record(ssid: "Other", password: Data("secret".utf8))
        let replies: [(OSStatus, CFTypeRef?)] = [(errSecItemNotFound, nil),
            (errSecSuccess, wrong as CFDictionary), (errSecSuccess, record() as CFDictionary),
            (errSecSuccess, record(password: Data()) as CFDictionary),
            (errSecSuccess, record(password: Data([0xff])) as CFDictionary)]
        for reply in replies {
            let reader = PersonalWiFiKeychainReader { query in
                query[kSecReturnData as String] == nil ? (errSecSuccess, [record(reference: Data([1]))] as CFArray) : reply
            }
            #expect(throws: SystemImportError.self) { try reader.read(ssid: "热点 Café") }
        }
    }
}
