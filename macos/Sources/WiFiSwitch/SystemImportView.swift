import AppKit
import SwiftUI

struct SystemImportView: View {
    @ObservedObject var model: AppModel
    @State private var label = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("添加当前 Wi-Fi 配置").font(.title2.bold())
            Text(model.systemImportCandidate?.ssid ?? "连接已变化")
                .font(.headline).textSelection(.enabled)
            Text("尚未确认此连接对应的账号。填写名称并确认后，将读取系统保存的用户名和密码；macOS 可能要求钥匙串授权。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("账号名称（必填）")
                TextField("例如：办公账号、家中热点", text: $label)
                    .textFieldStyle(.roundedBorder).disabled(model.isImporting)
                    .accessibilityIdentifier("system-import-label")
            }
            Text("普通 Wi-Fi 和热点不需要用户名。密码仅存入本机钥匙串；添加不会重新连接或改变自动加入设置。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.systemImportError {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("system-import-error")
            }
            HStack {
                if model.isImporting { ProgressView().controlSize(.small); Text("正在读取并保存…").font(.caption) }
                Spacer()
                Button("取消") { model.cancelSystemImport() }.keyboardShortcut(.cancelAction)
                Button("确认添加") { Task { await model.confirmSystemImport(label: label) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isImporting || model.systemImportCandidate == nil)
                    .accessibilityIdentifier("system-import-confirm")
            }
        }.padding(24).frame(width: 420)
    }
}

/// An independent window also works while the main window and menu are closed.
@MainActor
final class SystemImportWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var model: AppModel?

    func present(model: AppModel) {
        dismiss()
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 468, height: 370),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "WiFi Switch · 添加配置"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SystemImportView(model: model))
        window.delegate = self
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) { model?.cancelSystemImport() }
}
