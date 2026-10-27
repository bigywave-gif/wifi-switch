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

enum SystemCredentialSource: String, Codable {
    case standardPersonal, user, system
}

struct SystemConnectionConfiguration {
    let identity: SystemConnectionIdentity
    let password: String?
    var source: SystemCredentialSource? = nil
}

protocol SystemConnectionReading {
    func identity(ssid: String) async -> SystemConnectionIdentity?
    func configuration(ssid: String) async throws -> SystemConnectionConfiguration
    func configuration(ssid: String, authorizationPrompt: String) async throws -> SystemConnectionConfiguration
    func configuration(ssid: String, authorizationPrompt: String,
                       prepareAccess: @escaping @MainActor (SystemCredentialSource) async throws -> Void) async throws -> SystemConnectionConfiguration
}

extension SystemConnectionReading {
    func configuration(ssid: String, authorizationPrompt: String) async throws -> SystemConnectionConfiguration {
        try await configuration(ssid: ssid)
    }
    func configuration(ssid: String, authorizationPrompt: String,
                       prepareAccess: @escaping @MainActor (SystemCredentialSource) async throws -> Void) async throws -> SystemConnectionConfiguration {
        try await prepareAccess(.user)
        return try await configuration(ssid: ssid, authorizationPrompt: authorizationPrompt)
    }
}

