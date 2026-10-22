import AppKit

@MainActor
enum AppInformation {
    static func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: aboutOptions())
    }

    static func aboutOptions(bundle: Bundle = .main) -> [NSApplication.AboutPanelOptionKey: Any] {
        func value(_ key: String) -> String? { bundle.object(forInfoDictionaryKey: key) as? String }
        let name = value("CFBundleDisplayName") ?? value("CFBundleName") ?? "WiFi Switch"
        #if arch(arm64)
        let architecture = "Apple Silicon · arm64"
        #elseif arch(x86_64)
        let architecture = "Intel · x86_64"
        #else
        let architecture = "macOS"
        #endif
        var details = ["一个账号，多个 Wi-Fi，快速连接。", "", "适用平台：\(architecture)"]
        if let minimum = value("LSMinimumSystemVersion") {
            details.append("系统要求：macOS \(minimum) 或更高版本")
        }
        if let distribution = value("WiFiSwitchDistribution") { details.append(distribution) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 4
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: name,
            .credits: NSAttributedString(string: details.joined(separator: "\n"), attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ])
        ]
        if let version = value("CFBundleShortVersionString") { options[.applicationVersion] = version }
        if let build = value("CFBundleVersion") { options[.version] = build }
        if let url = bundle.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) { options[.applicationIcon] = icon }
        return options
    }

    static func showUserGuide() {
        guard let url = Bundle.main.url(forResource: "README", withExtension: "txt"),
              NSWorkspace.shared.open(url) else {
            let alert = NSAlert()
            alert.messageText = "无法打开使用说明"
            alert.informativeText = "请查看安装包中的 README.txt。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
    }
}
