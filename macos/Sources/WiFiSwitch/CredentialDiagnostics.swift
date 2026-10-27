import Foundation

/// Fixed event names only: no SSID, username, account ID, password, or password digest.
enum CredentialDiagnosticEvent: String {
    case automaticReconnectStarted, manualConnectionStarted, systemRecoveredInstead
    case associationRequestStarting, associationReturned, connectionServiceReturned, connectionServiceFailed, enterpriseAssociationVerified
    case automaticVerificationStarted, automaticVerificationCompleted, automaticVerificationFailed, keychainLabelUpdateFailed
    case importRead, savedPasswordVerified, savedPasswordVerificationFailed, backgroundRead, comparisonApplied, verificationReadFailed, importReadFailed
}

enum CredentialDiagnostics {
    private static let lock = NSLock()

    static func record(_ event: CredentialDiagnosticEvent, comparison: SystemCredentialComparison? = nil,
                       reason: CredentialComparisonReason? = nil, source: SystemCredentialSource? = nil, errorCode: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WiFiSwitch")
        let file = directory.appendingPathComponent("credential-sync.log")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            var data = (try? Data(contentsOf: file)) ?? Data()
            if data.count > 64 * 1024 { data = Data(data.suffix(32 * 1024)) }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let fields = [ISO8601DateFormatter().string(from: Date()), "v=\(version)", "pid=\(ProcessInfo.processInfo.processIdentifier)", event.rawValue,
                          comparison?.rawValue ?? "-", reason?.rawValue ?? "-", source?.rawValue ?? "-", errorCode.map(String.init) ?? "-"]
            data.append(Data((fields.joined(separator: " ") + "\n").utf8))
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* Diagnostics must never fail an import or trigger a credential read. */ }
    }
}
