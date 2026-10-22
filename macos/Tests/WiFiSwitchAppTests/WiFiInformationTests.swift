import CoreWLAN
import Foundation
import Testing
@testable import WiFiSwitch

struct WiFiInformationTests {
    private let connected = WiFiInformationReader.Interface(name: "en0", ssid: "Office", poweredOn: true,
        security: .wpa2Enterprise, mac: "02:00:00:00:00:01", bssid: "02:00:00:00:00:02")
    private var values: [String: Any] { [
        "State:/Network/Interface/en0/IPv4": ["Addresses": ["192.0.2.10", "192.0.2.11"], "SubnetMasks": ["255.255.255.0"]],
        "State:/Network/Interface/en0/IPv6": ["Addresses": ["2001:db8::10"], "PrefixLength": [64]],
        "State:/Network/Service/wifi/IPv4": ["InterfaceName": "en0", "Router": "192.0.2.1"],
        "State:/Network/Service/wifi/IPv6": ["InterfaceName": "en0", "Router": "fe80::1%en0"],
        "State:/Network/Service/wifi/DNS": ["ServerAddresses": ["192.0.2.53", "192.0.2.53", "2001:db8::53"]],
        "State:/Network/Service/vpn/IPv4": ["InterfaceName": "utun7", "Router": "198.51.100.1"],
        "State:/Network/Service/vpn/DNS": ["ServerAddresses": ["198.51.100.53"]],
        "State:/Network/Global/DNS": ["ServerAddresses": ["203.0.113.53"]]
    ] }
    private func rows(_ info: WiFiInformation) -> [String: String] {
        Dictionary(uniqueKeysWithValues: info.sections.flatMap(\.rows).map { ($0.title, $0.value) })
    }
    @Test func addressesMasksGatewaysAndDNSBelongOnlyToSelectedInterface() {
        let info = WiFiInformationReader.assemble(ssid: "Office", authentication: .enterprise,
            before: connected, after: connected, values: values)
        let result = rows(info)
        #expect(info.connectionConfirmed)
        #expect(result["IPv4 地址 1"] == "192.0.2.10")
        #expect(result["子网掩码 1"] == "255.255.255.0")
        #expect(result["子网掩码 2"] == "未获取")
        #expect(result["IPv4 网关"] == "192.0.2.1")
        #expect(result["IPv6 / 前缀长度"] == "2001:db8::10/64")
        #expect(result["IPv6 网关"] == "fe80::1%en0")
        #expect(result["DNS（Wi-Fi 服务）"] == "192.0.2.53\n2001:db8::53")
        #expect(!result.values.joined().contains("198.51.100"))
        #expect(!result.values.joined().contains("203.0.113"))
        #expect(result["MAC（当前接口）"] == connected.mac)
    }
    @Test func inactiveTargetNeverDisplaysCurrentNetworkAddresses() {
        let info = WiFiInformationReader.assemble(ssid: "Home", authentication: .personal,
            before: connected, after: connected, values: values)
        #expect(info.status.contains("未连接此 Wi-Fi"))
        #expect(!info.connectionConfirmed)
        #expect(rows(info)["IPv4 地址 1"] == nil)
        #expect(rows(info)["配置认证类型"] == "Wi-Fi 密码")
    }
    @Test func missingPermissionPowerAndReadFailureHaveExplicitStates() {
        var unknown = connected; unknown.ssid = nil
        let unreadable = WiFiInformationReader.assemble(ssid: "Office", authentication: .enterprise,
            before: unknown, after: unknown, values: values)
        #expect(unreadable.status.contains("无法确认"))
        #expect(!unreadable.connectionConfirmed)
        var off = connected; off.poweredOn = false
        let poweredOff = WiFiInformationReader.assemble(ssid: "Office", authentication: .enterprise,
            before: off, after: off, values: values)
        #expect(poweredOff.status.contains("已关闭"))
        let failed = WiFiInformationReader.assemble(ssid: "Office", authentication: .enterprise,
            before: connected, after: connected, values: nil)
        #expect(failed.status.contains("无法读取"))
        #expect(failed.sections.count == 1)
    }
    @Test func changedConnectionDiscardsInFlightData() {
        for property in 0..<4 {
            var changed = connected
            if property == 0 { changed.name = "en1" }
            if property == 1 { changed.ssid = "Home" }
            if property == 2 { changed.security = .wpa3Enterprise }
            if property == 3 { changed.bssid = "02:00:00:00:00:03" }
            let info = WiFiInformationReader.assemble(ssid: "Office", authentication: .enterprise,
                before: connected, after: changed, values: values)
            #expect(info.sections.count == 1)
            #expect(!info.connectionConfirmed)
            #expect(!rows(info).values.joined().contains("192.0.2"))
        }
    }
    @Test func missingFieldsStayUnknownWithoutBorrowingGlobalDNS() {
        let info = WiFiInformationReader.assemble(ssid: "Office", authentication: .enterprise,
            before: connected, after: connected, values: ["State:/Network/Global/DNS": ["ServerAddresses": ["203.0.113.53"]]])
        #expect(rows(info)["IPv4 地址"] == "未分配")
        #expect(rows(info)["DNS（Wi-Fi 服务）"] == "未获取")
        #expect(rows(info)["IPv4 网关"] == "未获取")
    }
    @Test func securityComesFromLiveNetworkAndDoesNotGuessEAP() {
        let info = WiFiInformationReader.assemble(ssid: "Office", authentication: .personal,
            before: connected, after: connected, values: values)
        #expect(rows(info)["安全类型"] == "WPA2 企业")
        #expect(rows(info)["认证方式"] == "802.1X（具体 EAP 类型未提供）")
        #expect(WiFiInformationReader.securityDescription(.wpa3Personal).1 == "SAE")
        #expect(WiFiInformationReader.securityDescription(.none).1 == "无需密码")
        #expect(WiFiInformationReader.securityDescription(.unknown).0 == "未获取")
    }
}
