import AppKit

@MainActor
struct ReconnectPrompt {
    func run(ssid: String, account: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Wi-Fi 连接已断开"
        alert.informativeText = "\(ssid) · \(account)\n是否使用此账号重新连接？"
        alert.addButton(withTitle: "重新连接")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
