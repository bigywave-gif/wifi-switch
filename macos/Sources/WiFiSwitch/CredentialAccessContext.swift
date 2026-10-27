import AppKit

struct CredentialAccessContext: Equatable {
    let ssid: String
    let accountName: String
    let username: String?
    var stage: Stage = .systemWiFi
    enum Stage {
        case systemWiFi, systemKeychain, personalWiFi, appAccount
        init(source: SystemCredentialSource) {
            switch source {
            case .user: self = .systemWiFi
            case .system: self = .systemKeychain
            case .standardPersonal: self = .personalWiFi
            }
        }
    }
    var message: String {
        var lines = ["账号：\(accountName)", "Wi-Fi：\(ssid)"]
        if let username, !username.isEmpty { lines.append("用户名：\(username)") }
        switch stage {
        case .systemWiFi:
            lines.append("正在读取：系统 Wi-Fi 凭据（登录钥匙串）。")
            lines.append("系统弹窗可能显示“\(ssid)”或要求解锁“登录”钥匙串。")
        case .systemKeychain:
            lines.append("正在读取：系统 Wi-Fi 凭据（系统钥匙串）。")
            lines.append("系统弹窗可能显示“\(ssid)”或“系统”钥匙串。")
        case .personalWiFi:
            lines.append("正在读取：系统保存的 Wi-Fi 密码。")
            lines.append("系统密码条目对应 Wi-Fi“\(ssid)”。")
        case .appAccount:
            lines.append("正在读取：WiFi Switch 账号密码。")
            lines.append("系统条目可能仍叫“WiFi Switch 账号密码”，或带上述账号描述。")
        }
        if stage == .systemKeychain {
            lines.append("授权时输入本机管理员用户名和密码，不是 Wi-Fi 密码。")
        } else if stage == .personalWiFi {
            lines.append("“登录”钥匙串提示请输入钥匙串密码；系统管理员提示请输入本机管理员用户名和密码。不是 Wi-Fi 密码。")
        } else {
            lines.append("授权时输入“登录”钥匙串密码（通常是 Mac 登录密码），不是 Wi-Fi 密码。")
        }
        return lines.joined(separator: "\n")
    }
}

/// CoreWLAN's authorization dialog has no custom-text parameter. Keep its target
/// visible in an app-owned companion panel without another confirmation step.
@MainActor final class CredentialAccessWindow {
    private var window: NSPanel?
    private var messageField: NSTextField?

    func present(_ context: CredentialAccessContext) async {
        dismiss()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 180),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "WiFi Switch · 钥匙串授权说明"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = content(context)
        window = panel
        layout(panel)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await displayBeforeAuthorization(panel)
    }
    func update(_ context: CredentialAccessContext) async {
        guard let panel = window else { return }
        messageField?.stringValue = context.message
        layout(panel)
        await displayBeforeAuthorization(panel)
    }

    private func layout(_ panel: NSPanel) {
        panel.contentView?.layoutSubtreeIfNeeded()
        if let content = panel.contentView { panel.setContentSize(content.fittingSize) }
    }

    /// Submit the explanation to AppKit before asking Security to show its own UI.
    /// macOS still controls when the system prompt becomes visible.
    private func displayBeforeAuthorization(_ panel: NSPanel) async {
        panel.displayIfNeeded()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                panel.displayIfNeeded()
                continuation.resume()
            }
        }
    }

    private func content(_ context: CredentialAccessContext) -> NSView {
        let title = NSTextField(labelWithString: "核对账户信息")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)!)
        icon.contentTintColor = .labelColor
        let header = NSStackView(views: [icon, title])
        header.spacing = 8
        let message = NSTextField(wrappingLabelWithString: context.message)
        message.font = .systemFont(ofSize: NSFont.systemFontSize)
        message.isSelectable = true
        message.preferredMaxLayoutWidth = 392
        messageField = message
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let waiting = NSTextField(labelWithString: "等待系统读取或授权…")
        waiting.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        waiting.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [spinner, waiting])
        footer.spacing = 8
        let stack = NSStackView(views: [header, message, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalToConstant: 392),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            spinner.widthAnchor.constraint(equalToConstant: 16), spinner.heightAnchor.constraint(equalToConstant: 16)
        ])
        return root
    }
    func dismiss() { window?.close(); window = nil; messageField = nil }
}
