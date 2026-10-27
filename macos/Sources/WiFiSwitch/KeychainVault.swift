import Foundation
import Security
import WiFiSwitchCore

struct KeychainVault: CredentialVault {
    let service: String
    private let isolatedKeychain: SecKeychain?
    init(service: String = "org.wifiswitch.WiFiSwitch.accounts", isolatedKeychain: SecKeychain? = nil) {
        self.service = service
        self.isolatedKeychain = isolatedKeychain
    }

    private func query(_ id: UUID) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString,
         kSecAttrSynchronizable as String: false]
        if let isolatedKeychain { query[kSecMatchSearchList as String] = [isolatedKeychain] }
        return query
    }

    func password(for accountID: UUID) throws -> String? {
        var request = query(accountID)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainFailure(status: errSecDecode)
        }
        return value
    }

    @MainActor func readPassword(for accountID: UUID) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // SecItemCopyMatching can wait for the user's authorization. Keep the
                // main run loop free to render the current account and access stage.
                continuation.resume(with: Result { try password(for: accountID) })
            }
        }
    }

    static func label(accountID: UUID, accountName: String) -> String {
        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = name.isEmpty ? "未命名账号" : name
        return "WiFi Switch 账号密码 · \(visible) [\(accountID.uuidString.prefix(8))]"
    }

    func setPassword(_ password: String, for accountID: UUID) throws {
        try writePassword(password, for: accountID, accountName: nil)
    }

    func setPassword(_ password: String, for accountID: UUID, accountName: String) throws {
        try writePassword(password, for: accountID, accountName: accountName)
    }

    private func writePassword(_ password: String, for accountID: UUID, accountName: String?) throws {
        var attributes: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        if let accountName { attributes[kSecAttrLabel as String] = Self.label(accountID: accountID, accountName: accountName) }
        let status = SecItemUpdate(query(accountID) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(accountID)
            if let isolatedKeychain {
                item.removeValue(forKey: kSecMatchSearchList as String)
                item[kSecUseKeychain as String] = isolatedKeychain
            }
            item[kSecValueData as String] = Data(password.utf8)
            item[kSecAttrLabel as String] = accountName.map { Self.label(accountID: accountID, accountName: $0) } ?? "WiFi Switch 账号密码"
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainFailure(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainFailure(status: status)
        }
    }

    /// Metadata-only update: never read or replace the stored secret or its access policy.
    func updateLabel(for accountID: UUID, accountName: String) -> OSStatus {
        SecItemUpdate(query(accountID) as CFDictionary,
                      [kSecAttrLabel as String: Self.label(accountID: accountID, accountName: accountName)] as CFDictionary)
    }

    func deletePassword(for accountID: UUID) throws {
        let status = SecItemDelete(query(accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
    }
}

struct KeychainFailure: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        if status == errSecUserCanceled { return "钥匙串访问已取消，账号资料未更新。" }
        if status == errSecInteractionNotAllowed { return "钥匙串当前不可访问，请解锁 Mac 后重试。" }
        return "钥匙串操作失败（\(status)）：\(SecCopyErrorMessageString(status, nil) as String? ?? "未知错误")"
    }
}
