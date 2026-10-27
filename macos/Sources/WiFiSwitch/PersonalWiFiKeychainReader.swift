import Foundation
import Security

/// Exact-item reads for imports and credential verification; identity polling never reads secrets.
struct PersonalWiFiKeychainReader {
    typealias CopyMatching = ([String: Any]) -> (OSStatus, CFTypeRef?)
    private let copyMatching: CopyMatching

    init(copyMatching: @escaping CopyMatching = { query in
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }) {
        self.copyMatching = copyMatching
    }

    static func searchQuery(ssid: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "AirPort",
         kSecAttrAccount as String: ssid,
         kSecReturnAttributes as String: true,
         kSecReturnPersistentRef as String: true,
         kSecMatchLimit as String: kSecMatchLimitAll]
    }

    static func passwordQuery(reference: Data) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecMatchItemList as String: [reference],
         kSecMatchLimit as String: kSecMatchLimitOne,
         kSecReturnAttributes as String: true,
         kSecReturnData as String: true]
    }

    func read(ssid: String, authorizationPrompt: String? = nil) throws -> [SystemWiFiCredential] {
        let (status, result) = copyMatching(Self.searchQuery(ssid: ssid))
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw SystemImportError.keychain(stage: "查找 Wi-Fi 密码条目", code: Int(status)) }
        guard let items = result as? [[String: Any]], !items.isEmpty else { throw SystemImportError.missingCredentials }
        // Enumerate references first: macOS does not allow ReturnData with MatchLimitAll.
        // The default search list includes the user's configured login/system keychains.
        var credentials: [SystemWiFiCredential] = []
        var seen = Set<Data>()
        for item in items {
            guard Self.matches(item, ssid: ssid), let reference = item[kSecValuePersistentRef as String] as? Data else {
                throw SystemImportError.missingCredentials
            }
            guard seen.insert(reference).inserted else { continue }
            var query = Self.passwordQuery(reference: reference)
            if let authorizationPrompt { query[kSecUseOperationPrompt as String] = authorizationPrompt }
            let (readStatus, value) = copyMatching(query)
            guard readStatus == errSecSuccess else { throw SystemImportError.keychain(stage: "读取 Wi-Fi 密码", code: Int(readStatus)) }
            guard let record = value as? [String: Any], Self.matches(record, ssid: ssid),
                  let data = record[kSecValueData as String] as? Data,
                  let password = String(data: data, encoding: .utf8), !password.isEmpty else {
                throw SystemImportError.missingCredentials
            }
            credentials.append(.init(username: nil, password: password))
        }
        return credentials
    }

    private static func matches(_ item: [String: Any], ssid: String) -> Bool {
        item[kSecAttrService as String] as? String == "AirPort" && item[kSecAttrAccount as String] as? String == ssid
    }
}
