import Foundation
import Testing
import WiFiSwitchCore
@testable import WiFiSwitch

struct AccountNetworkDraftTests {
    @Test func mandatoryCredentialsFollowSingleAndMixedNetworkSelections() throws {
        let nearby = [NearbyWiFi(ssid: "Office", rssi: -30, authentication: .enterprise),
                      NearbyWiFi(ssid: "Phone", rssi: -40, authentication: .personal),
                      NearbyWiFi(ssid: "Guest", rssi: -50, authentication: .open)]
        var draft = AccountNetworkDraft()
        draft.setSelected(true, ssid: "Phone")
        #expect(!draft.requiresUsername(saved: [], nearby: nearby))
        #expect(draft.requiresSecret(saved: [], nearby: nearby))
        draft.setSelected(true, ssid: "Guest")
        #expect(!draft.requiresUsername(saved: [], nearby: nearby) && draft.requiresSecret(saved: [], nearby: nearby))
        draft.setSelected(false, ssid: "Phone")
        #expect(!draft.requiresUsername(saved: [], nearby: nearby) && !draft.requiresSecret(saved: [], nearby: nearby))
        draft.setSelected(true, ssid: "Office")
        #expect(draft.requiresUsername(saved: [], nearby: nearby) && draft.requiresSecret(saved: [], nearby: nearby))
        // Stored authentication hints preserve requirements when a later scan cannot find the network.
        let saved = [SavedWiFi(ssid: "Office", authentication: .enterprise), SavedWiFi(ssid: "Guest", authentication: .open)]
        #expect(draft.requiresUsername(saved: saved, nearby: []))
        try draft.addManualSSID("Phone", nearby: nearby)
        #expect(draft.selectedSSIDs.contains("Phone"))
    }

    @MainActor @Test func savingAndConnectingOpenAccountUsesNoVaultAndRequiresNoCredentials() async throws {
        let model = AppModel(demoMode: true)
        await model.scan()
        let before = model.accounts.count
        try model.saveAccount(editor: AccountEditor(account: nil), label: "Guest", username: "", password: "", networkSSIDs: ["Guest Open"])
        let account = try #require(model.accounts.last)
        #expect(model.accounts.count == before + 1 && !account.hasStoredSecret)
        #expect(account.username.isEmpty)
        #expect(try model.savedPassword(for: AccountEditor(account: account)) == "")
        #expect(model.networks(for: account)[0].authentication == .open)
        #expect(model.switchAccount(account, on: model.networks(for: account)[0]) == nil) // Ordinary demo never connects.
    }

    @Test func mergesSavedAndScannedNetworksWithoutHidingPersonalOrHotspotNetworks() {
        var draft = AccountNetworkDraft()
        let saved = [SavedWiFi(ssid: "Office")]
        let nearby = [NearbyWiFi(ssid: "Office", rssi: -30, supportsEnterpriseAuthentication: true),
                      NearbyWiFi(ssid: "Campus", rssi: -40, supportsEnterpriseAuthentication: true),
                      NearbyWiFi(ssid: "Phone Hotspot", rssi: -50), NearbyWiFi(ssid: "Home", rssi: -60)]
        let options = draft.options(saved: saved, nearby: nearby)
        #expect(options.map(\.ssid) == ["Office", "Campus", "Phone Hotspot", "Home"])
        draft.setSelected(true, ssid: "Office")
        draft.setSelected(true, ssid: "Campus")
        draft.setSelected(true, ssid: "Campus")
        #expect(draft.selectedSSIDs == ["Office", "Campus"])
        draft.setSelected(false, ssid: "Office")
        #expect(draft.selectedSSIDs == ["Campus"])
    }

    @Test func refreshCannotLoseSelectedOfflineNetworksAndManualInputPreservesExactSSID() throws {
        var draft = AccountNetworkDraft(selectedSSIDs: ["Office", "Campus"])
        try draft.addManualSSID(" Hidden ", nearby: [])
        try draft.addManualSSID(" Hidden ", nearby: [])
        #expect(draft.selectedSSIDs == ["Office", "Campus", " Hidden "])
        #expect(draft.options(saved: [], nearby: []).map(\.ssid) == draft.selectedSSIDs)
        draft.setSelected(false, ssid: " Hidden ")
        #expect(draft.options(saved: [], nearby: []).contains { $0.ssid == " Hidden " })
        #expect(draft.selectedSSIDs == ["Office", "Campus"])
    }

    @Test func manualInvalidNetworkDoesNotChangeDraft() {
        var draft = AccountNetworkDraft(selectedSSIDs: ["Office"])
        let nearby = [NearbyWiFi(ssid: "Phone Hotspot", rssi: -50)]
        for ssid in ["", "  ", "Bad\0SSID", String(repeating: "网", count: 11)] {
            #expect(throws: (any Error).self) { try draft.addManualSSID(ssid, nearby: nearby) }
            #expect(draft.selectedSSIDs == ["Office"] && draft.manualSSIDs.isEmpty)
        }
    }

    @MainActor @Test func editorSelectionSavesMultipleNetworksWithoutConnectingOrChangingCurrentAccount() async throws {
        let service = EditorWiFiService()
        let model = AppModel(demoMode: true, wifi: service)
        model.markCurrentAccount(model.accounts[0], on: model.networks[0])
        let current = model.accountSelection
        let initialAccounts = model.accounts
        let initialNetworks = model.networks
        await model.scan()
        var draft = AccountNetworkDraft()
        draft.setSelected(true, ssid: "Office · Enterprise")
        draft.setSelected(true, ssid: "Campus")
        try draft.addManualSSID("Hidden", nearby: model.nearby)
        #expect(model.accounts == initialAccounts && model.networks == initialNetworks)
        try model.saveAccount(editor: AccountEditor(account: nil), label: "New", username: "new", password: "synthetic", networkSSIDs: draft.selectedSSIDs)
        let saved = try #require(model.accounts.last)
        #expect(model.networks(for: saved).map(\.ssid) == ["Office · Enterprise", "Campus", "Hidden"])
        #expect(try model.savedPassword(for: AccountEditor(account: saved)) == "synthetic")
        #expect(model.accountSelection == current)
        #expect(service.connectionAttempts == 0)
        let count = model.accounts.count
        try model.saveAccount(editor: AccountEditor(account: nil), label: "Hotspot", username: "", password: "synthetic", networkSSIDs: ["Phone Hotspot"])
        #expect(model.accounts.count == count + 1)
        #expect(model.networks(for: model.accounts.last!).map(\.ssid) == ["Phone Hotspot"])
        #expect(service.connectionAttempts == 0)
    }
}

private final class EditorWiFiService: WiFiServicing {
    func reconnectAccount(ssid: String, username: String, password: String, progress: @escaping (SwitchPhase) -> Void) async throws {
        try await switchAccount(ssid: ssid, username: username, password: password, progress: progress)
    }
    var connectionAttempts = 0
    func snapshot() async -> WiFiSnapshot { WiFiSnapshot(ssid: "Office · Enterprise", poweredOn: true, available: true, hasUsableAddress: true) }
    func scan() async throws -> [NearbyWiFi] { [] }
    func switchAccount(ssid: String, username: String, password: String, progress: @escaping (SwitchPhase) -> Void) async throws {
        connectionAttempts += 1
        throw WiFiError.demoMode
    }
}
