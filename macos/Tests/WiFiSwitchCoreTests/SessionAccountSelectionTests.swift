import Foundation
import Testing
@testable import WiFiSwitchCore

struct SessionAccountSelectionTests {
    private func fixture() -> (SavedWiFi, WiFiAccount) {
        let account = WiFiAccount(label: "Office", username: "alice")
        return (SavedWiFi(ssid: "Enterprise", accounts: [account]), account)
    }

    @Test func selectionOnlyAppliesToTheExactConnectedNetworkAndAccount() {
        let (network, account) = fixture()
        let selection = SessionAccountSelection(network: network, account: account, source: .manual)
        #expect(selection.isValid(connectedSSID: network.ssid, networks: [network]))
        #expect(!selection.isValid(connectedSSID: nil, networks: [network]))
        #expect(!selection.isValid(connectedSSID: "Other", networks: [network]))
        #expect(!selection.isValid(connectedSSID: "enterprise", networks: [network]))
    }

    @Test func editedUsernameAndDeletedAccountInvalidateSelection() {
        var (network, account) = fixture()
        let selection = SessionAccountSelection(network: network, account: account, source: .successfulSwitch)
        network.accounts[0].username = "bob"
        #expect(!selection.isValid(connectedSSID: network.ssid, networks: [network]))
        network.accounts = []
        #expect(!selection.isValid(connectedSSID: network.ssid, networks: [network]))
    }

    @Test func recreatedNetworkCannotInheritOldSelection() {
        let (network, account) = fixture()
        let selection = SessionAccountSelection(network: network, account: account, source: .manual)
        let replacement = SavedWiFi(ssid: network.ssid, accounts: [account])
        #expect(!selection.isValid(connectedSSID: network.ssid, networks: [replacement]))
    }

    @Test func successfulSwitchHasCurrentAccountBadgeAndManualMarkRemainsExplicit() {
        let (network, account) = fixture()
        let manual = SessionAccountSelection(network: network, account: account, source: .manual)
        let requested = SessionAccountSelection(network: network, account: account, source: .successfulSwitch)
        #expect(manual.source.label == "当前账号 · 手动标记")
        #expect(requested.source.label == "当前账号")
        #expect(manual != requested)
    }
}
