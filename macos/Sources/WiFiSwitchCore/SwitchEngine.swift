import Foundation

public enum SwitchPhase: Equatable {
    case finding, disconnecting, authenticating, verifying, savingSystemDefault

    public var title: String {
        switch self {
        case .finding: return "正在查找 Wi-Fi…"
        case .disconnecting: return "正在断开当前连接…"
        case .authenticating: return "正在使用所选账号认证…"
        case .verifying: return "正在确认连接与 IP 地址…"
        case .savingSystemDefault: return "正在保存此 Wi-Fi 的系统连接凭据…"
        }
    }
}

public struct LinkState: Equatable {
    public let ssid: String?
    public let hasUsableAddress: Bool
    public init(ssid: String?, hasUsableAddress: Bool) {
        self.ssid = ssid
        self.hasUsableAddress = hasUsableAddress
    }
}

public enum WiFiError: LocalizedError {
    case unavailable, poweredOff, networkNotFound, unsupportedAuthentication, ambiguousAuthentication, verificationTimeout, locationRequired, demoMode, connectionChanged

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "未找到 Wi-Fi 网卡。"
        case .poweredOff: return "Wi-Fi 已关闭，请先在系统菜单中打开 Wi-Fi。"
        case .networkNotFound: return "没有扫描到这个 Wi-Fi，请检查名称、距离和定位权限。当前连接未主动断开。"
        case .unsupportedAuthentication: return "未能识别这个 Wi-Fi 的认证方式，当前连接未主动断开。请重新扫描或检查网络配置。"
        case .ambiguousAuthentication: return "同名 Wi-Fi 存在不同的认证方式，无法安全确定目标。当前连接未主动断开，请联系网络管理员确认。"
        case .verificationTimeout: return "未能确认目标 Wi-Fi 已连接并取得 IP 地址。请检查账号、密码或系统认证弹窗，也可选择原账号重新连接。"
        case .locationRequired: return "请先允许定位权限，macOS 需要此权限才能向应用提供 Wi-Fi 名称。"
        case .demoMode: return "这是界面演示，不会连接真实 Wi-Fi。请打开正常版本进行切换。"
        case .connectionChanged: return "系统已连接其他 Wi-Fi，已停止自动重连。"
        }
    }
}

public protocol WiFiDriver {
    /// Must find and validate the exact network before disrupting the current connection.
    func prepare(ssid: String) throws -> WiFiAuthentication
    func disconnect() throws
    func associate(credentials: WiFiAssociationCredentials) throws
    func linkState() -> LinkState
    /// Called only after an explicit connection has authenticated and passed verification.
    func saveSystemDefault(credentials: WiFiAssociationCredentials) throws
    func captureSystemCredentials(credentials: WiFiAssociationCredentials) throws
    func restoreSystemCredentials() throws
}

public extension WiFiDriver {
    func captureSystemCredentials(credentials: WiFiAssociationCredentials) throws {}
    func restoreSystemCredentials() throws {}
}

public struct SystemDefaultSyncError: LocalizedError {
    public let stage: String
    public let code: Int
    public let rollbackFailed: Bool
    public init(stage: String, code: Int, rollbackFailed: Bool = false) {
        self.stage = stage; self.code = code; self.rollbackFailed = rollbackFailed
    }
    public var errorDescription: String? {
        "本次 Wi-Fi 已完成连接验证，但系统默认连接未同步（\(stage)，错误码 \(code)）。" +
        (rollbackFailed ? "部分系统设置未能恢复，请检查系统 Wi-Fi 设置。" : "未完成默认设置更新。") +
        "系统重连仍可能使用其他账号；请处理系统授权或网络管理限制后，手动重新连接。"
    }
}

/// Synchronous by design; the macOS adapter runs this entire operation on a serial worker queue.
public struct SwitchEngine {
    private let driver: WiFiDriver
    private let wait: (TimeInterval) -> Void
    private let verificationAttempts: Int

    public init(driver: WiFiDriver, verificationAttempts: Int = 30,
                wait: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.driver = driver
        self.wait = wait
        self.verificationAttempts = verificationAttempts
    }

    public func switchAccount(ssid: String, username: String, password: String,
                              synchronizeSystemCredentials: Bool = true,
                              progress: (SwitchPhase) -> Void) throws {
        progress(.finding)
        let authentication = try driver.prepare(ssid: ssid)
        let credentials = try authentication.credentials(username: username, password: password)
        if !synchronizeSystemCredentials { try driver.captureSystemCredentials(credentials: credentials) }
        do {
        progress(.disconnecting)
        try driver.disconnect()
        wait(0.5)
        progress(.authenticating)
        try driver.associate(credentials: credentials)
        try verify(ssid: ssid, progress: progress)
        } catch {
            if !synchronizeSystemCredentials { try driver.restoreSystemCredentials() }
            throw error
        }
        if synchronizeSystemCredentials {
            progress(.savingSystemDefault)
            try driver.saveSystemDefault(credentials: credentials)
        } else { try driver.restoreSystemCredentials() }
    }

    /// Recovery cooperates with system auto-join: it never deliberately disconnects
    /// the interface, and yields if macOS recovered or joined a different network.
    public func reconnectAccount(ssid: String, username: String, password: String,
                                 progress: (SwitchPhase) -> Void) throws {
        if try recoveredOrChanged(ssid: ssid) { return }
        progress(.finding)
        let authentication = try driver.prepare(ssid: ssid)
        let credentials = try authentication.credentials(username: username, password: password)
        if try recoveredOrChanged(ssid: ssid) { return }
        try driver.captureSystemCredentials(credentials: credentials)
        do {
        progress(.authenticating)
        try driver.associate(credentials: credentials)
        try verify(ssid: ssid, progress: progress)
        } catch {
            try driver.restoreSystemCredentials()
            throw error
        }
        try driver.restoreSystemCredentials()
    }

    private func recoveredOrChanged(ssid: String) throws -> Bool {
        let state = driver.linkState()
        if let current = state.ssid, current != ssid { throw WiFiError.connectionChanged }
        return state.ssid == ssid && state.hasUsableAddress
    }

    private func verify(ssid: String, progress: (SwitchPhase) -> Void) throws {
        progress(.verifying)
        var consecutiveMatches = 0
        for _ in 0..<verificationAttempts {
            wait(1)
            let state = driver.linkState()
            consecutiveMatches = state.ssid == ssid && state.hasUsableAddress ? consecutiveMatches + 1 : 0
            if consecutiveMatches >= 3 { return }
        }
        throw WiFiError.verificationTimeout
    }
}
