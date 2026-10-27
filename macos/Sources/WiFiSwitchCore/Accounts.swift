import Foundation

public struct WiFiAccount: Identifiable, Codable, Equatable {
    public let id: UUID
    public var label: String
    public var username: String
    public var lastUsedAt: Date?
    public var networkIDs: [UUID]
    public var hasStoredSecret: Bool

    public init(id: UUID = UUID(), label: String, username: String, lastUsedAt: Date? = nil, networkIDs: [UUID] = [], hasStoredSecret: Bool = true) {
        self.id = id
        self.label = label
        self.username = username
        self.lastUsedAt = lastUsedAt
        self.networkIDs = networkIDs
        self.hasStoredSecret = hasStoredSecret
    }

    private enum CodingKeys: String, CodingKey { case id, label, username, lastUsedAt, networkIDs, hasStoredSecret }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        username = try c.decode(String.self, forKey: .username)
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        networkIDs = try c.decodeIfPresent([UUID].self, forKey: .networkIDs) ?? []
        hasStoredSecret = try c.decodeIfPresent(Bool.self, forKey: .hasStoredSecret) ?? true
    }

    public var displayName: String { label.isEmpty ? "未命名账号" : label }
}

public struct SavedWiFi: Identifiable, Codable, Equatable {
    public let id: UUID
    public let ssid: String
    public var accounts: [WiFiAccount]
    public var authentication: WiFiAuthentication

    public init(id: UUID = UUID(), ssid: String, accounts: [WiFiAccount] = [], authentication: WiFiAuthentication = .enterprise) {
        self.id = id
        self.ssid = ssid
        self.accounts = accounts
        self.authentication = authentication
    }

    private enum CodingKeys: String, CodingKey { case id, ssid, accounts, authentication }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        ssid = try c.decode(String.self, forKey: .ssid)
        accounts = try c.decode([WiFiAccount].self, forKey: .accounts)
        // Versions 1–3 supported enterprise Wi-Fi only.
        authentication = try c.decodeIfPresent(WiFiAuthentication.self, forKey: .authentication) ?? .enterprise
    }
}

public struct AutomaticReconnectFailure: Codable, Equatable {
    public let selection: SessionAccountSelection
    public let count: Int
    public let reason: String
    public let requiresCredentialReview: Bool

    init(selection: SessionAccountSelection, count: Int, reason: String, requiresCredentialReview: Bool) {
        self.selection = selection
        self.count = count
        self.reason = reason
        self.requiresCredentialReview = requiresCredentialReview
    }

    private enum CodingKeys: String, CodingKey { case selection, count, reason, requiresCredentialReview }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selection = try c.decode(SessionAccountSelection.self, forKey: .selection)
        count = try c.decode(Int.self, forKey: .count)
        reason = try c.decode(String.self, forKey: .reason)
        // Older versions stored only the retry count and a human-readable reason.
        requiresCredentialReview = try c.decodeIfPresent(Bool.self, forKey: .requiresCredentialReview) ?? false
    }
}

public struct AccountConfiguration: Codable, Equatable {
    public var version = 4
    public var networkDefinitions: [SavedWiFi]
    public var accounts: [WiFiAccount]
    public var currentConnection: SessionAccountSelection?
    public var automaticReconnectFailure: AutomaticReconnectFailure?

    /// Projection retained for connection validation. Credentials live once, at account level.
    public var networks: [SavedWiFi] {
        networkDefinitions.map { network in
            SavedWiFi(id: network.id, ssid: network.ssid,
                      accounts: accounts.filter { $0.networkIDs.contains(network.id) }, authentication: network.authentication)
        }
    }

