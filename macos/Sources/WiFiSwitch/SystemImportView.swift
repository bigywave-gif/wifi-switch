import AppKit
import SwiftUI

struct SystemImportView: View {
    @ObservedObject var model: AppModel
    @State private var label = ""

    private var updating: Bool { model.systemImportCandidate?.isPasswordUpdate == true }
    private var verifying: Bool { model.systemImportCandidate?.isPasswordVerification == true }
    private var linking: Bool { model.systemImportCandidate?.linkingNetwork == true }
    private var hasTarget: Bool { model.systemImportCandidate?.updatingAccount != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verifying ? "核对账户信息" : updating ? "更新已保存的密码" : (linking ? "添加 Wi-Fi 到已有账号" : "添加当前 Wi-Fi 配置")).font(.title2.bold())
            Text(model.systemImportCandidate?.ssid ?? "连接已变化")
                .font(.headline).textSelection(.enabled)
            if let account = model.systemImportCandidate?.updatingAccount {
                Text(account.label.isEmpty ? "未命名账号" : account.label).font(.headline)
                if verifying && !account.username.isEmpty {
                    Text("用户名：\(account.username)").textSelection(.enabled)
                }
                if linking {
                    Text("将此 Wi-Fi 关联到上面的已有账号，保留原有名称和其他 Wi-Fi。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if updating {
                    Text("系统 Wi-Fi 密码与 WiFi Switch 中保存的不一致，请更新此账号的密码。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if verifying {
                    Text("暂时无法自动核对。点击“核对”读取系统账户信息并比较，一致时无需更新。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if updating && (linking || account.networkIDs.count > 1) {
                    Text("更新会影响此账号关联的所有 Wi-Fi，它们共用一份密码。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("填写 Wi-Fi 描述后点击添加，将读取系统保存的账号信息。macOS 可能要求钥匙串授权。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Wi-Fi 描述（必填）")
                TextField("例如：办公账号、家中热点", text: $label)
                    .textFieldStyle(.roundedBorder).disabled(model.isImporting)
                    .accessibilityIdentifier("system-import-label")
            }
            }
            Text(verifying ? "核对可能需要钥匙串授权。若发现密码不同，将再次提示确认更新。" : hasTarget ? "确认后可能需要钥匙串授权。仅保存到本应用，不重新连接或改变自动加入设置。" :
                 "普通 Wi-Fi 和热点不需要用户名。密码仅存入本机钥匙串；添加不会重新连接或改变自动加入设置。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.systemImportError {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("system-import-error")
            }
            if let context = model.credentialAccessContext {
                Text(context.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("credential-access-context")
            }
            HStack {
                if model.isImporting { ProgressView().controlSize(.small); Text(verifying ? "正在读取并核对…" : "正在读取并保存…").font(.caption) }
                Spacer()
                Button("取消") { model.cancelSystemImport() }.keyboardShortcut(.cancelAction)
                Button(verifying ? "核对" : updating ? (linking ? "添加并更新" : "更新") : "添加") { Task { await model.confirmSystemImport(label: label) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled((!hasTarget && label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || model.isImporting || model.systemImportCandidate == nil)
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
        window.title = "WiFi Switch · 系统配置"
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
