import SwiftUI
import WiFiSwitchCore

struct WiFiInformationView: View {
    @EnvironmentObject private var model: AppModel
    let account: WiFiAccount
    let network: SavedWiFi
    @Environment(\.dismiss) private var dismiss
    @State private var information: WiFiInformation?
    @State private var loading = false
    private var canView: Bool { model.canViewWiFiInformation(for: account, on: network) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Wi-Fi 信息").font(.title2.bold())
                Text(network.ssid).font(.headline).textSelection(.enabled)
                Text(information?.status ?? "正在读取…")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(information?.sections ?? []) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title).font(.headline)
                            ForEach(section.rows) { row in
                                HStack(alignment: .top, spacing: 16) {
                                    Text(row.title).foregroundStyle(.secondary).frame(width: 142, alignment: .leading)
                                    Text(row.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if information?.sections.count ?? 0 > 1 {
                        Text("当前 DNS 为系统分配给 Wi-Fi 接口的解析器地址，不代表每次请求实际命中的服务器；手动设置和自动获取仅列出配置来源。请先在系统设置中保存修改。VPN、加密 DNS 或按域名分流可能使用其他解析器。认证信息不包含密码或实时认证用户名。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
            }
            Divider()
            HStack(spacing: 12) {
                if loading { ProgressView().controlSize(.small) }
                else if let timestamp = information?.timestamp {
                    Text("更新于 \(timestamp.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新") { Task { await refresh() } }.disabled(loading)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
        }
        .frame(width: 560, height: 610)
        .onChange(of: canView) { allowed in
            if !allowed { information = nil; dismiss() }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    @MainActor private func refresh() async {
        guard canView else { information = nil; dismiss(); return }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let result: WiFiInformation
        if model.demoMode {
            result = WiFiInformationReader.demo(ssid: network.ssid)
        } else {
            result = await WiFiInformationReader.read(ssid: network.ssid, authentication: network.authentication)
        }
        guard !Task.isCancelled else { return }
        guard canView, result.connectionConfirmed else { information = nil; dismiss(); return }
        information = result
    }
}
