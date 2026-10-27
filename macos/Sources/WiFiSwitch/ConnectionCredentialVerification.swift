import Foundation
import WiFiSwitchCore

/// Deduplicates interactive-capable reads, not permissions. macOS owns Keychain access grants.
@MainActor final class ConnectionCredentialVerificationGate {
    private var ssid: String?
    private var attempted: (identity: SystemConnectionIdentity, account: WiFiAccount)?
    private var succeeded = false
    private var connectionEvent = false

    func observe(ssid: String?) {
        guard self.ssid != ssid else { return }
        self.ssid = ssid
        attempted = nil
        succeeded = false
        connectionEvent = false
    }
    func invalidatePendingRead() { attempted = nil; succeeded = false }
    func connectionChanged() { connectionEvent = true }
    func claim(identity: SystemConnectionIdentity, account: WiFiAccount) -> Bool {
        if attempted?.identity == identity, attempted?.account == account {
            // A failed/cancelled attempt never loops on polling or duplicate link notifications.
            // A debounced reconnect rechecks previously successful reads using the same reader.
            guard connectionEvent, succeeded else { return false }
        }
        attempted = (identity, account)
        connectionEvent = false
        succeeded = false
        return true
    }
    func completed(result: SystemCredentialComparison) {
        succeeded = result != .unavailable
    }
}
