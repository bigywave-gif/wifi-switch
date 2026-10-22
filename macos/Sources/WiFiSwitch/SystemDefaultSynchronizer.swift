import CoreWLAN
import Foundation
import Security
import WiFiSwitchCore

enum SystemCredentialDomain: CaseIterable { case user, system }

/// Protect the previous per-SSID credentials even if native association persists them.
struct SystemCredentialBackup {
    let store: any SystemDefaultStore
    let ssid: Data
    let enterprise: Bool
    let attempted: SystemWiFiCredential
    let saved: [(SystemCredentialDomain, SystemWiFiCredential?)]

    init(store: any SystemDefaultStore, ssid: Data, credentials: WiFiAssociationCredentials) throws {
        self.store = store; self.ssid = ssid
        switch credentials {
        case let .enterprise(username, password): enterprise = true; attempted = .init(username: username, password: password)
        case let .personal(password): enterprise = false; attempted = .init(username: nil, password: password)
        case .open: enterprise = false; attempted = .init(username: nil, password: nil)
        }
        do {
            let isEnterprise = enterprise
            saved = credentials == .open ? [] : try SystemCredentialDomain.allCases.map { ($0, try store.read(ssid: ssid, enterprise: isEnterprise, domain: $0)) }
        } catch { throw SystemCredentialPreservationError(beforeConnection: true) }
    }

    func restore() throws {
        do {
            for (domain, old) in saved {
                let current = try store.read(ssid: ssid, enterprise: enterprise, domain: domain)
                guard current != old else { continue }
                // A concurrent change from a different app/user must not be overwritten.
                guard current == attempted else { throw SystemCredentialPreservationError(beforeConnection: false) }
                try store.write(old, ssid: ssid, enterprise: enterprise, domain: domain)
                guard try store.read(ssid: ssid, enterprise: enterprise, domain: domain) == old else {
                    throw SystemCredentialPreservationError(beforeConnection: false)
                }
            }
        } catch { throw SystemCredentialPreservationError(beforeConnection: false) }
    }
}

struct SystemCredentialPreservationError: LocalizedError {
    let beforeConnection: Bool
    var errorDescription: String? {
        beforeConnection ? "无法读取原有系统账号信息，为避免覆盖系统首选账号，本次连接尚未开始。请检查钥匙串授权。" :
            "本次连接流程已结束，但未能确认原有系统账号凭据已保留。请检查系统 Wi-Fi 保存的账号；这不是密码认证失败。"
    }
}

/// Kept in memory only; never serialized, included in errors, or passed to a subprocess.
struct SystemWiFiCredential: Equatable {
    let username: String?
    let password: String?
}

protocol SystemDefaultStore {
    func isConnected(to ssid: Data) -> Bool
    func read(ssid: Data, enterprise: Bool, domain: SystemCredentialDomain) throws -> SystemWiFiCredential?
    func write(_ value: SystemWiFiCredential?, ssid: Data, enterprise: Bool, domain: SystemCredentialDomain) throws
}

/// Synchronizes only this SSID's credentials. Network ranking and Auto-Join belong to macOS.
struct SystemDefaultSynchronizer {
    let store: any SystemDefaultStore

