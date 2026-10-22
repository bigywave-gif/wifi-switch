import Foundation
import Security

/// Only metadata is requested. Neither password data nor an item reference is returned.
enum SystemIdentityAttributes {
    static func query(ssid: String, dataProtection: Bool = false) -> [String: Any] {
        var result: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: ssid,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        if dataProtection {
            result[kSecUseDataProtectionKeychain as String] = true
            result[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        return result
    }

    static func username(ssid: String, items: [[String: Any]]) -> String? {
        var usernames = Set<String>()
        for item in items {
            guard item[kSecAttrLabel as String] as? String == ssid,
                  let service = item[kSecAttrService as String] as? String,
                  service.hasPrefix("com.apple.network.eap."),
                  service.hasSuffix(".item.wlan.ssid." + ssid) else { continue }
            guard let username = item[kSecAttrAccount as String] as? String, !username.isEmpty else { return nil }
            usernames.insert(username)
        }
        return usernames.count == 1 ? usernames.first : nil
    }

    /// Called in the no-interaction helper. Fail closed on inaccessible stores or conflicts.
    static func readUsername(ssid: String) -> String? {
        var queries = [query(ssid: ssid), query(ssid: ssid, dataProtection: true)]
        var systemKeychain: SecKeychain?
        guard SecKeychainOpen("/Library/Keychains/System.keychain", &systemKeychain) == errSecSuccess,
              let systemKeychain else { return nil }
        var systemQuery = query(ssid: ssid)
        systemQuery[kSecMatchSearchList as String] = [systemKeychain]
        queries.append(systemQuery)
        var items: [[String: Any]] = []
        for query in queries {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let attributes = result as? [[String: Any]] else { return nil }
            items.append(contentsOf: attributes)
        }
        return username(ssid: ssid, items: items)
    }
}
