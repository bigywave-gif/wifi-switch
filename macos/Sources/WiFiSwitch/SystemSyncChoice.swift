import AppKit
import SwiftUI

/// Keeps the connection decision separate from its optional explanation.
@MainActor
final class SystemSyncChoice: NSObject {
    private let explanation = NSPopover()

    func run(ssid: String, account: String) -> Bool? {
        let alert = NSAlert()
        alert.messageText = "同步为系统首选账号？"
        alert.informativeText = "Wi-Fi：\(ssid)\n账号：\(account)"
        alert.addButton(withTitle: "同步账号")
        alert.addButton(withTitle: "仅本次连接")
        alert.addButton(withTitle: "取消")

        let help = NSButton(title: "设置说明", target: self, action: #selector(showExplanation(_:)))
        help.isBordered = false
        help.image = NSImage(systemSymbolName: "questionmark.circle.fill", accessibilityDescription: nil)
        help.imagePosition = .imageLeading
        help.contentTintColor = .systemBlue
        help.attributedTitle = NSAttributedString(string: "设置说明", attributes: [
            .foregroundColor: NSColor.systemBlue,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        ])
        help.setAccessibilityLabel("设置说明")
        help.toolTip = "查看同步账号与仅本次连接的区别"
        help.sizeToFit()
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        help.frame.origin = NSPoint(x: (accessory.bounds.width - help.frame.width) / 2,
                                   y: (accessory.bounds.height - help.frame.height) / 2)
        accessory.addSubview(help)
        alert.accessoryView = accessory

        explanation.behavior = .transient
        explanation.contentViewController = NSHostingController(rootView: SystemSyncExplanation())
        explanation.contentSize = NSSize(width: 300, height: 230)
        defer { explanation.close() }
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? true : (response == .alertSecondButtonReturn ? false : nil)
    }

    @objc private func showExplanation(_ sender: NSButton) {
        if explanation.isShown { explanation.close() }
        else { explanation.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX) }
    }
}

private struct SystemSyncExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置说明").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("同步账号").fontWeight(.semibold)
                Text("连接成功后，更新此 Wi-Fi 在系统中保存的账号和密码。")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("仅本次连接").fontWeight(.semibold)
                Text("本次使用所选账号，保留系统原有账号。")
            }
            Text("两种选择均不改变 Wi-Fi 优先顺序和自动加入设置。")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }
}
