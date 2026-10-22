import Foundation
import Security
import WiFiSwitchCore

struct KeychainVault: CredentialVault {
    let service: String
    init(service: String = "org.wifiswitch.WiFiSwitch.accounts") { self.service = service }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString,
         kSecAttrSynchronizable as String: false]
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

    func setPassword(_ password: String, for accountID: UUID) throws {
        let attributes = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query(accountID) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(accountID)
            item[kSecValueData as String] = Data(password.utf8)
            item[kSecAttrLabel as String] = "WiFi Switch 账号密码"
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainFailure(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainFailure(status: status)
        }
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
