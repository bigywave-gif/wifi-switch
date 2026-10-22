import CoreWLAN
import Foundation
import Security
import WiFiSwitchCore

/// Saved system identity, not evidence of which EAP identity the server accepted.
struct SystemConnectionIdentity: Codable, Equatable {
    let ssid: String
    let authentication: WiFiAuthentication
    let username: String?
}

struct SystemConnectionConfiguration {
    let identity: SystemConnectionIdentity
    let password: String?
}

protocol SystemConnectionReading {
    func identity(ssid: String) async -> SystemConnectionIdentity?
    func configuration(ssid: String) async throws -> SystemConnectionConfiguration
}

enum SystemImportError: LocalizedError {
    case connectionChanged, unavailable, ambiguous, duplicate, storage
    var errorDescription: String? {
        switch self {
        case .connectionChanged: return "当前 Wi-Fi 已变化或尚未连接完成，请重新打开添加窗口。"
        case .unavailable: return "未能读取完整的系统 Wi-Fi 配置。可能未保存凭据、未获钥匙串授权，或使用了证书认证。可取消后手动添加账号。"
        case .ambiguous: return "系统中存在不同的账号凭据，无法确定要导入哪一组。请手动添加，避免保存错误账号。"
        case .duplicate: return "此 Wi-Fi 已有对应账号。为避免覆盖已有密码，请取消后编辑该账号。"
        case .storage: return "配置保存失败，未完成添加。请检查配置文件和钥匙串访问权限后重试。"
        }
    }
}

final class SystemConnectionReader: SystemConnectionReading {
    private let queue = DispatchQueue(label: "WiFiSwitch.system-import")

    func identity(ssid: String) async -> SystemConnectionIdentity? {
        // Isolate legacy Keychain no-interaction settings from interactive imports.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let output = Pipe()
                process.executableURL = Bundle.main.executableURL
                process.arguments = ["--system-identity", ssid]
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }
                do { try process.run() } catch { continuation.resume(returning: nil); return }
                if finished.wait(timeout: .now() + 4) == .timedOut {
                    process.terminate()
                    continuation.resume(returning: nil)
                    return
                }
                guard process.terminationStatus == 0 else { continuation.resume(returning: nil); return }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let value = try? JSONDecoder().decode(SystemConnectionIdentity.self, from: data)
                continuation.resume(returning: value?.ssid == ssid ? value : nil)
            }
        }
    }

    func configuration(ssid: String) async throws -> SystemConnectionConfiguration {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let interface = try Self.connectedInterface(ssid: ssid)
                    let authentication = Self.authentication(interface.security())
                    guard authentication != .unknown else { throw SystemImportError.unavailable }
                    let store = CoreWLANDefaultStore(interface: interface)
                    var credentials: [SystemWiFiCredential] = []
                    if authentication != .open {
                        for domain in SystemCredentialDomain.allCases {
                            if let credential = try store.read(ssid: Data(ssid.utf8), enterprise: authentication == .enterprise, domain: domain) {
                                credentials.append(credential)
                            }
                        }
                    }
                    let result = try Self.resolve(ssid: ssid, authentication: authentication, credentials: credentials)
                    _ = try Self.connectedInterface(ssid: ssid)
                    guard Self.authentication(interface.security()) == authentication else { throw SystemImportError.connectionChanged }
                    continuation.resume(returning: result)
                } catch let error as SystemImportError { continuation.resume(throwing: error) }
                catch { continuation.resume(throwing: SystemImportError.unavailable) }
            }
        }
    }

    static func resolve(ssid: String, authentication: WiFiAuthentication, credentials: [SystemWiFiCredential]) throws -> SystemConnectionConfiguration {
        if authentication == .open {
            return .init(identity: .init(ssid: ssid, authentication: .open, username: nil), password: nil)
        }
        guard authentication != .unknown, let first = credentials.first,
              let password = first.password, !password.isEmpty,
              authentication != .enterprise || first.username?.isEmpty == false else { throw SystemImportError.unavailable }
        guard credentials.allSatisfy({ $0 == first }) else { throw SystemImportError.ambiguous }
        return .init(identity: .init(ssid: ssid, authentication: authentication,
                                    username: authentication == .enterprise ? first.username : nil), password: password)
    }

    /// Runs only in the short-lived helper, before starting AppKit or the model.
    static func runIdentityHelper(ssid: String) -> Int32 {
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return 2 }
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn(),
              interfaceHasUsableAddress(interface) else { return 3 }
        // A child process may not inherit location access and may receive nil SSID.
        // The caller supplies an observed SSID and rechecks it after this read.
        if let currentSSID = interface.ssid(), currentSSID != ssid { return 4 }
        let authentication = authentication(interface.security())
        guard authentication != .unknown else { return 5 }
        var username: String?
        if authentication == .enterprise {
            username = SystemIdentityAttributes.readUsername(ssid: ssid)
            guard username != nil else { return 6 }
        }
        guard interface.powerOn(), interfaceHasUsableAddress(interface),
              Self.authentication(interface.security()) == authentication else { return 7 }
        if let currentSSID = interface.ssid(), currentSSID != ssid { return 4 }
        let identity = SystemConnectionIdentity(ssid: ssid, authentication: authentication, username: username)
        guard let data = try? JSONEncoder().encode(identity), data.count < 4096 else { return 1 }
        FileHandle.standardOutput.write(data)
        return 0
    }

    private static func connectedInterface(ssid: String) throws -> CWInterface {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn(),
              interface.ssid() == ssid, interfaceHasUsableAddress(interface) else { throw SystemImportError.connectionChanged }
        return interface
    }

    private static func authentication(_ security: CWSecurity) -> WiFiAuthentication {
        switch security {
        case .wpaEnterprise, .wpa2Enterprise, .wpaEnterpriseMixed, .dynamicWEP, .enterprise, .wpa3Enterprise: return .enterprise
        case .wpaPersonal, .wpa2Personal, .wpaPersonalMixed, .personal, .wpa3Personal, .wpa3Transition, .WEP: return .personal
        case .none, .OWE, .oweTransition: return .open
        default: return .unknown
        }
    }
}
