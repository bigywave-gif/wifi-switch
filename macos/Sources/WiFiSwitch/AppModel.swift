import AppKit
import Foundation
import WiFiSwitchCore

struct AppNotice: Identifiable {
    let id = UUID()
    let text: String
    var isError = false
    var accountEditor: AccountEditor?
}

struct AccountEditor: Identifiable {
    let id = UUID()
    let account: WiFiAccount?
}

struct SystemImportCandidate: Identifiable {
    let id = UUID()
    let ssid: String
    var automatic = false
}

struct AccountDeletion: Identifiable {
    var id: UUID { account.id }
    let account: WiFiAccount
}

enum AccountConnectionStatus: Equatable {
    case normal
    case abnormal(String)

    var isNormal: Bool { self == .normal }
    var detail: String {
        switch self {
        case .normal: return "已连接目标 Wi-Fi，并获取到可用 IP 地址。尚未检测互联网或公司业务服务。"
        case .abnormal(let reason): return reason
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var networks: [SavedWiFi] = []
    @Published private(set) var accounts: [WiFiAccount] = []
    @Published private(set) var isSwitching = false
    @Published private(set) var switchingAccountID: UUID?
    @Published private(set) var switchingNetworkID: UUID?
    @Published private(set) var phase: SwitchPhase?
    @Published private(set) var authenticationTakingLong = false
    @Published private(set) var snapshot = WiFiSnapshot(ssid: nil, poweredOn: true, available: true)
    @Published private(set) var accountSelection: SessionAccountSelection?
    @Published private(set) var interruptedAccount: SessionAccountSelection?
    @Published private(set) var isCheckingConnection = false
    @Published private(set) var automaticReconnectFailures = 0
    @Published private(set) var automaticReconnectError: String?
    @Published private(set) var automaticReconnectNeedsCredentialReview = false
    @Published private(set) var isScanning = false
    @Published private(set) var nearby: [NearbyWiFi] = []
    @Published private(set) var scanCompleted = false
    @Published private(set) var scanError: String?
    @Published var notice: AppNotice?
    @Published var networkEditor: WiFiAccount?
    @Published var editor: AccountEditor?
    @Published var deletion: AccountDeletion?
    @Published var expanded = Set<UUID>()
    @Published private(set) var loadError: String?
    let location = LocationAccess()
    let demoMode: Bool
    let dataURL: URL
    private var repository: AccountRepository?
    private let wifi: any WiFiServicing
    @Published private(set) var systemImportCandidate: SystemImportCandidate?
    @Published private(set) var isImporting = false
    @Published private(set) var systemImportError: String?
    private let syncPreferenceDecision: ((WiFiAccount, SavedWiFi) -> Bool?)?
    private var isConfirmingConnection = false
    private var hasLiveAppConnection = false
    private let systemReader: (any SystemConnectionReading)?
    private var dismissedImports: Set<String> = []
    private var systemIdentityUnresolved = false
    private var missingSystemConfigurationSSID: String?
    private lazy var importWindow = SystemImportWindow()
    private let allowsSwitching: Bool
    private var waitHintTask: Task<Void, Never>?
    private var connectionMonitor: WiFiConnectionMonitor?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var isSuspended = false
    private var connectionRevision = 0
    private let automaticReconnectEnabled: Bool
    private let automaticReconnectDelay: Duration
    private var automaticReconnectTask: Task<Void, Never>?
    private var automaticReconnectCycle = UUID()
    private var monitoringTask: Task<Void, Never>?

    init(demoMode: Bool = false, wifi: (any WiFiServicing)? = nil, repository: AccountRepository? = nil,
         automaticReconnectEnabled: Bool? = nil, automaticReconnectDelay: Duration = .seconds(10),
         systemReader: (any SystemConnectionReading)? = nil,
         syncPreferenceDecision: ((WiFiAccount, SavedWiFi) -> Bool?)? = nil) {
        self.syncPreferenceDecision = syncPreferenceDecision
        self.demoMode = demoMode
        self.systemReader = systemReader ?? (demoMode ? nil : SystemConnectionReader())
        if !demoMode { dismissedImports = Set(UserDefaults.standard.stringArray(forKey: "dismissedSystemImports") ?? []) }
        self.automaticReconnectEnabled = automaticReconnectEnabled ?? !demoMode
        self.automaticReconnectDelay = automaticReconnectDelay
        self.wifi = wifi ?? WiFiService()
        // Normal demo launches remain unable to connect; tests inject an in-memory service.
        allowsSwitching = !demoMode || wifi != nil
        dataURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WiFiSwitch/accounts.json")
        do {
            if let repository {
                self.repository = repository
            } else if demoMode {
                self.repository = try AccountRepository(storage: MemoryStorage(), vault: MemoryVault())
                let id = try self.repository!.addNetwork(ssid: "Office · Enterprise")
                let work = try self.repository!.saveAccount(networkID: id, label: "日常办公", username: "work@example.com", newPassword: "demo-only")
                try self.repository!.saveAccount(networkID: id, label: "测试环境", username: "test@example.com", newPassword: "demo-only")
                try self.repository!.markUsed(networkID: id, accountID: work)
                snapshot.ssid = "Office · Enterprise"
                snapshot.hasUsableAddress = true
            } else {
                self.repository = try AccountRepository(storage: JSONConfigurationStorage(url: dataURL), vault: KeychainVault())
            }
            sync()
            if automaticReconnectStopped {
                notice = automaticReconnectStoppedNotice
            }
            isCheckingConnection = self.repository?.configuration.currentConnection != nil || self.repository?.configuration.version == 1
            expanded = Set(accounts.map(\.id))
        } catch { loadError = error.localizedDescription }
        if !demoMode {
            connectionMonitor = WiFiConnectionMonitor { [weak self] in
                Task { @MainActor in
                    await self?.connectionDidChange()
                }
            }
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.suspendConnectionForSleep() }
            }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.resumeConnectionAfterWake() }
            }
            // Continue observing even when both the main window and menu are closed.
            monitoringTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let self else { return }
                    await self.refresh()
                }
            }
        }
    }

    deinit {
        monitoringTask?.cancel()
        automaticReconnectTask?.cancel()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    var editBlockedReason: String? {
        if loadError != nil { return "账号列表读取失败，暂时无法保存。" }
        if isConfirmingConnection { return "请先选择是否同步系统首选账号。" }
        if isImporting { return "正在导入系统 Wi-Fi 配置，请稍后。" }
        if isSwitching { return "正在连接账号，请等待连接结束后保存。" }
        if isScanning { return "正在扫描 Wi-Fi，请等待扫描结束后保存。" }
        if isCheckingConnection { return "正在确认当前连接，请稍后保存。" }
        return nil
    }

    var canEdit: Bool { editBlockedReason == nil }
    var accountCount: Int { accounts.count }

    var connectedNetwork: SavedWiFi? { networks.first { $0.ssid == snapshot.ssid } }

    var selectedAccount: WiFiAccount? {
        guard let selection = accountSelection,
              selection.isValid(connectedSSID: snapshot.ssid, networks: networks) else { return nil }
        return connectedNetwork?.accounts.first { $0.id == selection.accountID }
    }

    var connectedAccountID: UUID? {
        guard let account = selectedAccount, let network = connectedNetwork,
              accountConnectionStatus(for: account, on: network) == .normal else { return nil }
        return account.id
    }

    func canViewWiFiInformation(for account: WiFiAccount, on network: SavedWiFi) -> Bool {
        connectedAccountID == account.id && connectedNetwork?.id == network.id
    }

    /// Pin only the confirmed connected account; keep stored order and all other rows unchanged.
    var displayAccounts: [WiFiAccount] {
        guard let id = connectedAccountID, let current = accounts.first(where: { $0.id == id }) else { return accounts }
        return [current] + accounts.filter { $0.id != id }
    }

    var accountStatusTitle: String {
        if isCheckingConnection { return "当前账号：正在读取连接状态" }
        if isSwitching { return "当前账号：正在连接，尚未确认" }
        guard snapshot.ssid != nil else { return "当前账号：尚未识别连接" }
        guard let account = selectedAccount, let source = accountSelection?.source else {
            return "当前账号：未识别"
        }
        let name = account.displayName
        switch source {
        case .systemSavedCredentials: return "当前账号（系统保存配置）：\(name)"
        case .manual: return "当前账号（手动标记）：\(name)"
        case .successfulSwitch, .restoredConnection: return "当前账号：\(name)"
        }
    }

    var accountStatusDetail: String {
        if isSwitching { return "连接完成前，不显示上一个账号为当前账号。" }
        guard snapshot.ssid != nil else {
            return snapshot.ssidIsReadable ? "连接 Wi-Fi 后可查看账号状态。" : "允许读取 Wi-Fi 名称后会检查现有连接；不需要为此重新连接网络。"
        }
        switch accountSelection?.source {
        case .systemSavedCredentials:
            return "根据当前 Wi-Fi 和系统保存的配置识别；这不代表已核实本次认证实际使用的账号。"
        case .manual:
            return "这是你手动标记的账号，未经系统核实。重新打开应用时，会在 Wi-Fi 匹配后恢复。"
        case .successfulSwitch:
            return "通过 WiFi Switch 连接成功，已保存当前账号，重新打开应用无需重复连接。"
        case .restoredConnection:
            return "已根据保存的账号记录和当前 Wi-Fi 恢复，无需重新连接。若在系统中更换过账号，可通过所需账号重新连接。"
        case nil:
            return "系统已连接此 Wi-Fi，但没有匹配的账号记录。通过工具连接成功后会自动保存当前账号。"
        }
    }

    func markCurrentAccount(_ account: WiFiAccount, on network: SavedWiFi) {
        guard canEdit, snapshot.ssid == network.ssid, !isCurrentAccount(account, on: network) else { return }
        let selection = SessionAccountSelection(network: network, account: account, source: .manual)
        guard selection.isValid(connectedSSID: snapshot.ssid, networks: networks) else { return }
        do {
            try repository?.rememberConnection(selection)
            connectionRevision += 1
            accountSelection = selection
            interruptedAccount = nil
        } catch { show(error) }
    }

    func clearAccountSelection() {
        cancelAutomaticReconnect()
        connectionRevision += 1
        interruptedAccount = nil
        accountSelection = nil
        do { try repository?.clearRememberedConnection() }
        catch { show(error) }
    }

    func isCurrentAccount(_ account: WiFiAccount, on network: SavedWiFi) -> Bool {
        !isSwitching && snapshot.available && snapshot.poweredOn &&
            accountSelection?.networkID == network.id && selectedAccount?.id == account.id
    }

    func accountConnectionStatus(for account: WiFiAccount, on network: SavedWiFi) -> AccountConnectionStatus? {
        guard !isSwitching, !isCheckingConnection else { return nil }
        if automaticReconnectStopped,
           repository?.configuration.currentConnection?.accountID == account.id,
           repository?.configuration.currentConnection?.networkID == network.id {
            return .abnormal(automaticReconnectStoppedMessage)
        }
        if isCurrentAccount(account, on: network) {
            return snapshot.hasUsableAddress ? .normal : .abnormal("已连接此 Wi-Fi，但未获取到可用 IP 地址。可能正在等待网络分配地址，请稍后重试或联系网络管理员。")
        }
        guard let previous = interruptedAccount,
              previous.networkID == network.id, previous.accountID == account.id,
              previous.isValid(connectedSSID: network.ssid, networks: networks) else { return nil }
        if !snapshot.available { return .abnormal("系统未检测到可用的 Wi-Fi 网卡，之前的账号连接已中断。") }
        if !snapshot.poweredOn { return .abnormal("系统 Wi-Fi 已关闭，之前的账号连接已中断。请先开启 Wi-Fi。") }
        if snapshot.ssid == nil && !snapshot.ssidIsReadable { return nil }
        if snapshot.ssid == nil { return .abnormal("与目标 Wi-Fi 的连接已断开。请检查信号或网络是否可用，再重新连接。") }
        guard snapshot.ssid == network.ssid else { return nil }
        return .abnormal("正在核对已保存账号对应的 Wi-Fi 状态，连接记录已保留。")
    }

    func accountBadge(for account: WiFiAccount, on network: SavedWiFi) -> String? {
        guard isCurrentAccount(account, on: network) else { return nil }
        return accountSelection?.source.label
    }

    func networks(for account: WiFiAccount) -> [SavedWiFi] {
        networks.filter { network in network.accounts.contains { $0.id == account.id } }
    }

    func addNetwork(ssid: String, to account: WiFiAccount) throws {
        guard canEdit, let repository else { throw StoreError.invalidConfiguration }
        try repository.linkNetwork(accountID: account.id, ssid: ssid, authentication: nearby.first { $0.ssid == ssid }?.authentication ?? networks.first { $0.ssid == ssid }?.authentication ?? .unknown)
        sync()
        expanded.insert(account.id)
        notice = AppNotice(text: "已为 \(account.displayName) 添加 \(ssid)，连接时将使用此账号保存的凭据。")
    }

    func unlinkNetwork(_ network: SavedWiFi, from account: WiFiAccount) {
        guard canEdit else { return }
        do {
            try repository?.unlinkNetwork(accountID: account.id, networkID: network.id)
            sync()
            notice = AppNotice(text: "已移除 Wi-Fi 关联；账号和密码仍保留，系统连接未改变。")
        } catch { show(error) }
    }

    func reconnectNetworkAfterEditing(_ account: WiFiAccount?) -> SavedWiFi? {
        let previous = accountSelection ?? interruptedAccount ?? repository?.configuration.currentConnection
        guard let account, let previous, previous.accountID == account.id,
              snapshot.available, snapshot.poweredOn,
              snapshot.ssid == previous.ssid || (snapshot.ssid == nil && snapshot.ssidIsReadable),
              previous.isValid(connectedSSID: previous.ssid, networks: networks) else { return nil }
        return networks.first { $0.id == previous.networkID }
    }

    @discardableResult
    func saveAccount(editor: AccountEditor, label: String, username: String, password: String,
                     networkIDs: [UUID]? = nil, networkSSIDs: [String]? = nil) throws -> Task<Void, Never>? {
        guard canEdit, let repository else { throw StoreError.invalidConfiguration }
        let previousSelection = accountSelection ?? interruptedAccount ?? repository.configuration.currentConnection
        let reconnectNetwork = reconnectNetworkAfterEditing(editor.account)
        let id = try repository.saveAccount(accountID: editor.account?.id,
            label: label, username: username, newPassword: password.isEmpty ? nil : password,
            networkIDs: networkIDs, networkSSIDs: networkSSIDs,
            networkAuthentications: AccountNetworkDraft(selectedSSIDs: networkSSIDs ?? []).authentications(saved: networks, nearby: nearby))
        expanded.insert(id)
        // The repository preserves the marker for an unchanged password. Losing it
        // after a credential edit means the saved identity must be authenticated again.
        let changedCurrentCredentials = previousSelection?.accountID == editor.account?.id && previousSelection != nil &&
            repository.configuration.currentConnection == nil &&
            (!password.isEmpty || previousSelection?.username != username.trimmingCharacters(in: .whitespacesAndNewlines))
        if previousSelection?.accountID == editor.account?.id,
           repository.configuration.currentConnection == nil {
            cancelAutomaticReconnect()
            connectionRevision += 1
            accountSelection = nil
            interruptedAccount = nil
        }
        sync()
        if changedCurrentCredentials, let target = reconnectNetwork,
           let updatedAccount = accounts.first(where: { $0.id == id }),
           let updatedNetwork = networks.first(where: { $0.id == target.id && $0.accounts.contains(where: { $0.id == id }) }) {
            let task = connectAccount(updatedAccount, on: updatedNetwork, reconnect: true, afterSaving: true)
            if task == nil {
                notice = AppNotice(text: "账号已保存，但未能开始重新连接：\(notice?.text ?? "请检查当前网络状态。")", isError: true,
                                   accountEditor: AccountEditor(account: updatedAccount))
            }
            return task
        }
        notice = AppNotice(text: "账号已保存。展开账号添加 Wi-Fi，再点击对应网络的“连接”。")
        return nil
    }

    func savedPassword(for editor: AccountEditor) throws -> String {
        guard canEdit, let repository, let account = editor.account,
              accounts.contains(where: { $0.id == account.id })
        else { throw StoreError.invalidConfiguration }
        return try repository.password(for: account.id)
    }

    func deleteAccount(_ item: AccountDeletion) {
        guard canEdit else { return }
        do {
            try repository?.deleteAccount(accountID: item.account.id)
            sync()
            notice = AppNotice(text: "账号及其保存的密码已删除。")
        } catch { show(error) }
    }

    func refresh() async {
        guard (!demoMode || allowsSwitching) && !isSwitching && !isScanning && !isSuspended else { return }
        // Only the latest refresh may publish a result. Sleep and explicit account actions
        // also invalidate in-flight reads so an older snapshot cannot erase new state.
        connectionRevision += 1
        let revision = connectionRevision
        let latest = await wifi.snapshot()
        guard !isSwitching && !isScanning && !isSuspended && revision == connectionRevision else { return }
        defer {
            if revision == connectionRevision {
                isCheckingConnection = false
                scheduleAutomaticReconnectIfNeeded()
                proposeSystemImport()
            }
        }
        missingSystemConfigurationSSID = nil
        let previousAccount = accountSelection ?? interruptedAccount ?? repository?.configuration.currentConnection
        if latest.ssid != snapshot.ssid || !latest.poweredOn || !latest.hasUsableAddress { hasLiveAppConnection = false }
        snapshot = latest
        if let candidate = systemImportCandidate, candidate.ssid != latest.ssid || !latest.poweredOn { cancelSystemImport() }
        // Observations never delete the user's connection record. Sleep, startup,
        // temporary outages and another SSID affect live status, not saved identity.
        guard latest.available, latest.poweredOn, let ssid = latest.ssid else {
            accountSelection = nil
            interruptedAccount = previousAccount
            return
        }
        if let systemReader, latest.hasUsableAddress, !isImporting, !hasLiveAppConnection {
            let identity = await systemReader.identity(ssid: ssid)
            guard revision == connectionRevision, !isSwitching, !isSuspended else { return }
            let checked = await wifi.snapshot()
            guard revision == connectionRevision, checked.ssid == ssid, checked.poweredOn, checked.hasUsableAddress else { return }
            snapshot = checked
            if let identity, identity.ssid == ssid, let account = matchingSystemAccount(identity), let network = connectedNetwork {
                let selection = SessionAccountSelection(network: network, account: account, source: .systemSavedCredentials)
                do {
                    // Do not erase an authentication failure merely because its saved username matches.
                    let old = repository?.configuration.currentConnection
                    if old?.accountID != selection.accountID || old?.networkID != selection.networkID || old?.username != selection.username {
                        try repository?.rememberConnection(selection)
                        sync()
                    }
                    accountSelection = selection
                    interruptedAccount = nil
                    systemIdentityUnresolved = false
                    if systemImportCandidate?.automatic == true { cancelSystemImport() }
                } catch { show(error) }
            } else {
                accountSelection = nil
                interruptedAccount = previousAccount
                systemIdentityUnresolved = true
                if let identity, identity.ssid == ssid, systemConfigurationIsMissing(identity) {
                    missingSystemConfigurationSSID = ssid
                } else if systemImportCandidate?.automatic == true {
                    cancelSystemImport()
                }
            }
            return
        }
        if systemReader != nil, latest.hasUsableAddress { return }
        do { try repository?.migrateConnectionRecord(connectedSSID: ssid) }
        catch { show(error) }
        if let remembered = previousAccount ?? repository?.configuration.currentConnection,
           remembered.isValid(connectedSSID: ssid, networks: networks) {
            if accountSelection != remembered {
                accountSelection = remembered.restored(networks: networks)
            }
            interruptedAccount = nil
            if latest.hasUsableAddress, !automaticReconnectNeedsCredentialReview, (1..<3).contains(automaticReconnectFailures) {
                do {
                    try repository?.clearAutomaticReconnectFailure()
                    automaticReconnectFailures = 0
                    automaticReconnectError = nil
                } catch { show(error) }
            }
        } else {
            accountSelection = nil
            interruptedAccount = previousAccount
        }
    }

    func connectionDidChange() async {
        if !isSwitching { hasLiveAppConnection = false }
        // A successful association also emits notifications. Refresh the actual connection
        // instead of clearing the account blindly, including late notifications from our switch.
        await refresh()
    }

    func suspendConnectionForSleep() {
        hasLiveAppConnection = false
        cancelAutomaticReconnect()
        connectionRevision += 1
        isSuspended = true
        interruptedAccount = accountSelection ?? interruptedAccount
        accountSelection = nil
        cancelSystemImport()
        isCheckingConnection = true
        // Sleep interrupts observation, not the saved identity. Never delete it here.
    }

    func resumeConnectionAfterWake() async {
        isSuspended = false
        await refresh()
    }

    private var automaticReconnectStopped: Bool {
        automaticReconnectNeedsCredentialReview || automaticReconnectFailures >= 3
    }

    private var automaticReconnectStoppedMessage: String {
        let summary = automaticReconnectNeedsCredentialReview ?
            "认证失败，已停止自动重试。请核对并修改用户名或密码；如信息无误，请检查网络权限或证书。" :
            "自动重连连续失败 3 次，已停止重试。请检查网络后手动重新连接。"
        return summary + (automaticReconnectError.map { "\n最近原因：\($0)" } ?? "")
    }

    private var automaticReconnectStoppedNotice: AppNotice {
        let account = accounts.first { $0.id == repository?.configuration.currentConnection?.accountID }
        return AppNotice(text: automaticReconnectStoppedMessage, isError: true,
                         accountEditor: automaticReconnectNeedsCredentialReview ? account.map { AccountEditor(account: $0) } : nil)
    }

    private var automaticReconnectTarget: (SessionAccountSelection, WiFiAccount, SavedWiFi)? {
        guard automaticReconnectEnabled, !isSuspended, !isSwitching, !isScanning, !isImporting, !isConfirmingConnection, !systemIdentityUnresolved,
              !automaticReconnectStopped, snapshot.available, snapshot.poweredOn,
              snapshot.ssidIsReadable, demoMode || location.authorized,
              let selection = repository?.configuration.currentConnection,
              selection.isValid(connectedSSID: selection.ssid, networks: networks),
              snapshot.ssid == nil || (snapshot.ssid == selection.ssid && !snapshot.hasUsableAddress),
              let network = networks.first(where: { $0.id == selection.networkID }),
              let account = accounts.first(where: { $0.id == selection.accountID }) else { return nil }
        return (selection, account, network)
    }

    private func cancelAutomaticReconnect() {
        automaticReconnectCycle = UUID()
        automaticReconnectTask?.cancel()
        automaticReconnectTask = nil
    }

    private func scheduleAutomaticReconnectIfNeeded() {
        guard automaticReconnectTask == nil, automaticReconnectTarget != nil else { return }
        let cycle = UUID()
        automaticReconnectCycle = cycle
        let delay = automaticReconnectDelay
        automaticReconnectTask = Task { @MainActor [weak self] in
            defer {
                if self?.automaticReconnectCycle == cycle { self?.automaticReconnectTask = nil }
            }
            while !Task.isCancelled {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self else { return }
                await self.refresh()
                guard !Task.isCancelled, self.automaticReconnectCycle == cycle,
                      let (_, account, network) = self.automaticReconnectTarget,
                      let attempt = self.connectAccount(account, on: network, reconnect: true, automatic: true) else { return }
                await attempt.value
                guard !Task.isCancelled, self.automaticReconnectCycle == cycle else { return }
                if self.notice?.isError != true { return }
                if self.automaticReconnectStopped {
                    self.notice = self.automaticReconnectStoppedNotice
                    return
                }
            }
        }
    }

    func scan() async {
        guard canEdit else { return }
        scanError = nil
        scanCompleted = false
        nearby = []
        if demoMode {
            nearby = [NearbyWiFi(ssid: "Office · Enterprise", rssi: -45, supportsEnterpriseAuthentication: true), NearbyWiFi(ssid: "Campus", rssi: -61, supportsEnterpriseAuthentication: true), NearbyWiFi(ssid: "Phone Hotspot", rssi: -68), NearbyWiFi(ssid: "Guest Open", rssi: -72, authentication: .open)]
            scanCompleted = true
            return
        }
        guard location.authorized else {
            scanError = WiFiError.locationRequired.localizedDescription
            if !location.denied { location.request() }
            return
        }
        isScanning = true
        defer { isScanning = false; scanCompleted = true }
        do { nearby = try await wifi.scan() }
        catch { scanError = error.localizedDescription }
    }

    @discardableResult
    func switchAccount(_ account: WiFiAccount, on network: SavedWiFi) -> Task<Void, Never>? {
        connectAccount(account, on: network, reconnect: false)
    }

    @discardableResult
    func reconnectAccount(_ account: WiFiAccount, on network: SavedWiFi) -> Task<Void, Never>? {
        connectAccount(account, on: network, reconnect: true)
    }

    @discardableResult
    private func connectAccount(_ account: WiFiAccount, on network: SavedWiFi, reconnect: Bool,
                                automatic: Bool = false, afterSaving: Bool = false) -> Task<Void, Never>? {
        // Only an explicit reconnect action may bypass the healthy-current-account guard.
        guard canEdit, reconnect || !isCurrentAccount(account, on: network) || !snapshot.hasUsableAddress,
              networks.contains(where: { $0.id == network.id && $0.accounts.contains(where: { $0.id == account.id && $0.username == account.username }) })
        else { return nil }
        guard allowsSwitching else { show(WiFiError.demoMode); return nil }
        guard demoMode || location.authorized else {
            show(WiFiError.locationRequired)
            if !location.denied { location.request() }
            return nil
        }
        guard let repository else { return nil }
        let synchronize: Bool
        if automatic { synchronize = false }
        else {
            isConfirmingConnection = true
            let choice: Bool?
            if let syncPreferenceDecision { choice = syncPreferenceDecision(account, network) }
            else if demoMode { choice = true }
            else {
                choice = SystemSyncChoice().run(ssid: network.ssid, account: account.displayName)
            }
            isConfirmingConnection = false
            guard let choice else { return nil }
            synchronize = choice
        }
        cancelSystemImport()
        let remembered = repository.configuration.currentConnection
        if !automatic {
            // Only an explicit account change invalidates the saved identity.
            do { try repository.clearRememberedConnection() }
            catch { show(error); return nil }
            cancelAutomaticReconnect()
            automaticReconnectFailures = 0
            automaticReconnectError = nil
            automaticReconnectNeedsCredentialReview = false
        }
        interruptedAccount = nil
        connectionRevision += 1
        accountSelection = nil
        isSwitching = true
        switchingAccountID = account.id
        switchingNetworkID = network.id
        phase = nil
        authenticationTakingLong = false
        notice = automatic ? AppNotice(text: "网络异常，正在自动重连（\(automaticReconnectFailures + 1)/3）…") :
            (afterSaving ? AppNotice(text: "账号已保存，正在使用新凭据重新连接 \(network.ssid)…") : nil)
        return Task {
            var attemptedPassword: String?
            defer {
                waitHintTask?.cancel()
                waitHintTask = nil
                authenticationTakingLong = false
                isSwitching = false
                switchingAccountID = nil
                switchingNetworkID = nil
                phase = nil
            }
            do {
                let password = network.authentication == .open ? "" : try repository.password(for: account.id)
                attemptedPassword = password
                let progress: (SwitchPhase) -> Void = { phase in
                    Task { @MainActor in
                        if self.isSwitching && self.switchingAccountID == account.id {
                            self.phase = phase
                            if phase == .disconnecting { self.snapshot.ssid = nil }
                            if phase == .authenticating {
                                self.waitHintTask = Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                                    if !Task.isCancelled && self.phase == .authenticating {
                                        self.authenticationTakingLong = true
                                    }
                                }
                            } else {
                                self.waitHintTask?.cancel()
                                self.authenticationTakingLong = false
                            }
                        }
                    }
                }
                if automatic {
                    try await wifi.reconnectAccount(ssid: network.ssid, username: account.username, password: password, progress: progress)
                } else {
                    try await wifi.switchAccount(ssid: network.ssid, username: account.username, password: password, synchronizeSystemCredentials: synchronize, progress: progress)
                }
                snapshot = await wifi.snapshot()
                let selection = automatic ? (remembered ?? SessionAccountSelection(network: network, account: account, source: .successfulSwitch)) :
                    SessionAccountSelection(network: network, account: account, source: .successfulSwitch)
                systemIdentityUnresolved = false
                guard snapshot.available && snapshot.poweredOn,
                      selection.isValid(connectedSSID: snapshot.ssid, networks: networks),
                      !automatic || snapshot.hasUsableAddress
                else { throw WiFiError.verificationTimeout }
                accountSelection = selection
                hasLiveAppConnection = !automatic
                do {
                    try repository.rememberConnection(selection, connectedAt: automatic ? nil : Date())
                    sync()
                    notice = AppNotice(text: "\(automatic ? "自动重连成功" : (afterSaving ? "账号已保存并重新连接成功" : "连接成功"))，当前账号：\(account.displayName)。" +
                        (automatic ? "" : (synchronize ? "已同步此 Wi-Fi 的系统账号凭据。" : "已保留原有系统账号凭据，本次使用所选账号。")))
                } catch {
                    notice = AppNotice(text: "已连接 \(network.ssid)，但账号记录保存失败，重开后可能无法恢复：\(error.localizedDescription)", isError: true)
                }
            } catch {
                // Framework errors may include credential context; only present a sanitized description.
                let requiresCredentialReview = connectionRequiresCredentialReview(error)
                var message = connectionErrorMessage(error)
                if let password = attemptedPassword, !password.isEmpty {
                    message = message.replacingOccurrences(of: password, with: "••••••")
                }
                if automatic, let remembered {
                    automaticReconnectNeedsCredentialReview = requiresCredentialReview
                    do {
                        try repository.recordAutomaticReconnectFailure(for: remembered, reason: message,
                                                                        requiresCredentialReview: requiresCredentialReview)
                        automaticReconnectFailures = repository.configuration.automaticReconnectFailure?.count ?? 0
                        automaticReconnectError = message
                    } catch {
                        // If the retry limit cannot be persisted, stop instead of retrying forever.
                        automaticReconnectFailures = 3
                        automaticReconnectError = "无法保存重试状态：\(error.localizedDescription)"
                    }
                }
                if automatic && automaticReconnectNeedsCredentialReview {
                    notice = automaticReconnectStoppedNotice
                } else {
                    let stoppedHint = requiresCredentialReview ? "已停止自动重试，请修改账号后再连接。" : ""
                    notice = AppNotice(text: "\(automatic ? "自动重连失败（\(automaticReconnectFailures)/3）" : (afterSaving ? "账号已保存，但重新连接未完成" : "连接未完成"))：\(stoppedHint)\(message)", isError: true,
                                       accountEditor: error is SystemDefaultSyncError || error is SystemCredentialPreservationError ? nil : AccountEditor(account: account))
                }
                snapshot = await wifi.snapshot()
            }
        }
    }

    private func matchingSystemAccount(_ identity: SystemConnectionIdentity) -> WiFiAccount? {
        guard let network = networks.first(where: { $0.ssid == identity.ssid && $0.authentication == identity.authentication }) else { return nil }
        let matches = network.accounts.filter { account in
            identity.authentication == .enterprise ? account.username == identity.username : true
        }
        // Personal/open networks have no username: only a unique association can be inferred.
        return matches.count == 1 ? matches[0] : nil
    }

    private func systemConfigurationIsMissing(_ identity: SystemConnectionIdentity) -> Bool {
        guard identity.authentication != .unknown,
              identity.authentication != .enterprise || identity.username?.isEmpty == false else { return false }
        guard let network = networks.first(where: { $0.ssid == identity.ssid }) else { return true }
        // A conflicting authentication type or multiple personal accounts is ambiguity,
        // not proof that the user needs to create another account.
        guard network.authentication == identity.authentication else { return false }
        if identity.authentication == .enterprise {
            return !network.accounts.contains { $0.username == identity.username }
        }
        return network.accounts.isEmpty
    }

    var canImportSystemConnection: Bool {
        systemReader != nil && canEdit && snapshot.available && snapshot.poweredOn && snapshot.hasUsableAddress && snapshot.ssid != nil
    }

    private func proposeSystemImport() {
        guard selectedAccount == nil, systemImportCandidate == nil, editor == nil, networkEditor == nil, deletion == nil,
              let ssid = snapshot.ssid, missingSystemConfigurationSSID == ssid,
              !dismissedImports.contains(ssid), canImportSystemConnection else { return }
        beginSystemImport(automatic: true)
    }

    func beginSystemImport(automatic: Bool = false) {
        guard canImportSystemConnection, let ssid = snapshot.ssid else { return }
        dismissedImports.insert(ssid)
        if !demoMode { UserDefaults.standard.set(Array(dismissedImports), forKey: "dismissedSystemImports") }
        systemImportCandidate = SystemImportCandidate(ssid: ssid, automatic: automatic)
        systemImportError = nil
        if !demoMode || CommandLine.arguments.contains("--demo-import") { importWindow.present(model: self) }
    }

    func cancelSystemImport() {
        systemImportCandidate = nil
        systemImportError = nil
        if !demoMode || CommandLine.arguments.contains("--demo-import") { importWindow.dismiss() }
        // Keep isImporting until a pending Keychain call returns. Its result is discarded.
    }

    func confirmSystemImport(label: String) async {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !isImporting, let candidate = systemImportCandidate,
              let systemReader, let repository, canImportSystemConnection else { return }
        isImporting = true
        systemImportError = nil
        cancelAutomaticReconnect()
        defer { isImporting = false }
        do {
            let before = await wifi.snapshot()
            guard before.ssid == candidate.ssid, before.poweredOn, before.hasUsableAddress,
                  systemImportCandidate?.id == candidate.id else { throw SystemImportError.connectionChanged }
            let configuration = try await systemReader.configuration(ssid: candidate.ssid)
            let after = await wifi.snapshot()
            guard systemImportCandidate?.id == candidate.id, after.ssid == candidate.ssid,
                  after.poweredOn, after.hasUsableAddress, configuration.identity.ssid == candidate.ssid else { throw SystemImportError.connectionChanged }
            let identity = configuration.identity
            guard identity.authentication != .unknown,
                  !identity.authentication.requiresUsername || identity.username?.isEmpty == false,
                  !identity.authentication.requiresSecret || configuration.password?.isEmpty == false else { throw SystemImportError.unavailable }
            let id: UUID
            if let existing = matchingSystemAccount(identity) {
                // Never overwrite saved credentials or names as a side effect of importing.
                guard try repository.password(for: existing.id) == (configuration.password ?? "") else { throw SystemImportError.duplicate }
                id = existing.id
            } else {
                if networks.contains(where: { $0.ssid == identity.ssid && $0.authentication != identity.authentication }) {
                    throw SystemImportError.ambiguous
                }
                if identity.authentication != .enterprise, connectedNetwork?.accounts.isEmpty == false { throw SystemImportError.ambiguous }
                do {
                    id = try repository.saveAccount(label: label, username: identity.username ?? "", newPassword: configuration.password,
                        networkSSIDs: [identity.ssid], networkAuthentications: [identity.ssid: identity.authentication])
                } catch { throw SystemImportError.storage }
            }
            snapshot = after
            sync()
            guard let network = connectedNetwork, let account = accounts.first(where: { $0.id == id }) else { throw SystemImportError.storage }
            let selection = SessionAccountSelection(network: network, account: account, source: .systemSavedCredentials)
            do {
                try repository.rememberConnection(selection)
                sync()
                accountSelection = selection
                interruptedAccount = nil
                systemIdentityUnresolved = false
                notice = AppNotice(text: "已保存系统 Wi-Fi 配置，并根据系统保存的信息更新账号标记；没有重新连接网络。")
            } catch {
                notice = AppNotice(text: "配置已添加，但连接标记未能保存。请检查配置文件权限。", isError: true)
            }
            expanded.insert(id)
            cancelSystemImport()
        } catch {
            guard systemImportCandidate?.id == candidate.id else { return }
            systemImportError = (error as? SystemImportError ?? .unavailable).localizedDescription
        }
    }

    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    private func sync() {
        networks = repository?.configuration.networks ?? []
        accounts = repository?.configuration.accounts ?? []
        automaticReconnectFailures = repository?.configuration.automaticReconnectFailure?.count ?? 0
        automaticReconnectError = repository?.configuration.automaticReconnectFailure?.reason
        automaticReconnectNeedsCredentialReview = repository?.configuration.automaticReconnectFailure?.requiresCredentialReview ?? false
        validateAccountSelection()
    }
    private func validateAccountSelection() {
        if let interrupted = interruptedAccount,
           !interrupted.isValid(connectedSSID: interrupted.ssid, networks: networks) { interruptedAccount = nil }
        if let selection = accountSelection,
           !selection.isValid(connectedSSID: selection.ssid, networks: networks) { clearAccountSelection() }
    }
    private func show(_ error: Error) { notice = AppNotice(text: error.localizedDescription, isError: true) }
}

// Explicit UI demonstration only. Normal launches always use JSON + the real macOS Keychain.
final class MemoryStorage: ConfigurationStorage {
    var value = AccountConfiguration()
    func load() -> AccountConfiguration { value }
    func save(_ configuration: AccountConfiguration) { value = configuration }
}

final class MemoryVault: CredentialVault {
    var values: [UUID: String] = [:]
    func password(for accountID: UUID) -> String? { values[accountID] }
    func setPassword(_ password: String, for accountID: UUID) { values[accountID] = password }
    func deletePassword(for accountID: UUID) { values.removeValue(forKey: accountID) }
}
