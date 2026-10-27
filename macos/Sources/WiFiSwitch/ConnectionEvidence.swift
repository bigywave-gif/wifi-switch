import Foundation

/// A completed application association and the separately saved system default.
struct ConnectionEvidence: Equatable {
    let ssid: String
    let requestedAccount: String
    let requestedUsername: String
    let automatic: Bool
    var savedAccount: String?
    var savedUsername: String?

    var detail: String {
        let origin = automatic ? "WiFi Switch 自动重连" : "WiFi Switch 手动连接"
        let saved = savedUsername.map { username in
            savedAccount.map { "\($0)（\(username)）" } ?? username
        } ?? "暂未读取到"
        return "Wi-Fi：\(ssid)\n连接来源：\(origin)\n本次请求账号：\(requestedAccount)（\(requestedUsername)）\n系统保存账号：\(saved)\n\n已使用所选账号提交认证，系统连接调用成功，且目标 Wi-Fi 与 IP 已连续确认。系统保存账号用于后续系统连接，可以与本次账号不同。\n\n本状态依据应用连接结果，不是认证服务器身份查询；不会因默认账号不同而覆盖密码或修改系统首选账号。"
    }
}
