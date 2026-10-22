import Foundation
import WiFiSwitchCore

struct MenuConnectionChoice: Identifiable {
    struct ID: Hashable { let account: UUID; let network: UUID }
    let account: WiFiAccount
    let network: SavedWiFi
    var id: ID { ID(account: account.id, network: network.id) }

    /// Exclude only the confirmed active pair, keeping alternate accounts on the same SSID.
    static func otherConnections(accounts: [WiFiAccount], networks: [SavedWiFi],
                                 connectedSSID: String?, connectedAccountID: UUID?) -> [Self] {
        accounts.flatMap { account in
            networks.compactMap { network in
                guard network.accounts.contains(where: { $0.id == account.id }),
                      !(network.ssid == connectedSSID && account.id == connectedAccountID) else { return nil }
                return Self(account: account, network: network)
            }
        }
    }
}
