import Foundation
import WiFiSwitchCore

struct AccountNetworkOption: Identifiable {
    var id: String { ssid }
    let ssid: String
    let isSaved: Bool
    let nearby: NearbyWiFi?
    var detail: String {
        if let nearby { return nearby.authentication.label }
        return isSaved ? "已保存" : "待扫描确认"
    }
}

/// An editor-local draft: scanning and selecting never write accounts or credentials.
struct AccountNetworkDraft {
    private(set) var selectedSSIDs: [String] = []
    private(set) var manualSSIDs: [String] = []

    init(selectedSSIDs: [String] = []) {
        for ssid in selectedSSIDs { setSelected(true, ssid: ssid) }
    }

    mutating func setSelected(_ selected: Bool, ssid: String) {
        if selected && !selectedSSIDs.contains(ssid) { selectedSSIDs.append(ssid) }
        if !selected { selectedSSIDs.removeAll { $0 == ssid } }
    }

    mutating func addManualSSID(_ ssid: String, nearby: [NearbyWiFi]) throws {
        guard !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ssid.utf8.count <= 32, !ssid.contains("\0") else { throw StoreError.invalidSSID }
        if !manualSSIDs.contains(ssid) { manualSSIDs.append(ssid) }
        setSelected(true, ssid: ssid)
    }

    func authentications(saved: [SavedWiFi], nearby: [NearbyWiFi]) -> [String: WiFiAuthentication] {
        Dictionary(uniqueKeysWithValues: selectedSSIDs.map { ssid in
            (ssid, nearby.first(where: { $0.ssid == ssid })?.authentication ?? saved.first(where: { $0.ssid == ssid })?.authentication ?? .unknown)
        })
    }

    func requiresUsername(saved: [SavedWiFi], nearby: [NearbyWiFi]) -> Bool {
        authentications(saved: saved, nearby: nearby).values.contains { $0.requiresUsername }
    }

    func requiresSecret(saved: [SavedWiFi], nearby: [NearbyWiFi]) -> Bool {
        selectedSSIDs.isEmpty || authentications(saved: saved, nearby: nearby).values.contains { $0.requiresSecret }
    }

    func options(saved: [SavedWiFi], nearby: [NearbyWiFi]) -> [AccountNetworkOption] {
        var seen = Set<String>()
        // Selected/offline networks stay visible after another scan.
        return (saved.map(\.ssid) + nearby.map(\.ssid) + selectedSSIDs + manualSSIDs).compactMap { ssid in
            guard seen.insert(ssid).inserted else { return nil }
            return AccountNetworkOption(ssid: ssid, isSaved: saved.contains { $0.ssid == ssid },
                                        nearby: nearby.first { $0.ssid == ssid })
        }
    }
}