    func save(ssid: Data, credentials: WiFiAssociationCredentials) throws {
        var stage = "读取系统 Wi-Fi 凭据"
        var saved: [(SystemCredentialDomain, SystemWiFiCredential?)] = []
        var changed: [SystemCredentialDomain] = []
        let enterprise: Bool
        let credential: SystemWiFiCredential?
        switch credentials {
        case let .enterprise(username, password):
            enterprise = true; credential = SystemWiFiCredential(username: username, password: password)
        case let .personal(password):
            enterprise = false; credential = SystemWiFiCredential(username: nil, password: password)
        case .open:
            enterprise = false; credential = nil
        }
        do {
            guard store.isConnected(to: ssid) else { throw SyncFailure.connectionChanged }
            if credential != nil {
                // Save the current user's default. If the system domain already has a
                // credential for this SSID, update it too instead of leaving a stale account.
                // Never create a new system-wide secret merely because it is absent.
                for domain in SystemCredentialDomain.allCases {
                    let old = try store.read(ssid: ssid, enterprise: enterprise, domain: domain)
                    if domain == .user || old != nil { saved.append((domain, old)) }
                }
            }
            guard store.isConnected(to: ssid) else { throw SyncFailure.connectionChanged }
            stage = "保存系统 Wi-Fi 凭据"
            for (domain, old) in saved where old != credential {
                changed.append(domain)
                try store.write(credential, ssid: ssid, enterprise: enterprise, domain: domain)
                guard try store.read(ssid: ssid, enterprise: enterprise, domain: domain) == credential else {
                    throw SyncFailure.credentialNotSaved
                }
            }
            stage = "核对系统 Wi-Fi 凭据"
            for (domain, _) in saved {
                guard try store.read(ssid: ssid, enterprise: enterprise, domain: domain) == credential else {
                    throw SyncFailure.credentialNotSaved
                }
            }
            guard store.isConnected(to: ssid) else { throw SyncFailure.connectionChanged }
        } catch {
            // A synchronization failure is not a rejected password. Revert only our
            // own writes, and retain the live connection. Never erase a whole keychain.
            var rollbackFailed = false
            for domain in changed.reversed() {
                let old = saved.first { $0.0 == domain }!.1
                do {
                    let now = try store.read(ssid: ssid, enterprise: enterprise, domain: domain)
                    if now == credential {
                        try store.write(old, ssid: ssid, enterprise: enterprise, domain: domain)
                        if try store.read(ssid: ssid, enterprise: enterprise, domain: domain) != old { rollbackFailed = true }
                    } else if now != old { rollbackFailed = true }
                } catch { rollbackFailed = true }
            }
            // Native errors can contain credential context; expose only a stage and numeric code.
            throw SystemDefaultSyncError(stage: stage, code: (error as NSError).code, rollbackFailed: rollbackFailed)
        }
    }
}

private enum SyncFailure: Int, Error {
    case connectionChanged = 1, credentialNotSaved
}

/// Uses the public CoreWLAN persistence APIs; distinct from the app's per-account vault.
final class CoreWLANDefaultStore: SystemDefaultStore {
    private let interface: CWInterface
    init(interface: CWInterface) { self.interface = interface }

    func isConnected(to ssid: Data) -> Bool {
        interface.powerOn() && interface.ssidData() == ssid && interfaceHasUsableAddress(interface)
    }
    private func keychainDomain(_ domain: SystemCredentialDomain) -> CWKeychainDomain {
        domain == .user ? .user : .system
    }
    func read(ssid: Data, enterprise: Bool, domain: SystemCredentialDomain) throws -> SystemWiFiCredential? {
        var username: NSString?
        var password: NSString?
        let result: OSStatus
        if enterprise {
            result = CWKeychainFindWiFiEAPUsernameAndPassword(keychainDomain(domain), ssid, &username, &password)
        } else {
            result = CWKeychainFindWiFiPassword(keychainDomain(domain), ssid, &password)
        }
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        return SystemWiFiCredential(username: username as String?, password: password as String?)
    }
    func write(_ value: SystemWiFiCredential?, ssid: Data, enterprise: Bool, domain: SystemCredentialDomain) throws {
        let result: OSStatus
        if enterprise {
            if let value {
                result = CWKeychainSetWiFiEAPUsernameAndPassword(keychainDomain(domain), ssid, value.username, value.password)
            } else {
                result = CWKeychainDeleteWiFiEAPUsernameAndPassword(keychainDomain(domain), ssid)
            }
        } else if let value, let password = value.password {
            result = CWKeychainSetWiFiPassword(keychainDomain(domain), ssid, password)
        } else {
            result = CWKeychainDeleteWiFiPassword(keychainDomain(domain), ssid)
        }
        guard result == errSecSuccess || (value == nil && result == errSecItemNotFound) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
    }
}
