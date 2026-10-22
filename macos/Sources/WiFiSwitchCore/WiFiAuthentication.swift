import Foundation

public enum WiFiAuthentication: String, Codable, Equatable, Hashable {
    case enterprise, personal, open, unknown

    public var label: String {
        switch self {
        case .enterprise: return "企业认证"
        case .personal: return "Wi-Fi 密码"
        case .open: return "开放网络 · 无密码"
        case .unknown: return "连接时识别"
        }
    }
    public var requiresUsername: Bool { self == .enterprise }
    public var requiresSecret: Bool { self != .open }

    public func credentials(username: String, password: String) throws -> WiFiAssociationCredentials {
        switch self {
        case .enterprise:
            guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.missingUsername }
            guard !password.isEmpty else { throw StoreError.missingPassword }
            return .enterprise(username: username, password: password)
        case .personal:
            guard !password.isEmpty else { throw StoreError.missingPassword }
            return .personal(password: password)
        case .open: return .open
        case .unknown: throw WiFiError.unsupportedAuthentication
        }
    }
}

/// Deliberately omits the username for personal Wi-Fi and all credentials for open Wi-Fi.
public enum WiFiAssociationCredentials: Equatable {
    case enterprise(username: String, password: String)
    case personal(password: String)
    case open
}
