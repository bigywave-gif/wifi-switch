import Foundation
import Security
import Testing
@testable import WiFiSwitch

struct SystemIdentityAttributesTests {
    @Test(arguments: [true, false])
    func queriesOnlyAttributesOfExactSSIDWithoutInteraction(dataProtection: Bool) {
        let query = SystemIdentityAttributes.query(ssid: "Office", dataProtection: dataProtection)
        #expect(query[kSecAttrLabel as String] as? String == "Office")
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        #expect(query[kSecReturnData as String] == nil)
        #expect(query[kSecReturnRef as String] == nil)
        #expect(query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
    }

    @Test func legacyEAPMetadataResolvesAccountWithoutSecretData() {
        let record = entry("alice")
        #expect(SystemIdentityAttributes.username(ssid: "Office", items: [record]) == "alice")
        #expect(SystemIdentityAttributes.username(ssid: "Office", items: [record, record]) == "alice")
        #expect(SystemIdentityAttributes.username(ssid: "Other", items: [record]) == nil)
    }

    @Test func labelAloneCannotMakeUnrelatedItemAUsername() {
        var unrelated = entry("bob")
        unrelated[kSecAttrService as String] = "org.wifiswitch.WiFiSwitch.accounts"
        #expect(SystemIdentityAttributes.username(ssid: "Office", items: [unrelated]) == nil)
        #expect(SystemIdentityAttributes.username(ssid: "Office", items: [unrelated, entry("alice")]) == "alice")
        unrelated[kSecAttrService as String] = "com.apple.network.eap.user.item.wlan.ssid.Office-Guest"
        #expect(SystemIdentityAttributes.username(ssid: "Office", items: [unrelated]) == nil)
    }

    @Test func ConflictsMissingAndEmptyUsernamesAreNotNewAccountEvidence() {
        #expect(SystemIdentityAttributes.username(ssid: "Office", items: []) == nil)
        #expect(SystemIdentityAttributes.username(ssid: "Office", items: [entry("alice"), entry("bob")]) == nil)
        #expect(SystemIdentityAttributes.username(ssid: "Office", items: [entry("")]) == nil)
        var missing = entry("alice")
        missing.removeValue(forKey: kSecAttrAccount as String)
        #expect(SystemIdentityAttributes.username(ssid: "Office", items: [missing]) == nil)
    }

    private func entry(_ username: String) -> [String: Any] {
        [kSecAttrLabel as String: "Office", kSecAttrAccount as String: username,
         kSecAttrService as String: "com.apple.network.eap.user.item.wlan.ssid.Office"]
    }
}