    public init(networks: [SavedWiFi] = []) {
        networkDefinitions = networks.map { SavedWiFi(id: $0.id, ssid: $0.ssid, authentication: $0.authentication) }
        accounts = networks.flatMap { network in
            network.accounts.map { account in
                var account = account
                account.networkIDs = [network.id]
                return account
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case version, networks, accounts, currentConnection, automaticReconnectFailure }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        let networks = try c.decode([SavedWiFi].self, forKey: .networks)
        self.init(networks: networks)
        self.version = version
        if version >= 3 {
            guard networks.allSatisfy({ $0.accounts.isEmpty }) else { throw StoreError.invalidConfiguration }
            accounts = try c.decode([WiFiAccount].self, forKey: .accounts)
        }
        currentConnection = try c.decodeIfPresent(SessionAccountSelection.self, forKey: .currentConnection)
        automaticReconnectFailure = try c.decodeIfPresent(AutomaticReconnectFailure.self, forKey: .automaticReconnectFailure)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(version < 3 ? networks : networkDefinitions, forKey: .networks)
        if version >= 3 { try c.encode(accounts, forKey: .accounts) }
        try c.encodeIfPresent(currentConnection, forKey: .currentConnection)
        try c.encodeIfPresent(automaticReconnectFailure, forKey: .automaticReconnectFailure)
    }

    public func validate() throws {
        if let failure = automaticReconnectFailure {
            guard (1...3).contains(failure.count), failure.selection == currentConnection else {
                throw StoreError.invalidConfiguration
            }
        }
        guard (1...4).contains(version),
              networkDefinitions.allSatisfy({ $0.accounts.isEmpty }),
              Set(networkDefinitions.map(\.id)).count == networkDefinitions.count,
              Set(networkDefinitions.map(\.ssid)).count == networkDefinitions.count,
              Set(accounts.map(\.id)).count == accounts.count else { throw StoreError.invalidConfiguration }
        let networkIDs = Set(networkDefinitions.map(\.id))
        for account in accounts {
            guard (version >= 4 || !account.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                  Set(account.networkIDs).count == account.networkIDs.count,
                  Set(account.networkIDs).isSubset(of: networkIDs) else { throw StoreError.invalidConfiguration }
        }
        for network in networks {
            try validateSSID(network.ssid)
            let usernames = network.accounts.map(\.username).filter { !$0.isEmpty }
            guard Set(usernames).count == usernames.count else { throw StoreError.duplicateAccount }
        }
    }
}

public enum StoreError: LocalizedError {
    case invalidSSID, missingUsername, missingPassword, duplicateNetwork, duplicateAccount
    case notFound, networkNotEmpty, invalidConfiguration, rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .invalidSSID: return "Wi-Fi 名称不能为空，且最多为 32 个 UTF-8 字节。"
        case .missingUsername: return "请输入用户名。"
        case .missingPassword: return "请输入密码。"
        case .duplicateNetwork: return "这个 Wi-Fi 已经在列表中。"
        case .duplicateAccount: return "此 Wi-Fi 已关联另一个同名登录账号，请先检查关联。"
        case .notFound: return "没有找到这个 Wi-Fi 或账号，请重新打开列表。"
        case .networkNotEmpty: return "请先删除该 Wi-Fi 下的账号，再移除 Wi-Fi。"
        case .invalidConfiguration: return "账号列表格式不正确或版本不受支持。已停止写入，原文件保持不变。"
        case .rollbackFailed: return "保存失败，且钥匙串恢复未完成。请重新编辑这个账号的密码后再切换。"
        }
    }
}

private func validateSSID(_ ssid: String) throws {
    guard !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          ssid.utf8.count <= 32, !ssid.contains("\0") else { throw StoreError.invalidSSID }
}

public protocol CredentialVault {
    func password(for accountID: UUID) throws -> String?
    @MainActor func readPassword(for accountID: UUID) async throws -> String?
    func setPassword(_ password: String, for accountID: UUID) throws
    func deletePassword(for accountID: UUID) throws
    func setPassword(_ password: String, for accountID: UUID, accountName: String) throws
}

public extension CredentialVault {
    @MainActor func readPassword(for accountID: UUID) async throws -> String? {
        try password(for: accountID)
    }

    func setPassword(_ password: String, for accountID: UUID, accountName: String) throws {
        try setPassword(password, for: accountID)
    }
}

public protocol ConfigurationStorage {
    func load() throws -> AccountConfiguration
    func save(_ configuration: AccountConfiguration) throws
}

