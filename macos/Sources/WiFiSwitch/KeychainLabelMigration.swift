import Foundation
import Security
import WiFiSwitchCore

/// Runs metadata updates in an isolated noninteractive process; no passwords are sent.
struct KeychainLabelMigration {
    struct Entry: Codable, Equatable {
        let id: UUID
        let name: String
    }

    static func runHelper() -> Int32 {
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return 1 }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard data.count <= 262_144, let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return 2 }
        let vault = KeychainVault()
        var failed = false
        for entry in entries {
            let status = vault.updateLabel(for: entry.id, accountName: entry.name)
            if status != errSecSuccess {
                failed = true
                CredentialDiagnostics.record(.keychainLabelUpdateFailed, errorCode: Int(status))
            }
        }
        return failed ? 3 : 0
    }

    static func migrate(_ accounts: [WiFiAccount]) async {
        let entries = accounts.filter(\.hasStoredSecret).map { Entry(id: $0.id, name: $0.displayName) }
        guard !entries.isEmpty, let inputData = try? JSONEncoder().encode(entries), inputData.count <= 262_144 else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process(), input = Pipe()
                process.executableURL = Bundle.main.executableURL
                process.arguments = ["--update-keychain-labels"]
                process.standardInput = input
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }
                do {
                    try process.run()
                    try input.fileHandleForWriting.write(contentsOf: inputData)
                    try input.fileHandleForWriting.close()
                    if finished.wait(timeout: .now() + 4) == .timedOut { process.terminate() }
                } catch {
                    if process.isRunning { process.terminate() }
                }
                continuation.resume()
            }
        }
    }
}
