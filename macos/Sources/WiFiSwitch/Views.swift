import SwiftUI
import WiFiSwitchCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var location: LocationAccess

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.system(size: 44)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text("WiFi Switch").font(.system(size: 25, weight: .bold))
                    Text("一个账号，多个 Wi-Fi，快速连接。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.editor = AccountEditor(account: nil) } label: {
                    Label("添加账号", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!model.canEdit)
                .accessibilityIdentifier("add-account")
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 22)

            HStack(spacing: 7) {
                Circle().fill(model.snapshot.ssid == nil ? Color.secondary : Color.green).frame(width: 7, height: 7)
                Text(connectionTitle).lineLimit(1).truncationMode(.tail)
                    .help(model.accountStatusDetail).accessibilityIdentifier("connection-summary")
                if model.selectedAccount == nil && model.canImportSystemConnection {
                    Button("添加此配置") { model.beginSystemImport() }.buttonStyle(.borderless)
                }
                Spacer()
                Text("\(model.accountCount) 个账号").foregroundStyle(.secondary)
                    .fixedSize().accessibilityIdentifier("account-count")
            }
            .font(.system(size: 12)).padding(.horizontal, 28).padding(.bottom, 16)

            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    if model.demoMode {
                        noticeBox("界面演示 · 示例账号仅保存在内存中，不会连接真实 Wi-Fi。", symbol: "eye", color: .orange)
                    }
                    if let error = model.loadError {
                        noticeBox("无法读取账号列表：\(error)\n文件：\(model.dataURL.path)", symbol: "exclamationmark.triangle", color: .red)
                    }
                    if !location.authorized && !model.demoMode {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "location.circle").font(.title2).foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("允许读取 Wi-Fi 名称").font(.system(size: 13, weight: .semibold))
                                Text("macOS 要求定位权限才能扫描和识别 Wi-Fi。本应用不采集地理位置。")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            Button(location.denied ? "前往设置" : "允许定位") {
                                if location.denied { model.openLocationSettings() } else { location.request() }
                            }
                        }
                        .padding(14).background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if model.isSwitching {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.phase?.title ?? "正在读取保存的密码…").font(.system(size: 13, weight: .medium))
                                Text("切换会短暂断网。如系统弹出授权或证书窗口，请完成后返回。")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                if model.authenticationTakingLong {
                                    Text("系统认证仍未返回。如果再次要求输入账号密码，可取消系统弹窗，然后核对或修改保存的账号。")
                                        .font(.system(size: 12)).foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                        }.padding(14).background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let notice = model.notice {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: notice.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(notice.isError ? Color.orange : Color.green)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(notice.text).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                if let editor = notice.accountEditor {
                                    Button("修改这个账号") { model.editor = editor }
                                        .buttonStyle(.borderless).disabled(!model.canEdit)
                                }
                            }
                            Spacer(minLength: 0)
                            Button { model.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("关闭提示")
                        }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if model.accounts.isEmpty && model.loadError == nil {
                        emptyState
                    } else {
                        ForEach(model.displayAccounts) { account in
                            AccountCard(account: account)
                        }
                    }
                }.padding(24)
            }
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.55))
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text("密码保存在系统钥匙串")
                Spacer()
                Text("关闭窗口后，仍可从菜单栏连接")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 13)
        }
        .frame(minWidth: 700, minHeight: 510)
        .sheet(item: $model.networkEditor) { account in AddNetworkView(account: account, location: location).environmentObject(model) }
        .sheet(item: $model.editor) { editor in AccountEditorView(editor: editor).environmentObject(model) }
        .alert(item: $model.deletion) { item in
            Alert(title: Text("删除“\(item.account.displayName)”？"),
                  message: Text("这会删除此账号、它关联的所有 Wi-Fi 和保存的密码，不影响其他账号，也不会主动断开系统连接。"),
                  primaryButton: .destructive(Text("删除")) { model.deleteAccount(item) },
                  secondaryButton: .cancel(Text("取消")))
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .onChange(of: location.status) { _ in Task { await model.refresh() } }
    }

    private var connectionTitle: String {
        if model.isSwitching { return "正在连接账号 · 等待认证完成" }
        if !model.snapshot.available { return "未找到 Wi-Fi 网卡" }
        if !model.snapshot.poweredOn { return "Wi-Fi 已关闭" }
        if let ssid = model.snapshot.ssid {
            if model.isCheckingConnection { return "已连接 · \(ssid) · 正在确认账号" }
            guard let account = model.selectedAccount else { return "已连接 · \(ssid) · 当前账号未识别" }
            let source = model.accountSelection?.source == .manual ? "（手动标记）" : ""
            return "已连接 · \(ssid) · \(account.displayName)\(source)"
        }
        return location.authorized ? "当前未连接 Wi-Fi" : "连接名称待授权后读取"
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi").font(.system(size: 46, weight: .light)).foregroundStyle(.blue)
                .frame(width: 100, height: 90)
            Text("先添加一个账号").font(.system(size: 20, weight: .semibold))
            Text("保存账号和密码，为它关联多个 Wi-Fi。\n展开账号，选择要连接的网络。")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            Button("添加第一个账号") { model.editor = AccountEditor(account: nil) }
                .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 6)
        }.frame(maxWidth: .infinity).padding(.vertical, 35)
    }

    private func noticeBox(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.system(size: 12)).textSelection(.enabled)
            Spacer(minLength: 0)
        }.padding(14).background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AccountCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var informationNetwork: SavedWiFi?
    let account: WiFiAccount
    private var expanded: Bool { model.expanded.contains(account.id) }
    private var networks: [SavedWiFi] { model.networks(for: account) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    if expanded { model.expanded.remove(account.id) } else { model.expanded.insert(account.id) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 10)
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 26)).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.displayName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Text("\(networks.count) 个关联 Wi-Fi").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(expanded ? "收起" : "展开")账号 \(account.displayName)")
                    .accessibilityValue(model.connectedAccountID == account.id ? "当前使用账号" : "")
                CurrentAccountIndicator(account: account)
                Menu {
                    Button("添加 Wi-Fi") { model.networkEditor = account }
                    Button("修改账号") { model.editor = AccountEditor(account: account) }
                    Button("删除账号", role: .destructive) { model.deletion = AccountDeletion(account: account) }
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                .disabled(!model.canEdit).accessibilityLabel("管理账号 \(account.displayName)")
            }.padding(.horizontal, 20).padding(.vertical, 18)
            if expanded {
                Divider().padding(.horizontal, 18)
                if networks.isEmpty {
                    Text("尚未关联 Wi-Fi，添加后即可使用此账号连接。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
                ForEach(networks) { network in
                    HStack(spacing: 12) {
                        Image(systemName: "wifi").font(.system(size: 19))
                            .foregroundStyle(model.accountConnectionStatus(for: account, on: network)?.isNormal == true ? Color.blue : Color.secondary)
                        Text(network.ssid).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 12)
                        NetworkConnectionControl(account: account, network: network)
                        Menu {
                            if model.canViewWiFiInformation(for: account, on: network) {
                                Button("查看 Wi-Fi 信息") {
                                    guard model.canViewWiFiInformation(for: account, on: network) else { return }
                                    informationNetwork = network
                                }
                                Divider()
                            }
                            Button("重新连接") { model.reconnectAccount(account, on: network) }
                                .disabled(!model.canEdit)
                            Button("移除 Wi-Fi", role: .destructive) { model.unlinkNetwork(network, from: account) }
                                .disabled(!model.canEdit)
                        } label: { Image(systemName: "ellipsis").frame(width: 20, height: 24) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                        .accessibilityLabel("管理 \(account.displayName) 的 \(network.ssid)")
                    }.padding(.horizontal, 20).padding(.vertical, 12)
                    if network.id != networks.last?.id { Divider().padding(.leading, 58).padding(.trailing, 18) }
                }
                HStack {
                    Button { model.networkEditor = account } label: { Label("添加 Wi-Fi", systemImage: "plus") }
                        .buttonStyle(.borderless).font(.system(size: 12)).disabled(!model.canEdit)
                        .accessibilityLabel("为 \(account.displayName) 添加 Wi-Fi")
                    Spacer()
                }.padding(.horizontal, 20).padding(.bottom, 16).padding(.top, 8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.07), lineWidth: 1))
        .sheet(item: $informationNetwork) { network in
            WiFiInformationView(account: account, network: network).environmentObject(model)
        }
    }
}