public final class JSONConfigurationStorage: ConfigurationStorage {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> AccountConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return AccountConfiguration() }
        let configuration = try JSONDecoder().decode(AccountConfiguration.self, from: Data(contentsOf: url))
        try configuration.validate()
        return configuration
    }

    public func save(_ configuration: AccountConfiguration) throws {
        try configuration.validate()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        // Publish only after the complete file has been written with private permissions.
        let temporary = directory.appendingPathComponent(".accounts-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            let oldData = try Data(contentsOf: url)
            let previous = try JSONDecoder().decode(AccountConfiguration.self, from: oldData)
            if previous.version < configuration.version {
                let backup = directory.appendingPathComponent("accounts-pre-v\(configuration.version)-\(UUID().uuidString).json")
                guard FileManager.default.createFile(atPath: backup.path, contents: oldData,
                    attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}

/// Used on the UI actor. Each credential mutation rolls back if metadata cannot be saved.
public final class AccountRepository {
    public private(set) var configuration: AccountConfiguration
    private let storage: ConfigurationStorage
    private let vault: CredentialVault

    public init(storage: ConfigurationStorage, vault: CredentialVault) throws {
        self.storage = storage
        self.vault = vault
        configuration = try storage.load()
        try configuration.validate()
        // v1 needs the existing one-time current-connection migration after SSID access.
        if (2...3).contains(configuration.version) { try commit(configuration) }
    }

    @discardableResult
    public func addNetwork(ssid: String, authentication: WiFiAuthentication = .enterprise) throws -> UUID {
        try validateSSID(ssid)
        guard !configuration.networkDefinitions.contains(where: { $0.ssid == ssid }) else { throw StoreError.duplicateNetwork }
        let network = SavedWiFi(ssid: ssid, authentication: authentication)
        var next = configuration
        next.networkDefinitions.append(network)
        try commit(next)
        return network.id
    }

    public func removeNetwork(id: UUID) throws {
        guard let network = configuration.networks.first(where: { $0.id == id }) else { throw StoreError.notFound }
        guard network.accounts.isEmpty else { throw StoreError.networkNotEmpty }
        var next = configuration
        next.networkDefinitions.removeAll { $0.id == id }
        if next.currentConnection?.networkID == id { next.currentConnection = nil }
        try commit(next)
    }

    @discardableResult
    public func saveAccount(networkID: UUID, accountID: UUID? = nil, label: String,
                            username: String, newPassword: String?) throws -> UUID {
        guard let network = configuration.networks.first(where: { $0.id == networkID }),
              accountID == nil || network.accounts.contains(where: { $0.id == accountID }) else { throw StoreError.notFound }
        return try saveAccount(accountID: accountID, label: label, username: username, newPassword: newPassword,
                               networkIDs: accountID == nil ? [networkID] : nil)
    }

    @discardableResult
    public func saveAccount(accountID: UUID? = nil, label: String, username: String,
                            newPassword: String?, networkIDs: [UUID]? = nil,
                            networkSSIDs: [String]? = nil,
                            networkAuthentications: [String: WiFiAuthentication] = [:]) throws -> UUID {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldAccount = configuration.accounts.first { $0.id == accountID }
        if accountID != nil && oldAccount == nil { throw StoreError.notFound }
        if let newPassword, newPassword.isEmpty { throw StoreError.missingPassword }
        guard networkIDs == nil || networkSSIDs == nil else { throw StoreError.invalidConfiguration }
        var next = configuration
        var associatedIDs = networkIDs ?? oldAccount?.networkIDs ?? []
        if let networkSSIDs {
            associatedIDs = []
            for ssid in networkSSIDs {
                try validateSSID(ssid)
                var network = next.networkDefinitions.first(where: { $0.ssid == ssid }) ?? SavedWiFi(ssid: ssid)
                if let authentication = networkAuthentications[ssid] { network.authentication = authentication }
                if let index = next.networkDefinitions.firstIndex(where: { $0.id == network.id }) { next.networkDefinitions[index] = network }
                else { next.networkDefinitions.append(network) }
                if !associatedIDs.contains(network.id) { associatedIDs.append(network.id) }
            }
        }
        let selectedNetworks = next.networkDefinitions.filter { associatedIDs.contains($0.id) }
        if selectedNetworks.contains(where: { $0.authentication.requiresUsername }) && username.isEmpty { throw StoreError.missingUsername }
        let hasStoredSecret = newPassword != nil || oldAccount?.hasStoredSecret == true
        if !hasStoredSecret && (selectedNetworks.contains(where: { $0.authentication.requiresSecret }) || (accountID == nil && selectedNetworks.isEmpty)) {
            throw StoreError.missingPassword
        }
        let id = accountID ?? UUID()
        let account = WiFiAccount(id: id, label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username, lastUsedAt: oldAccount?.lastUsedAt, networkIDs: associatedIDs, hasStoredSecret: hasStoredSecret)
        if let index = next.accounts.firstIndex(where: { $0.id == id }) { next.accounts[index] = account }
        else { next.accounts.append(account) }
        try next.validate()
        let oldPassword = newPassword != nil ? try vault.password(for: id) : nil
        let passwordChanged = newPassword != nil && newPassword != oldPassword
        if let current = next.currentConnection, current.accountID == id,
           (current.username != username || passwordChanged || !account.networkIDs.contains(current.networkID)) {
            next.currentConnection = nil
            next.automaticReconnectFailure = nil
        }
        if passwordChanged, let newPassword { try vault.setPassword(newPassword, for: id, accountName: account.displayName) }
        do { try commit(next) } catch {
            if passwordChanged {
                do { try restore(oldPassword, for: id, accountName: oldAccount?.displayName) } catch { throw StoreError.rollbackFailed }
            }
            throw error
        }
        return id
    }

    public func linkNetwork(accountID: UUID, ssid: String, authentication: WiFiAuthentication? = nil) throws {
        try validateSSID(ssid)
        guard let index = configuration.accounts.firstIndex(where: { $0.id == accountID }) else { throw StoreError.notFound }
        var next = configuration
        var network = next.networkDefinitions.first(where: { $0.ssid == ssid }) ?? SavedWiFi(ssid: ssid, authentication: authentication ?? .unknown)
        if let authentication { network.authentication = authentication }
        if network.authentication.requiresUsername && next.accounts[index].username.isEmpty { throw StoreError.missingUsername }
        if network.authentication.requiresSecret && !next.accounts[index].hasStoredSecret { throw StoreError.missingPassword }
        guard !next.accounts[index].networkIDs.contains(network.id) else { throw StoreError.duplicateNetwork }
        if let ni = next.networkDefinitions.firstIndex(where: { $0.id == network.id }) { next.networkDefinitions[ni] = network }
        else { next.networkDefinitions.append(network) }
        next.accounts[index].networkIDs.append(network.id)
        try commit(next)
    }

    public func unlinkNetwork(accountID: UUID, networkID: UUID) throws {
        guard let index = configuration.accounts.firstIndex(where: { $0.id == accountID }),
              configuration.accounts[index].networkIDs.contains(networkID) else { throw StoreError.notFound }
        var next = configuration
        next.accounts[index].networkIDs.removeAll { $0 == networkID }
        if next.currentConnection?.accountID == accountID && next.currentConnection?.networkID == networkID {
            next.currentConnection = nil
        }
        try commit(next)
    }

    public func deleteAccount(networkID: UUID, accountID: UUID) throws {
        guard configuration.networks.contains(where: { $0.id == networkID && $0.accounts.contains(where: { $0.id == accountID }) })
        else { throw StoreError.notFound }
        try deleteAccount(accountID: accountID)
    }

    public func deleteAccount(accountID: UUID) throws {
        guard let account = configuration.accounts.first(where: { $0.id == accountID }) else { throw StoreError.notFound }
        let oldPassword = account.hasStoredSecret ? try vault.password(for: accountID) : nil
        var next = configuration
        next.accounts.removeAll { $0.id == accountID }
        if next.currentConnection?.accountID == accountID { next.currentConnection = nil }
        if account.hasStoredSecret { try vault.deletePassword(for: accountID) }
        do { try commit(next) } catch {
            if account.hasStoredSecret {
                do { try restore(oldPassword, for: accountID, accountName: account.displayName) } catch { throw StoreError.rollbackFailed }
            }
            throw error
        }
    }

    public func password(for accountID: UUID) throws -> String {
        guard let account = configuration.accounts.first(where: { $0.id == accountID }) else { throw StoreError.notFound }
        guard account.hasStoredSecret else { return "" }
        guard let password = try vault.password(for: accountID), !password.isEmpty else { throw StoreError.missingPassword }
        return password
    }

    /// Interactive vaults can suspend without blocking the UI while authorization is pending.
    @MainActor public func readPassword(for accountID: UUID) async throws -> String {
        guard let account = configuration.accounts.first(where: { $0.id == accountID }) else { throw StoreError.notFound }
        guard account.hasStoredSecret else { return "" }
        guard let password = try await vault.readPassword(for: accountID), !password.isEmpty else { throw StoreError.missingPassword }
        return password
    }

    public func markUsed(networkID: UUID, accountID: UUID, at date: Date = Date()) throws {
        var next = configuration
        guard let index = next.accounts.firstIndex(where: { $0.id == accountID && $0.networkIDs.contains(networkID) }) else { throw StoreError.notFound }
        next.accounts[index].lastUsedAt = date
        try commit(next)
    }

    public func rememberConnection(_ selection: SessionAccountSelection, connectedAt: Date? = nil) throws {
        guard selection.isValid(connectedSSID: selection.ssid, networks: configuration.networks) else { throw StoreError.notFound }
        var next = configuration
        next.currentConnection = selection
        next.automaticReconnectFailure = nil
        if let connectedAt, let index = next.accounts.firstIndex(where: { $0.id == selection.accountID }) {
            next.accounts[index].lastUsedAt = connectedAt
        }
        try commit(next)
    }

    public func clearRememberedConnection() throws {
        guard configuration.currentConnection != nil || configuration.version == 1 else { return }
        var next = configuration
        next.currentConnection = nil
        try commit(next)
    }

    public func recordAutomaticReconnectFailure(for selection: SessionAccountSelection, reason: String,
                                                requiresCredentialReview: Bool = false) throws {
        guard configuration.currentConnection == selection else { throw StoreError.notFound }
        var next = configuration
        let previous = next.automaticReconnectFailure
        let count = previous?.selection == selection ? previous!.count : 0
        next.automaticReconnectFailure = AutomaticReconnectFailure(selection: selection, count: min(3, count + 1), reason: reason,
            requiresCredentialReview: requiresCredentialReview || (previous?.requiresCredentialReview == true))
        try commit(next)
    }

    public func clearAutomaticReconnectFailure() throws {
        guard configuration.automaticReconnectFailure != nil else { return }
        var next = configuration
        next.automaticReconnectFailure = nil
        try commit(next)
    }

    public func migrateConnectionRecord(connectedSSID: String?) throws {
        guard configuration.version == 1 else { return }
        var next = configuration
        next.currentConnection = nil
        if let network = next.networks.first(where: { $0.ssid == connectedSSID }),
           let latest = network.accounts.compactMap(\.lastUsedAt).max() {
            let candidates = network.accounts.filter { $0.lastUsedAt == latest }
            if candidates.count == 1 {
                next.currentConnection = SessionAccountSelection(network: network, account: candidates[0], source: .successfulSwitch)
            }
        }
        try commit(next)
    }

    private func commit(_ configuration: AccountConfiguration) throws {
        var next = configuration
        next.version = 4
        if next.automaticReconnectFailure?.selection != next.currentConnection {
            next.automaticReconnectFailure = nil
        }
        try next.validate()
        try storage.save(next)
        self.configuration = next
    }

    private func restore(_ password: String?, for id: UUID, accountName: String?) throws {
        if let password, let accountName { try vault.setPassword(password, for: id, accountName: accountName) }
        else if let password { try vault.setPassword(password, for: id) }
        else { try vault.deletePassword(for: id) }
    }
}
