import Foundation
import Security
import WiFiSwitchCore

struct KeychainVault: CredentialVault {
    static let defaultService = "org.wifiswitch.WiFiSwitch.accounts"
    let service: String
    private let isolatedKeychain: SecKeychain?
    init(service: String = KeychainVault.defaultService, isolatedKeychain: SecKeychain? = nil) {
        self.service = service
        self.isolatedKeychain = isolatedKeychain
    }

    /// Resolve a previous namespace from this account's metadata, never from a
    /// hardcoded personal identifier. No password is requested during discovery.
    static func resolvedService(_ services: [String]) throws -> String {
        let candidates = Set(services.filter { $0.hasSuffix(".WiFiSwitch.accounts") })
        if candidates.contains(defaultService) { return defaultService }
        guard candidates.count <= 1 else { throw KeychainFailure(status: errSecDuplicateItem) }
        return candidates.first ?? defaultService
    }

    private func existingService(_ id: UUID) throws -> String {
        guard service == Self.defaultService else { return service }
        var request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        if let isolatedKeychain { request[kSecMatchSearchList as String] = [isolatedKeychain] }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return service }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        guard let records = result as? [[String: Any]] else { throw KeychainFailure(status: errSecDecode) }
        return try Self.resolvedService(records.compactMap { $0[kSecAttrService as String] as? String })
    }

    private func query(_ id: UUID) throws -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: try existingService(id),
         kSecAttrAccount as String: id.uuidString,
         kSecAttrSynchronizable as String: false]
        if let isolatedKeychain { query[kSecMatchSearchList as String] = [isolatedKeychain] }
        return query
    }

    func password(for accountID: UUID) throws -> String? {
        var request = try query(accountID)
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
        let resolvedQuery = try query(accountID)
        let status = SecItemUpdate(resolvedQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = resolvedQuery
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
        do {
            return SecItemUpdate(try query(accountID) as CFDictionary,
                [kSecAttrLabel as String: Self.label(accountID: accountID, accountName: accountName)] as CFDictionary)
        } catch let failure as KeychainFailure { return failure.status }
        catch { return errSecInternalComponent }
    }

    func deletePassword(for accountID: UUID) throws {
        let status = SecItemDelete(try query(accountID) as CFDictionary)
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
