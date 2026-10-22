import Foundation

/// Tracks the account used by a completed app switch, or an explicitly manual label.
/// A remembered account is restored only after checking the connected Wi-Fi.
public struct SessionAccountSelection: Equatable, Codable {
    public enum Source: String, Equatable, Codable {
        case manual
        case successfulSwitch
        case restoredConnection
        case systemSavedCredentials

        public var isAutomatic: Bool { self != .manual }

        public var label: String {
            switch self {
            case .systemSavedCredentials: return "当前账号 · 系统保存配置"
            case .manual: return "当前账号 · 手动标记"
            case .successfulSwitch, .restoredConnection: return "当前账号"
            }
        }
    }

    public let networkID: UUID
    public let ssid: String
    public let accountID: UUID
    public let username: String
    public let source: Source

    public init(network: SavedWiFi, account: WiFiAccount, source: Source) {
        networkID = network.id
        ssid = network.ssid
        accountID = account.id
        username = account.username
        self.source = source
    }

    public func isValid(connectedSSID: String?, networks: [SavedWiFi]) -> Bool {
        guard connectedSSID == ssid,
              let network = networks.first(where: { $0.id == networkID && $0.ssid == ssid }) else { return false }
        return network.accounts.contains { $0.id == accountID && $0.username == username }
    }

    public func restored(networks: [SavedWiFi]) -> SessionAccountSelection? {
        guard let network = networks.first(where: { $0.id == networkID }),
              let account = network.accounts.first(where: { $0.id == accountID }),
              isValid(connectedSSID: network.ssid, networks: networks) else { return nil }
        return SessionAccountSelection(network: network, account: account,
            source: source == .manual || source == .systemSavedCredentials ? source : .restoredConnection)
    }
}
