import Foundation
import Security

@main
struct KeychainContinuityProbe {
    static func main() {
        do {
            guard CommandLine.arguments.count == 3,
                  let nonce = UUID(uuidString: CommandLine.arguments[2]) else {
                throw ProbeFailure()
            }
            // A missing authorization must fail, rather than silently waiting
            // for a dialog. This setting applies only to this test process.
            guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                throw ProbeFailure()
            }
            let vault = KeychainVault(service: "org.wifiswitch.WiFiSwitch.continuity.\(nonce.uuidString)")
            let accounts = [nonce, UUID(uuidString: "00000000-0000-0000-0000-000000000002")!]
            switch CommandLine.arguments[1] {
            case "seed":
                for account in accounts {
                    try vault.setPassword("synthetic-only-\(account.uuidString)", for: account)
                }
            case "check":
                for _ in 0..<3 {
                    for account in accounts {
                        guard try vault.password(for: account) == "synthetic-only-\(account.uuidString)" else {
                            throw ProbeFailure()
                        }
                    }
                }
            case "expect-denied":
                do {
                    _ = try vault.password(for: accounts[0])
                    throw ProbeFailure()
                } catch let error as KeychainFailure {
                    guard error.status == errSecInteractionNotAllowed || error.status == errSecAuthFailed else {
                        throw error
                    }
                }
            case "cleanup":
                for account in accounts { try vault.deletePassword(for: account) }
                for account in accounts {
                    guard try vault.password(for: account) == nil else { throw ProbeFailure() }
                }
            default: throw ProbeFailure()
            }
            print("PASS: \(CommandLine.arguments[1]), revision \(probeRevision)")
        } catch {
            let code = (error as? KeychainFailure)?.status ?? -1
            fputs("Keychain continuity check failed (\(code)); no password printed.\n", stderr)
            exit(1)
        }
    }
}

private struct ProbeFailure: Error {}