enum SystemImportError: LocalizedError {
    case connectionChanged, unavailable, ambiguous, duplicate, storage, accountChanged
    case missingCredentials
    case authenticationUnavailable
    case savedPasswordUnverified
    case keychain(stage: String, code: Int)
    var errorDescription: String? {
        switch self {
        case .savedPasswordUnverified: return "保存后的密码未能核验，尚未确认更新成功。请重新核对；诊断记录位于 ~/Library/Logs/WiFiSwitch/credential-sync.log。"
        case .accountChanged: return "账号或系统身份已变化，请关闭窗口并重新核对，未更新密码。"
        case .connectionChanged: return "当前 Wi-Fi 已变化或尚未连接完成，请重新打开配置窗口。"
        case .unavailable: return "未能读取完整的系统 Wi-Fi 配置。可能未保存凭据、未获钥匙串授权，或使用了证书认证。可取消后手动添加账号。"
        case .ambiguous: return "系统中存在不同的账号凭据，无法确定要导入哪一组。请手动添加，避免保存错误账号。"
        case .duplicate: return "此 Wi-Fi 已有对应账号。为避免覆盖已有密码，请取消后编辑该账号。"
        case .storage: return "配置保存失败，未完成保存。请检查配置文件和钥匙串访问权限后重试。"
        case .missingCredentials: return "未读取到此 Wi-Fi 完整的系统凭据，尚未保存配置。请确认系统已保存密码，或取消后手动添加。"
        case .authenticationUnavailable: return "无法确认当前 Wi-Fi 的认证方式，尚未读取密码。请稍后重试，或取消后手动添加。"
        case let .keychain(stage, code):
            if code == Int(errSecUserCanceled) { return "已取消钥匙串授权，未保存配置。可再次确认以重新授权。" }
            if code == Int(errSecAuthFailed) { return "钥匙串未允许读取此 Wi-Fi 的密码，未保存配置。请在系统授权窗口允许访问后重试。（\(code)）" }
            if code == Int(errSecInteractionNotAllowed) { return "钥匙串当前不允许交互，请解锁 Mac 和登录钥匙串后重试。（\(code)）" }
            return "\(stage)失败（系统错误码 \(code)），未保存配置。请重试或取消后手动添加。"
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
        try await configuration(ssid: ssid, authorizationPrompt: "读取 Wi-Fi“\(ssid)”的系统钥匙串信息以核对账户。")
    }

    func configuration(ssid: String, authorizationPrompt: String) async throws -> SystemConnectionConfiguration {
        try await configuration(ssid: ssid, authorizationPrompt: authorizationPrompt, prepareAccess: { _ in })
    }

    func configuration(ssid: String, authorizationPrompt: String,
                       prepareAccess: @escaping @MainActor (SystemCredentialSource) async throws -> Void) async throws -> SystemConnectionConfiguration {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let interface = try Self.connectedInterface(ssid: ssid)
                    let authentication = Self.authentication(interface.security())
                    guard authentication != .unknown else { throw SystemImportError.authenticationUnavailable }
                    let store = CoreWLANDefaultStore(interface: interface)
                    var source: SystemCredentialSource?
                    let credentials = try Self.readCredentials(authentication: authentication,
                        personal: { try PersonalWiFiKeychainReader().read(ssid: ssid, authorizationPrompt: authorizationPrompt) },
                        coreWLAN: { try store.read(ssid: Data(ssid.utf8), enterprise: authentication == .enterprise, domain: $0) },
                        selectedSource: { source = $0 }, prepareAccess: { source in
                            // This worker must wait until the main actor has rendered the
                            // matching explanation before CoreWLAN can request permission.
                            let ready = DispatchSemaphore(value: 0)
                            var preparation: Result<Void, Error>?
                            Task { @MainActor in
                                do { try await prepareAccess(source); preparation = .success(()) }
                                catch { preparation = .failure(error) }
                                ready.signal()
                            }
                            ready.wait()
                            try preparation!.get()
                        })
                    var result = try Self.resolve(ssid: ssid, authentication: authentication, credentials: credentials)
                    result.source = source
                    let checkedInterface = try Self.connectedInterface(ssid: ssid)
                    guard Self.authentication(checkedInterface.security()) == authentication else { throw SystemImportError.connectionChanged }
                    continuation.resume(returning: result)
                } catch let error as SystemImportError { continuation.resume(throwing: error) }
                catch { continuation.resume(throwing: SystemImportError.unavailable) }
            }
        }
    }

    static func readCredentials(authentication: WiFiAuthentication,
                                personal: () throws -> [SystemWiFiCredential],
                                coreWLAN: (SystemCredentialDomain) throws -> SystemWiFiCredential?,
                                selectedSource: (SystemCredentialSource) -> Void = { _ in },
                                prepareAccess: (SystemCredentialSource) throws -> Void = { _ in }) throws -> [SystemWiFiCredential] {
        if authentication == .open { return [] }
        guard authentication != .unknown else { throw SystemImportError.authenticationUnavailable }
        if authentication == .personal {
            try prepareAccess(.standardPersonal)
            let saved = try personal()
            if !saved.isEmpty { selectedSource(.standardPersonal); return saved }
            // Only fall back when no standard AirPort item exists. Cancellation or denial must stop.
        }
        // Import and silent comparison share a user-first lookup. Reading a second
        // domain after success can trigger an unnecessary System.keychain admin prompt.
        // Only an absent item permits fallback; errors and incomplete items must stop.
        for domain in [SystemCredentialDomain.user, .system] {
            try prepareAccess(domain == .user ? .user : .system)
            let value: SystemWiFiCredential?
            do {
                value = try coreWLAN(domain)
            } catch {
                throw SystemImportError.keychain(stage: domain == .user ? "读取用户钥匙串" : "读取系统钥匙串", code: (error as NSError).code)
            }
            guard let value else { continue }
            guard value.password?.isEmpty == false,
                  !authentication.requiresUsername || value.username?.isEmpty == false else {
                throw SystemImportError.missingCredentials
            }
            selectedSource(domain == .user ? .user : .system)
            return [value]
        }
        return []
    }

    static func resolve(ssid: String, authentication: WiFiAuthentication, credentials: [SystemWiFiCredential]) throws -> SystemConnectionConfiguration {
        if authentication == .open {
            return .init(identity: .init(ssid: ssid, authentication: .open, username: nil), password: nil)
        }
        guard authentication != .unknown, let first = credentials.first,
              let password = first.password, !password.isEmpty,
              authentication != .enterprise || first.username?.isEmpty == false else { throw SystemImportError.missingCredentials }
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

    static func authentication(_ security: CWSecurity) -> WiFiAuthentication {
        switch security {
        case .wpaEnterprise, .wpa2Enterprise, .wpaEnterpriseMixed, .dynamicWEP, .enterprise, .wpa3Enterprise: return .enterprise
        case .wpaPersonal, .wpa2Personal, .wpaPersonalMixed, .personal, .wpa3Personal, .wpa3Transition, .WEP: return .personal
        case .none, .OWE, .oweTransition: return .open
        default: return .unknown
        }
    }
}
