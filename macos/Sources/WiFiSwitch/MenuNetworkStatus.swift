import Foundation

/// The menu's link state is separate from the management panel's account error state.
enum MenuNetworkStatus: Equatable {
    case passwordChanged, passwordUnverified, internetUnavailable, addressUnavailable
    case registered, unregistered, disconnected, poweredOff, waitingForAddress, checking, unreadable, unavailable, accountNeedsReview

    static func resolve(snapshot: WiFiSnapshot, busy: Bool, connectedAccountID: UUID?, hasSelectedAccount: Bool) -> Self {
        guard snapshot.available else { return .unavailable }
        guard snapshot.poweredOn else { return .poweredOff }
        if busy { return .checking }
        guard snapshot.ssid != nil else { return snapshot.ssidIsReadable ? .disconnected : .unreadable }
        guard snapshot.hasUsableAddress else { return .waitingForAddress }
        if connectedAccountID != nil { return .registered }
        return hasSelectedAccount ? .accountNeedsReview : .unregistered
    }

    var hasSystemConfigurationAction: Bool {
        self == .unregistered || self == .passwordChanged || self == .passwordUnverified
    }

    var symbol: String {
        switch self {
        case .registered: return "checkmark.circle.fill"
        case .unregistered, .accountNeedsReview, .passwordChanged: return "exclamationmark.circle.fill"
        case .disconnected, .poweredOff, .internetUnavailable, .addressUnavailable: return "xmark.circle.fill"
        case .waitingForAddress, .checking: return "clock.fill"
        case .passwordUnverified: return "info.circle.fill"
        case .unreadable, .unavailable: return "questionmark.circle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .passwordChanged: return "系统 Wi-Fi 密码已变化，更新已保存的密码"
        case .passwordUnverified: return "暂时无法核对账号信息，点击核对"
        case .addressUnavailable: return "未获取到可用 IP 地址，请检查 DHCP 或网络设置"
        case .internetUnavailable: return "互联网检测未通过，请检查网络、DNS 或网页登录；检测目标为 Apple 和 Microsoft 的 TLS 服务"
        case .registered: return "已连接，当前使用账号"
        case .unregistered: return "未知账号，添加当前 Wi-Fi 配置"
        case .disconnected: return "Wi-Fi 已断开连接"
        case .poweredOff: return "Wi-Fi 已关闭，连接已断开"
        case .waitingForAddress: return "等待网络分配 IP 地址"
        case .checking: return "正在确认连接"
        case .unreadable: return "无法读取 Wi-Fi 名称"
        case .unavailable: return "未找到可用 Wi-Fi 网卡"
        case .accountNeedsReview: return "网络已连接，账号状态需核对"
        }
    }
}
