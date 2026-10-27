import Foundation
import Security
import Testing
@testable import WiFiSwitch

struct KeychainLabelTests {
    @Test func labelsUseAccountNameAndRemainDistinct() {
        let one = UUID(uuidString: "11111111-0000-4000-8000-000000000001")!
        let two = UUID(uuidString: "22222222-0000-4000-8000-000000000002")!
        #expect(KeychainVault.label(accountID: one, accountName: " 办公账号 ") == "WiFi Switch 账号密码 · 办公账号 [11111111]")
        #expect(KeychainVault.label(accountID: two, accountName: "办公账号") == "WiFi Switch 账号密码 · 办公账号 [22222222]")
        #expect(KeychainVault.label(accountID: one, accountName: "  ").contains("未命名账号"))
    }

    @Test @MainActor func existingPasswordIsPreservedWhenRenamingInIsolatedKeychain() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-switch-test-\(UUID().uuidString).keychain-db")
        let keychainPassword = "wifi-switch-test-only"
        var keychain: SecKeychain?
        let createStatus = keychainPassword.withCString { pointer in
            SecKeychainCreate(url.path, UInt32(keychainPassword.utf8.count), pointer, false, nil, &keychain)
        }
        #expect(createStatus == errSecSuccess)
        let isolated = try #require(keychain)
        defer { SecKeychainDelete(isolated) }
        let service = "WiFiSwitch.test.\(UUID().uuidString)"
        let vault = KeychainVault(service: service, isolatedKeychain: isolated)
        let id = UUID(), id2 = UUID()
        try vault.setPassword("synthetic-password", for: id)
        try vault.setPassword("second-password", for: id2, accountName: "项目")
        #expect(vault.updateLabel(for: id, accountName: "办公账号") == errSecSuccess)
        #expect(try vault.password(for: id) == "synthetic-password")
        #expect(try vault.password(for: id2) == "second-password")
        #expect(try await vault.readPassword(for: id) == "synthetic-password")
        #expect(try await vault.readPassword(for: UUID()) == nil)
        func itemLabel(_ id: UUID) throws -> String {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString,
                kSecAttrSynchronizable as String: false, kSecMatchSearchList as String: [isolated],
                kSecReturnAttributes as String: true]
            var result: CFTypeRef?
            #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
            return try #require((result as? [String: Any])?[kSecAttrLabel as String] as? String)
        }
        #expect(try itemLabel(id) == KeychainVault.label(accountID: id, accountName: "办公账号"))
        #expect(try itemLabel(id2) == KeychainVault.label(accountID: id2, accountName: "项目"))
        #expect(vault.updateLabel(for: id, accountName: "办公新名称") == errSecSuccess)
        #expect(try itemLabel(id).contains("办公新名称"))
        #expect(try vault.password(for: id) == "synthetic-password")
        try vault.deletePassword(for: id)
        try vault.deletePassword(for: id2)
    }
}
