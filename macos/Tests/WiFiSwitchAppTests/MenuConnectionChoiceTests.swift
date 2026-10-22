import Testing
import WiFiSwitchCore
@testable import WiFiSwitch

struct MenuConnectionChoiceTests {
    @Test func activePairIsExcludedButSameWiFiWithAnotherAccountAndOtherWiFiRemain() {
        let first = WiFiAccount(label: "Work", username: "first")
        let second = WiFiAccount(label: "Test", username: "second")
        let office = SavedWiFi(ssid: "Office", accounts: [first, second])
        let home = SavedWiFi(ssid: "Home", accounts: [first])
        let choices = MenuConnectionChoice.otherConnections(accounts: [first, second], networks: [office, home],
            connectedSSID: "Office", connectedAccountID: first.id)
        #expect(choices.count == 2)
        #expect(choices[0].account.id == first.id && choices[0].network.id == home.id)
        #expect(choices[1].account.id == second.id && choices[1].network.id == office.id)
        #expect(Set(choices.map(\.id)).count == 2)
    }

    @Test func unknownOrDisconnectedAccountDoesNotHideReconnectOptions() {
        let account = WiFiAccount(label: "Work", username: "first")
        let office = SavedWiFi(ssid: "Office", accounts: [account])
        for ssid: String? in ["Office", nil, "Unmanaged"] {
            let choices = MenuConnectionChoice.otherConnections(accounts: [account], networks: [office],
                connectedSSID: ssid, connectedAccountID: nil)
            #expect(choices.count == 1)
        }
    }

    @Test func unlinkedAccountsNeverBecomeConnectableRows() {
        let account = WiFiAccount(label: "Unlinked", username: "first")
        let choices = MenuConnectionChoice.otherConnections(accounts: [account], networks: [SavedWiFi(ssid: "Office")],
            connectedSSID: nil, connectedAccountID: nil)
        #expect(choices.isEmpty)
    }
}
