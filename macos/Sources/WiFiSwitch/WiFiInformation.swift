import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration
import WiFiSwitchCore

struct WiFiInformation {
    struct Row: Identifiable {
        let title: String
        let value: String
        var id: String { title }
    }
    struct Section: Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }
    let status: String
    let sections: [Section]
    var connectionConfirmed = false
    let timestamp = Date()
}

enum WiFiInformationReader {
    struct Interface: Equatable {
        var name: String
        var ssid: String?
        var poweredOn: Bool
        var security: CWSecurity = .unknown
        var mac: String?
        var bssid: String?
        var channel: Int?
        var rssi: Int = 0
        var noise: Int = 0
        var transmitRate: Double = 0
    }

    static func read(ssid: String, authentication: WiFiAuthentication) async -> WiFiInformation {
        let authenticationValue = authentication.rawValue
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let interface = CWWiFiClient.shared().interface()
                let before = interface.map(capture)
                let values = dynamicValues()
                let after = interface.map(capture)
                continuation.resume(returning: assemble(ssid: ssid, authentication: WiFiAuthentication(rawValue: authenticationValue) ?? .unknown,
                                                        before: before, after: after, values: values))
            }
        }
    }

    static func dynamicValues() -> [String: Any]? {
        guard let store = SCDynamicStoreCreate(nil, "WiFiSwitch.network-information" as CFString, nil, nil) else { return nil }
        let patterns = ["State:/Network/Interface/.*/IPv[46]", "State:/Network/Service/.*/(IPv4|IPv6|DNS)"]
        return SCDynamicStoreCopyMultiple(store, nil, patterns as CFArray) as? [String: Any]
    }

    static func capture(_ interface: CWInterface) -> Interface {
        let name = interface.interfaceName ?? ""
        return Interface(name: name, ssid: interface.ssid(), poweredOn: interface.powerOn(),
                         security: interface.security(), mac: currentMAC(name), bssid: interface.bssid(),
                         channel: interface.wlanChannel().map { Int($0.channelNumber) },
                         rssi: interface.rssiValue(), noise: interface.noiseMeasurement(), transmitRate: interface.transmitRate())
    }

    /// Read the current link-layer address (including a private address), not a permanent factory MAC.
    private static func currentMAC(_ name: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var item: UnsafeMutablePointer<ifaddrs>? = first
        while let current = item {
            defer { item = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name) == name,
                  let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let link = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self).pointee
            guard link.sdl_alen == 6 else { continue }
            let offset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)! + Int(link.sdl_nlen)
            guard offset + 6 <= Int(link.sdl_len) else { continue }
            let bytes = UnsafeRawPointer(address).advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            let value = (0..<6).map { bytes[$0] }
            guard value.contains(where: { $0 != 0 }) else { return nil }
            return value.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
        return nil
    }

    static func assemble(ssid: String, authentication: WiFiAuthentication,
                         before: Interface?, after: Interface?, values: [String: Any]?) -> WiFiInformation {
        func unavailable(_ status: String) -> WiFiInformation {
            .init(status: status, sections: [.init(title: "保存的配置", rows: [
                .init(title: "Wi-Fi 名称", value: ssid),
                .init(title: "配置认证类型", value: authentication.label)
            ])])
        }
        guard let before, let after, !before.name.isEmpty else { return unavailable("未找到 Wi-Fi 网卡") }
        guard before.poweredOn, after.poweredOn else { return unavailable("Wi-Fi 已关闭，暂无实时信息") }
        guard before.ssid != nil, after.ssid != nil else { return unavailable("无法确认当前 Wi-Fi 名称，请检查定位权限及连接状态") }
        guard before.ssid == ssid, after.ssid == ssid else { return unavailable("未连接此 Wi-Fi，连接后可查看实时信息") }
        guard before.name == after.name, before.security == after.security, before.bssid == after.bssid else {
            return unavailable("读取期间连接发生变化，请刷新")
        }
        guard let values else { return unavailable("无法读取系统网络配置，请刷新重试") }
        func dictionary(_ key: String) -> [String: Any] { values[key] as? [String: Any] ?? [:] }
        func strings(_ dict: [String: Any], _ key: String) -> [String] {
            (dict[key] as? [String] ?? []).filter { !$0.isEmpty }
        }
        func joined(_ values: [String], fallback: String = "未获取") -> String {
            var seen = Set<String>()
            let unique = values.filter { seen.insert($0).inserted }
            return unique.isEmpty ? fallback : unique.joined(separator: "\n")
        }
        // Bind service data by its runtime InterfaceName. Never borrow global/VPN DNS or routes.
        let serviceIDs = Set(values.keys.compactMap { key -> String? in
            let parts = key.split(separator: "/")
            guard parts.count == 5, parts[0] == "State:", parts[1] == "Network", parts[2] == "Service",
                  ["IPv4", "IPv6"].contains(String(parts[4])),
                  dictionary(key)["InterfaceName"] as? String == before.name else { return nil }
            return String(parts[3])
        }).sorted()
        func entities(_ family: String) -> [[String: Any]] {
            serviceIDs.compactMap { id in
                let data = dictionary("State:/Network/Service/\(id)/\(family)")
                if let name = data["InterfaceName"] as? String, name != before.name { return nil }
                return data
            }
        }
        let ipv4 = dictionary("State:/Network/Interface/\(before.name)/IPv4")
        let ipv6 = dictionary("State:/Network/Interface/\(before.name)/IPv6")
        let addresses4 = strings(ipv4, "Addresses")
        let masks = strings(ipv4, "SubnetMasks")
        let addresses6 = strings(ipv6, "Addresses")
        let prefixes = ipv6["PrefixLength"] as? [Int] ?? []
        let addressRows: [WiFiInformation.Row] = addresses4.isEmpty ? [
            .init(title: "IPv4 地址", value: "未分配"), .init(title: "子网掩码", value: "未获取")
        ] :
            addresses4.enumerated().flatMap { index, address -> [WiFiInformation.Row] in
                let suffix = addresses4.count > 1 ? " \(index + 1)" : ""
                return [.init(title: "IPv4 地址\(suffix)", value: address),
                        .init(title: "子网掩码\(suffix)", value: index < masks.count ? masks[index] : "未获取")]
            }
        let routers4 = entities("IPv4").compactMap { $0["Router"] as? String } + [ipv4["Router"] as? String].compactMap { $0 }
        let routers6 = entities("IPv6").compactMap { $0["Router"] as? String } + [ipv6["Router"] as? String].compactMap { $0 }
        let dns = entities("DNS").flatMap { strings($0, "ServerAddresses") }
        let security = securityDescription(before.security)
        return .init(status: "当前已连接此 Wi-Fi", sections: [
            .init(title: "网络地址", rows: addressRows + [
                .init(title: "IPv4 网关", value: joined(routers4)),
                .init(title: "IPv6 / 前缀长度", value: joined(addresses6.enumerated().map { index, address in
                    index < prefixes.count ? "\(address)/\(prefixes[index])" : address
                }, fallback: "未分配")),
                .init(title: "IPv6 网关", value: joined(routers6)),
                .init(title: "DNS（Wi-Fi 服务）", value: joined(dns))
            ]),
            .init(title: "无线连接", rows: [
                .init(title: "网卡", value: before.name),
                .init(title: "MAC（当前接口）", value: before.mac ?? "未获取"),
                .init(title: "BSSID（接入点）", value: before.bssid ?? "未获取或未获权限"),
                .init(title: "信道", value: before.channel.map(String.init) ?? "未获取"),
                .init(title: "信号 / 噪声", value: "\(before.rssi == 0 ? "未获取" : "\(before.rssi) dBm") / \(before.noise == 0 ? "未获取" : "\(before.noise) dBm")"),
                .init(title: "协商速率", value: before.transmitRate > 0 ? String(format: "%.1f Mbps", before.transmitRate) : "未获取")
            ]),
            .init(title: "认证信息", rows: [
                .init(title: "安全类型", value: security.0),
                .init(title: "认证方式", value: security.1)
            ])
        ], connectionConfirmed: true)
    }

    static func securityDescription(_ security: CWSecurity) -> (String, String) {
        let enterprise = "802.1X（具体 EAP 类型未提供）"
        switch security {
        case .wpaEnterprise: return ("WPA 企业", enterprise)
        case .wpa2Enterprise: return ("WPA2 企业", enterprise)
        case .wpa3Enterprise: return ("WPA3 企业", enterprise)
        case .wpaEnterpriseMixed: return ("WPA / WPA2 企业", enterprise)
        case .enterprise: return ("企业网络", enterprise)
        case .dynamicWEP: return ("动态 WEP", enterprise)
        case .wpaPersonal: return ("WPA 个人", "预共享密钥（PSK）")
        case .wpa2Personal: return ("WPA2 个人", "预共享密钥（PSK）")
        case .wpaPersonalMixed: return ("WPA / WPA2 个人", "预共享密钥（PSK）")
        case .wpa3Personal: return ("WPA3 个人", "SAE")
        case .wpa3Transition: return ("WPA2 / WPA3 过渡模式", "PSK / SAE，实际协商方式未提供")
        case .personal: return ("个人密码网络", "系统未提供具体方式")
        case .WEP: return ("WEP", "WEP 密钥")
        case .none: return ("开放网络", "无需密码")
        case .OWE: return ("增强开放网络", "OWE（无需密码）")
        case .oweTransition: return ("增强开放过渡模式", "OWE / 开放，实际协商方式未提供")
        default: return ("未获取", "系统未提供")
        }
    }

    static func demo(ssid: String) -> WiFiInformation {
        let interface = Interface(name: "en0", ssid: ssid, poweredOn: true, security: .wpa2Enterprise,
                                  mac: "02:00:00:00:00:01", bssid: "02:00:00:00:00:02", channel: 36,
                                  rssi: -52, noise: -92, transmitRate: 866.7)
        let sample = assemble(ssid: ssid, authentication: .enterprise, before: interface, after: interface, values: [
            "State:/Network/Interface/en0/IPv4": ["Addresses": ["192.0.2.10"], "SubnetMasks": ["255.255.255.0"]],
            "State:/Network/Interface/en0/IPv6": ["Addresses": ["2001:db8::10"], "PrefixLength": [64]],
            "State:/Network/Service/sample/IPv4": ["InterfaceName": "en0", "Router": "192.0.2.1"],
            "State:/Network/Service/sample/IPv6": ["InterfaceName": "en0", "Router": "fe80::1%en0"],
            "State:/Network/Service/sample/DNS": ["ServerAddresses": ["192.0.2.53", "2001:db8::53"]]
        ])
        return .init(status: "演示数据 · 不读取实际网络", sections: sample.sections, connectionConfirmed: true)
    }
}