private enum ConnectionColumn {
    static func width(compact: Bool) -> CGFloat { compact ? 64 : 76 }
}

private struct CurrentAccountIndicator: View {
    @EnvironmentObject private var model: AppModel
    let account: WiFiAccount
    var compact = false
    private var isCurrent: Bool { model.connectedAccountID == account.id }

    var body: some View {
        ZStack {
            if isCurrent {
                Circle().fill(Color.green).frame(width: 18, height: 18)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
            }
        }
        .frame(width: ConnectionColumn.width(compact: compact), height: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("当前使用账号")
        .accessibilityHidden(!isCurrent)
        .help(isCurrent ? model.accountStatusDetail : "")
    }
}

struct NetworkConnectionControl: View {
    @EnvironmentObject private var model: AppModel
    let account: WiFiAccount
    let network: SavedWiFi
    var compact = false

    var body: some View {
        Group {
            if let status = model.accountConnectionStatus(for: account, on: network) {
                AccountStatusLight(status: status, accountName: "\(account.displayName) · \(network.ssid)", canReconnect: model.canEdit) {
                    model.reconnectAccount(account, on: network)
                }
            } else {
                Button {
                    model.switchAccount(account, on: network)
                } label: {
                    Text(model.switchingAccountID == account.id && model.switchingNetworkID == network.id ? "连接中…" : "连接")
                        .frame(minWidth: compact ? 30 : 40)
                }.buttonStyle(.borderedProminent).controlSize(compact ? .small : .regular).disabled(!model.canEdit)
                    .accessibilityLabel("使用 \(account.displayName) 连接 \(network.ssid)")
            }
        }.frame(width: ConnectionColumn.width(compact: compact), alignment: .center)
    }
}

struct AddNetworkView: View {
    let account: WiFiAccount
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var location: LocationAccess
    @State private var ssid = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("添加 Wi-Fi").font(.system(size: 22, weight: .semibold))
            Text("为“\(account.displayName)”选择 Wi-Fi，连接时使用此账号保存的凭据。添加不会改变当前连接。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                Text("Wi-Fi 名称（SSID）").font(.system(size: 12, weight: .medium))
                TextField("例如：Company-WiFi", text: $ssid).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Wi-Fi 名称").accessibilityIdentifier("ssid-field")
                Text("名称区分大小写；隐藏网络也可以手动添加。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text(model.scanCompleted ? "附近 Wi-Fi · \(model.nearby.count) 个" : "附近 Wi-Fi").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.isScanning { ProgressView().controlSize(.small) }
                Button(model.isScanning ? "扫描中…" : "扫描附近 Wi-Fi") { Task { await model.scan() } }
                    .disabled(!model.canEdit)
            }
            if let scanError = model.scanError {
                Text(scanError).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if location.denied { Button("打开定位设置") { model.openLocationSettings() } }
            }
            ScrollView {
                VStack(spacing: 5) {
                    if model.nearby.isEmpty {
                        Text(model.scanCompleted ? "未发现 Wi-Fi。可重新扫描或手动输入名称。" : "点击扫描，查看附近的 Wi-Fi 和手机热点。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 100)
                    }
                    ForEach(model.nearby) { network in
                        Button { ssid = network.ssid } label: {
                            HStack {
                                Image(systemName: "wifi")
                                Text(network.ssid).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(network.authentication.label)
                                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                                if ssid == network.ssid { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                            }.padding(10).contentShape(Rectangle())
                                .background(ssid == network.ssid ? Color.blue.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height: 200).scrollIndicators(.visible)
            Text("企业网络使用账号密码；普通 Wi-Fi 和热点使用 Wi-Fi 密码，开放网络无需密码。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加") {
                    do { try model.addNetwork(ssid: ssid, to: account); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canEdit)
            }
        }.padding(26).frame(width: 470)
        .onChange(of: location.status) { _ in
            if location.authorized && model.scanError != nil { Task { await model.scan() } }
        }
    }
}

struct AccountEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editor: AccountEditor
    @State private var label: String
    @State private var username: String
    @State private var networkDraft = AccountNetworkDraft()
    @State private var initializedNetworks = false
    @State private var password = ""
    @State private var passwordVisible = false
    @State private var error: String?

    init(editor: AccountEditor) {
        self.editor = editor
        _label = State(initialValue: editor.account?.label ?? "")
        _username = State(initialValue: editor.account?.username ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(editor.account == nil ? "添加账号" : "修改账号").font(.system(size: 22, weight: .semibold))
                Text("企业网络使用用户名和密码；普通 Wi-Fi 和热点只使用密码。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("备注（选填）").font(.system(size: 12, weight: .medium))
                        TextField("例如：办公账号、测试账号", text: $label).textFieldStyle(.roundedBorder).accessibilityLabel("账号备注")
                        Text("用于列表中区分账号；留空显示“未命名账号”。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(usernameLabel).font(.system(size: 12, weight: .medium))
                        TextField("输入 Wi-Fi 登录用户名", text: $username).textFieldStyle(.roundedBorder).accessibilityLabel(usernameLabel)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(passwordLabel).font(.system(size: 12, weight: .medium))
                        HStack(spacing: 8) {
                            Group {
                                if passwordVisible { TextField("输入密码", text: $password) }
                                else { SecureField(editor.account?.hasStoredSecret == true ? "保留已保存的密码" : "输入 Wi-Fi 密码", text: $password) }
                            }
                            .textFieldStyle(.roundedBorder).accessibilityLabel(passwordLabel)
                            .accessibilityIdentifier("account-password").privacySensitive()
                            Button(action: togglePasswordVisibility) {
                                Image(systemName: passwordVisible ? "eye.slash" : "eye").frame(width: 24, height: 24)
                            }
                            .buttonStyle(.borderless).disabled(!model.canEdit)
                            .help(passwordVisibilityLabel).accessibilityLabel(passwordVisibilityLabel)
                            .accessibilityIdentifier("toggle-password-visibility")
                        }
                        if editor.account?.hasStoredSecret == true {
                            Text("留空保留原密码，点击眼睛可查看；修改后点击保存生效。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Text(credentialHint).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    AccountNetworkPicker(draft: $networkDraft, location: model.location)
                }.padding(.trailing, 4)
            }
            Label(saveActionHint, systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if let saveBlockedReason {
                    Text(saveBlockedReason).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("account-save-status")
                }
                Spacer()
                Button("取消") { password = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        try model.saveAccount(editor: editor, label: label, username: username, password: password,
                            networkSSIDs: networkDraft.selectedSSIDs)
                        password = ""
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saveBlockedReason != nil)
                    .help(saveBlockedReason ?? saveActionHint)
            }
        }.padding(26).frame(width: 470, height: min(680, max(480, (NSScreen.main?.visibleFrame.height ?? 780) - 80)))
        .onAppear {
            guard !initializedNetworks else { return }
            initializedNetworks = true
            if let account = editor.account { networkDraft = AccountNetworkDraft(selectedSSIDs: model.networks(for: account).map(\.ssid)) }
        }
        .onDisappear { password = ""; passwordVisible = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            passwordVisible = false
        }
    }

    private var requiresUsername: Bool {
        networkDraft.requiresUsername(saved: model.networks, nearby: model.nearby)
    }
    private var requiresSecret: Bool {
        networkDraft.requiresSecret(saved: model.networks, nearby: model.nearby)
    }
    private var needsNewSecret: Bool { requiresSecret && editor.account?.hasStoredSecret != true }
    private var saveActionHint: String {
        if let network = model.reconnectNetworkAfterEditing(editor.account), networkDraft.selectedSSIDs.contains(network.ssid) {
            return "密码保存在系统钥匙串。修改用户名或密码后，保存会重新连接 \(network.ssid)，可能短暂断网。"
        }
        return "密码保存在系统钥匙串；保存此账号不会切换当前 Wi-Fi。"
    }
    private var usernameLabel: String { requiresUsername ? "用户名（企业 Wi-Fi 必填）" : "用户名（选填，仅企业 Wi-Fi 使用）" }
    private var passwordLabel: String { needsNewSecret ? "密码（必填）" : "密码（选填）" }
    private var credentialHint: String {
        if !requiresSecret { return "当前仅选择开放网络，无需用户名和密码。" }
        return "同一账号下共用一份密码；密码不同请分别保存。未识别的网络会在连接前检查认证信息。"
    }

    private var saveBlockedReason: String? {
        var missing: [String] = []
        if requiresUsername && username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("用户名") }
        if needsNewSecret && password.isEmpty { missing.append("密码") }
        if !missing.isEmpty { return "请填写\(missing.joined(separator: "和"))后保存。" }
        return model.editBlockedReason
    }

    private var passwordVisibilityLabel: String {
        if passwordVisible { return "隐藏密码" }
        return editor.account?.hasStoredSecret == true && password.isEmpty ? "查看已保存的密码" : "显示密码"
    }

    private func togglePasswordVisibility() {
        guard model.canEdit else { return }
        if passwordVisible {
            passwordVisible = false
            return
        }
        do {
            if editor.account?.hasStoredSecret == true && password.isEmpty {
                password = try model.savedPassword(for: editor)
            }
            passwordVisible = true
            error = nil
        } catch {
            self.error = "无法读取已保存的密码：\(error.localizedDescription)"
        }
    }
}

struct AccountNetworkPicker: View {
    @EnvironmentObject private var model: AppModel
    @Binding var draft: AccountNetworkDraft
    @ObservedObject var location: LocationAccess
    @State private var manualSSID = ""
    @State private var inputError: String?

    private var options: [AccountNetworkOption] { draft.options(saved: model.networks, nearby: model.nearby) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("关联 Wi-Fi（选填）").font(.system(size: 12, weight: .medium))
                Spacer()
                if model.isScanning { ProgressView().controlSize(.small) }
                Button(model.isScanning ? "扫描中…" : "扫描附近 Wi-Fi") { Task { await model.scan() } }
                    .controlSize(.small).disabled(!model.canEdit).accessibilityIdentifier("scan-account-wifi")
            }
            Text("已选 \(draft.selectedSSIDs.count) 个 · 可多选，也可先保存账号稍后添加。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .accessibilityIdentifier("selected-wifi-count")
            if let error = model.scanError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if location.denied { Button("打开定位设置") { model.openLocationSettings() }.controlSize(.small) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if options.isEmpty {
                        Text(model.isScanning ? "正在查找附近网络…" : "暂无网络，可扫描附近 Wi-Fi 或手动添加名称。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    ForEach(options) { option in
                        Toggle(isOn: Binding(get: { draft.selectedSSIDs.contains(option.ssid) }, set: {
                            draft.setSelected($0, ssid: option.ssid)
                        })) {
                            HStack(spacing: 8) {
                                Text(option.ssid).lineLimit(1).help(option.ssid)
                                Spacer(minLength: 4)
                                Text(option.detail).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                            }
                        }.toggleStyle(.checkbox)
                            .disabled(!model.canEdit)
                            .accessibilityLabel("关联 \(option.ssid)，\(option.detail)")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.frame(height: 145).scrollIndicators(.visible)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            HStack {
                TextField("手动输入 Wi-Fi 名称（SSID）", text: $manualSSID)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("手动添加 Wi-Fi 名称")
                Button("添加") {
                    do {
                        try draft.addManualSSID(manualSSID, nearby: model.nearby)
                        manualSSID = ""
                        inputError = nil
                    } catch { inputError = error.localizedDescription }
                }.disabled(manualSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canEdit)
                    .accessibilityLabel("添加手动 Wi-Fi 到待保存列表")
            }
            if let inputError { Text(inputError).font(.system(size: 11)).foregroundStyle(.red) }
            Text("企业 Wi-Fi、普通 Wi-Fi 和手机热点均可选择。未扫描到的网络可手动添加；名称区分大小写。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task {
            if model.demoMode || location.authorized { await model.scan() }
        }
        .onChange(of: location.status) { _ in
            if location.authorized { Task { await model.scan() } }
        }
    }
}

struct MenuPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var otherNetworksExpanded = false

    private var otherConnections: [MenuConnectionChoice] {
        MenuConnectionChoice.otherConnections(accounts: model.accounts, networks: model.networks,
            connectedSSID: model.snapshot.ssid, connectedAccountID: model.connectedAccountID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("WiFi Switch", systemImage: "arrow.left.arrow.right.circle").font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.isSwitching { ProgressView().controlSize(.small) }
                Menu {
                    Button("配置管理") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                    Divider()
                    Button("关于 WiFi Switch") { AppInformation.showAbout() }
                    Button("使用说明") { AppInformation.showUserGuide() }
                    Divider()
                    Button("退出系统") { NSApp.terminate(nil) }.disabled(model.isSwitching)
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 15)).frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                .help("设置").accessibilityLabel("设置").accessibilityIdentifier("menu-settings")
            }.padding(.horizontal, 12).padding(.vertical, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = model.loadError { Text(error).foregroundStyle(.red).font(.caption) }
                    if let ssid = model.snapshot.ssid, model.snapshot.poweredOn {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.snapshot.hasUsableAddress ? "已连接网络" : "当前网络 · 等待 IP")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                Image(systemName: "wifi").font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white).frame(width: 32, height: 32)
                                    .background(model.snapshot.hasUsableAddress ? Color.blue : Color.gray, in: Circle())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ssid).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(ssid)
                                    Text(model.connectedAccountID != nil ? (model.selectedAccount?.displayName ?? "未知账号") : "未知账号")
                                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                        .help(model.accountStatusDetail)
                                }
                                Spacer(minLength: 0)
                                if model.connectedAccountID != nil {
                                    Image(systemName: "checkmark.circle.fill")
                                        .symbolRenderingMode(.palette).foregroundStyle(.black, .green)
                                        .font(.system(size: 18)).accessibilityLabel("当前使用账号")
                                }
                            }.accessibilityElement(children: .combine)
                                .accessibilityIdentifier("menu-connected-network")
                        }.padding(.bottom, 4)
                    } else {
                        Text(model.snapshot.poweredOn ? "当前未连接 Wi-Fi" : "Wi-Fi 已关闭")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Divider()
                    Button { otherNetworksExpanded.toggle() } label: {
                        HStack {
                            Text("其他网络").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Image(systemName: otherNetworksExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }.foregroundStyle(.secondary).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(otherNetworksExpanded ? "收起其他网络" : "展开其他网络")
                        .accessibilityIdentifier("menu-other-networks")
                    if otherNetworksExpanded {
                        ForEach(otherConnections) { choice in
                            HStack(spacing: 8) {
                                Image(systemName: "wifi")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.secondary).frame(width: 32, height: 32)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(choice.network.ssid).font(.system(size: 12, weight: .medium))
                                        .lineLimit(1).help(choice.network.ssid)
                                    Text(choice.account.displayName).font(.system(size: 11)).foregroundStyle(.secondary)
                                        .lineLimit(1).help(choice.account.displayName)
                                }
                                Spacer(minLength: 0)
                                NetworkConnectionControl(account: choice.account, network: choice.network, compact: true)
                            }.padding(.vertical, 4)
                        }
                        if otherConnections.isEmpty {
                            Text("没有其他已保存的连接，可在配置管理中添加。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if model.isSwitching { Text(model.phase?.title ?? "正在读取密码…").font(.caption).foregroundStyle(.blue) }
                    if model.authenticationTakingLong {
                        Text("若系统再次要求密码，可取消弹窗后在账号管理中核对保存的信息。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let notice = model.notice {
                        Text(notice.text).font(.system(size: 11)).foregroundStyle(notice.isError ? Color.orange : Color.secondary)
                    }
                    if model.demoMode { Text("演示模式 · 不连接真实 Wi-Fi").font(.caption).foregroundStyle(.orange) }
                }.padding(.horizontal, 12).padding(.vertical, 16)
            }.frame(maxHeight: 350)
        }.frame(width: 350.0 * 2 / 3)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { otherNetworksExpanded = false }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
}


private struct AccountStatusLight: View {
    let status: AccountConnectionStatus
    let accountName: String
    let canReconnect: Bool
    let reconnect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showDetails = false

    private var color: Color { status.isNormal ? .green : .red }

    var body: some View {
        Button { showDetails.toggle() } label: {
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { context in
                let pulse = reduceMotion ? 0.5 : (sin(context.date.timeIntervalSinceReferenceDate * .pi) + 1) / 2
                ZStack {
                    Circle().fill(color.opacity(0.1 + 0.15 * pulse))
                        .frame(width: 20, height: 20).scaleEffect(0.8 + 0.2 * pulse)
                    Circle().fill(color).frame(width: 8, height: 8)
                        .shadow(color: color.opacity(0.25 + 0.3 * pulse), radius: 3)
                }.frame(width: 28, height: 28)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(accountName)，\(status.isNormal ? "连接正常" : "连接异常")，查看详情")
        .help(status.isNormal ? "连接正常，点击查看详情" : "连接异常，点击查看原因")
        .popover(isPresented: $showDetails) {
            VStack(alignment: .leading, spacing: 10) {
                Label(status.isNormal ? "连接正常" : "连接异常", systemImage: status.isNormal ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(color).font(.headline)
                Text(accountName).font(.subheadline)
                Text(status.detail).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                if !status.isNormal {
                    Button("重新连接") { showDetails = false; reconnect() }
                        .buttonStyle(.borderedProminent).disabled(!canReconnect)
                    Text("重新连接会短暂中断网络。").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(16).frame(width: 280)
        }
    }
}
