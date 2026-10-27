import AppKit
import Foundation
import WiFiSwitchCore

struct AppNotice: Identifiable {
    let id = UUID()
    let text: String
    var isError = false
    var accountEditor: AccountEditor?
    var connection: SessionAccountSelection?
    var recoveringSSID: String?
    var isInformational = false
}

struct AccountEditor: Identifiable {
    let id = UUID()
    let account: WiFiAccount?
}

struct SystemImportCandidate: Identifiable {
    let id = UUID()
    let ssid: String
    var automatic = false
    var updatingAccount: WiFiAccount?
    var differenceConfirmed = false
    var linkingNetwork = false
    var isPasswordUpdate: Bool { updatingAccount != nil && differenceConfirmed }
    var isPasswordVerification: Bool { updatingAccount != nil && !linkingNetwork && !differenceConfirmed }
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
    @Published private(set) var connectionEvidence: ConnectionEvidence?
    private var awaitingSystemJoinAfterPowerOff = false
    private let systemReader: (any SystemConnectionReading)?
    private let credentialComparator: (any SystemCredentialComparing)?
    private let connectionVerificationGate: ConnectionCredentialVerificationGate?
    @Published private(set) var isVerifyingConnectionCredentials = false
    @Published private(set) var credentialAccessContext: CredentialAccessContext?
    private let credentialAccessWindow = CredentialAccessWindow()
    @Published private(set) var systemPasswordComparison: SystemCredentialComparison?
    private var passwordCheck: (identity: SystemConnectionIdentity, account: WiFiAccount, result: SystemCredentialComparison, date: Date)?
    private let passwordCheckDate: () -> Date
    private var comparisonEpoch = UUID()
    private var activeComparison: (identity: SystemConnectionIdentity, account: WiFiAccount,
                                   source: SystemCredentialSource?, epoch: UUID, token: UUID,
                                   task: Task<SystemCredentialComparison, Never>)?
    private var verifiedCredentialSource: (identity: SystemConnectionIdentity, accountID: UUID, source: SystemCredentialSource)?
    private var outdatedAccountIDs = Set<UUID>()
    // Equality is evidence for this connection only; an unreadable refresh is not a difference.
    private var verifiedConnection: (identity: SystemConnectionIdentity, account: WiFiAccount)?
    private var connectionEventGeneration = UUID()
    private let connectionEventDelay: Duration
    private var pendingImportRead: (candidateID: UUID, configuration: SystemConnectionConfiguration, date: Date)?
    private let internetChecker: (any InternetChecking)?
    @Published private(set) var internetStatus: InternetStatus = .checking
    private var internetTask: Task<Void, Never>?
    private var internetGeneration = UUID()
    private var internetCheckedAt: Date?
    private var addressWaitingSince: Date?
    private var dismissedImports: Set<String> = []
    private var systemIdentityUnresolved = false
    private var observedSystemIdentity: SystemConnectionIdentity?
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
    private let systemJoinVerificationGrace: TimeInterval
    private var systemJoinVerificationNotBefore: Date?
    private var automaticReconnectTask: Task<Void, Never>?
    private var automaticReconnectCycle = UUID()
    private var reconnectPromptArmed = false
    private var reconnectPromptDismissed = false
    private var isPresentingReconnectPrompt = false
    private let reconnectPromptDecision: ((WiFiAccount, SavedWiFi) async -> Bool)?
    private var monitoringTask: Task<Void, Never>?

    init(demoMode: Bool = false, wifi: (any WiFiServicing)? = nil, repository: AccountRepository? = nil,
         automaticReconnectEnabled: Bool? = nil, automaticReconnectDelay: Duration = .seconds(3),
         systemReader: (any SystemConnectionReading)? = nil,
         credentialComparator: (any SystemCredentialComparing)? = nil,
         passwordCheckDate: @escaping () -> Date = Date.init,
         internetChecker: (any InternetChecking)? = nil,
         connectionEventDelay: Duration? = nil,
         connectionVerificationGate: ConnectionCredentialVerificationGate? = nil,
         syncPreferenceDecision: ((WiFiAccount, SavedWiFi) -> Bool?)? = nil,
         reconnectPromptDecision: ((WiFiAccount, SavedWiFi) async -> Bool)? = nil,
         systemJoinVerificationGrace: TimeInterval = 3) {
        self.connectionVerificationGate = connectionVerificationGate ?? (demoMode ? nil : ConnectionCredentialVerificationGate())
        self.connectionEventDelay = connectionEventDelay ?? (demoMode ? .zero : .milliseconds(350))
        self.internetChecker = internetChecker ?? (demoMode ? nil : InternetConnectivity())
        self.passwordCheckDate = passwordCheckDate
        self.syncPreferenceDecision = syncPreferenceDecision
        self.reconnectPromptDecision = reconnectPromptDecision
        self.demoMode = demoMode
        self.systemReader = systemReader ?? (demoMode ? nil : SystemConnectionReader())
        self.credentialComparator = credentialComparator ?? (demoMode ? nil : SystemCredentialComparator())
        if !demoMode { dismissedImports = Set(UserDefaults.standard.stringArray(forKey: "dismissedSystemImports") ?? []) }
        self.automaticReconnectEnabled = automaticReconnectEnabled ?? !demoMode
        self.automaticReconnectDelay = automaticReconnectDelay
        self.systemJoinVerificationGrace = max(0, systemJoinVerificationGrace)
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
                let work = try self.repository!.saveAccount(networkID: id, label: "日常办公", username: "work@example.com", newPassword: "EXAMPLE-ONLY-NOT-A-REAL-PASSWORD")
                try self.repository!.saveAccount(networkID: id, label: "测试环境", username: "test@example.com", newPassword: "EXAMPLE-ONLY-NOT-A-REAL-PASSWORD")
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
        internetTask?.cancel()
        monitoringTask?.cancel()
        automaticReconnectTask?.cancel()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    var editBlockedReason: String? {
        if loadError != nil { return "账号列表读取失败，暂时无法保存。" }
        if isConfirmingConnection { return "请先选择是否同步系统首选账号。" }
        if isVerifyingConnectionCredentials { return "正在自动核对账户信息，请完成系统授权或取消。" }
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

    var menuNetworkStatus: MenuNetworkStatus {
        let status = MenuNetworkStatus.resolve(snapshot: snapshot, busy: isSwitching || isCheckingConnection || isVerifyingConnectionCredentials,
                 connectedAccountID: connectedAccountID, hasSelectedAccount: selectedAccount != nil)
        if snapshot.ssid != nil, snapshot.poweredOn, !isSwitching {
            if status == .waitingForAddress, let since = addressWaitingSince,
               passwordCheckDate().timeIntervalSince(since) >= 30 { return .addressUnavailable }
            if snapshot.hasUsableAddress, internetChecker != nil {
                if internetStatus == .unreachable { return .internetUnavailable }
                if internetStatus == .checking { return .checking }
            }
        }
        if (status == .registered || status == .accountNeedsReview), selectedAccount != nil, !hasLiveAppConnection {
            if credentialComparator != nil, systemPasswordComparison == nil { return .checking }
            if systemPasswordComparison == .different { return .passwordChanged }
            if systemPasswordComparison == .unavailable { return .passwordUnverified }
        }
        return status
    }

    var canAddMenuSystemConnection: Bool {
        return menuNetworkStatus.hasSystemConfigurationAction && canImportSystemConnection
    }

    var hasLiveEnterpriseConnection: Bool {
        hasLiveAppConnection && connectedNetwork?.authentication == .enterprise && selectedAccount != nil
    }

    var connectionAccountLabel: String {
        guard let account = selectedAccount else { return "未知账号" }
        return account.displayName
    }

    /// Read stored identity only for the explanation; never replace the requested session account.
    func refreshConnectionEvidence() async {
        guard hasLiveEnterpriseConnection, let original = connectionEvidence else { return }
        let revision = connectionRevision
        let identity = await systemReader?.identity(ssid: original.ssid)
        let latest = await wifi.snapshot()
        guard revision == connectionRevision, hasLiveEnterpriseConnection,
              connectionEvidence == original, latest.ssid == original.ssid,
              latest.poweredOn, latest.hasUsableAddress else { return }
        var updated = original
        if let identity, identity.ssid == original.ssid, identity.authentication == .enterprise {
            updated.savedUsername = identity.username
            updated.savedAccount = matchingSystemAccount(identity)?.displayName
        } else {
            updated.savedUsername = nil
            updated.savedAccount = nil
        }
        connectionEvidence = updated
    }

    func beginMenuSystemImport() {
        guard canAddMenuSystemConnection else { return }
        if menuNetworkStatus == .passwordChanged || menuNetworkStatus == .passwordUnverified, let account = selectedAccount {
            beginSystemImport(updating: account)
        } else { beginSystemImport() }
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
        if hasLiveEnterpriseConnection { return connectionEvidence?.detail ?? "已通过 WiFi Switch 使用所选账号完成连接。" }
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
        guard (!demoMode || allowsSwitching) && !isSwitching && !isScanning && !isSuspended && !isImporting && !isVerifyingConnectionCredentials else { return }
        // Only the latest refresh may publish a result. Sleep and explicit account actions
        // also invalidate in-flight reads so an older snapshot cannot erase new state.
        connectionRevision += 1
        let revision = connectionRevision
        let latest = await wifi.snapshot()
        guard !isSwitching && !isScanning && !isSuspended && !isImporting && revision == connectionRevision else { return }
        defer {
            if revision == connectionRevision {
                isCheckingConnection = false
                reconcileConnectionNotice()
                scheduleAutomaticReconnectIfNeeded()
                proposeSystemImport()
            }
        }
        missingSystemConfigurationSSID = nil
        observedSystemIdentity = nil
        let previousAccount = accountSelection ?? interruptedAccount ?? repository?.configuration.currentConnection
        // A system rejoin may still be completing its own authorization. Do not open
        // an interactive app credential check during the first few seconds after it joins.
        if automaticReconnectEnabled, reconnectPromptArmed, interruptedAccount != nil,
           latest.poweredOn, latest.ssid != nil, latest.hasUsableAddress {
            if systemJoinVerificationNotBefore == nil {
                systemJoinVerificationNotBefore = passwordCheckDate().addingTimeInterval(systemJoinVerificationGrace)
            }
            if automaticReconnectTask != nil { cancelAutomaticReconnect() }
        } else if latest.ssid == nil || !latest.poweredOn || !latest.hasUsableAddress {
            systemJoinVerificationNotBefore = nil
        }
        if latest.ssid != snapshot.ssid || !latest.poweredOn || !latest.hasUsableAddress { hasLiveAppConnection = false }
        if latest.ssid != snapshot.ssid || !latest.poweredOn || !latest.hasUsableAddress {
            systemPasswordComparison = nil
            passwordCheck = nil
            verifiedCredentialSource = nil
            resetConnectionChecks()
        }
        connectionVerificationGate?.observe(ssid: latest.poweredOn && latest.hasUsableAddress ? latest.ssid : nil)
        snapshot = latest
        if latest.poweredOn, latest.hasUsableAddress,
           let current = previousAccount, current.isValid(connectedSSID: latest.ssid, networks: networks) {
            reconnectPromptArmed = true
            reconnectPromptDismissed = false
        }
        if !latest.poweredOn {
            awaitingSystemJoinAfterPowerOff = true
            cancelAutomaticReconnect()
        } else if latest.ssid != nil, latest.hasUsableAddress {
            awaitingSystemJoinAfterPowerOff = false
        }
        if latest.ssid != nil, latest.poweredOn, !latest.hasUsableAddress {
            if addressWaitingSince == nil { addressWaitingSince = passwordCheckDate() }
        } else { addressWaitingSince = nil }
        refreshInternetStatus()
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
            observedSystemIdentity = identity?.ssid == ssid ? identity : nil
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
                    reconnectPromptArmed = true
                    reconnectPromptDismissed = false
                    interruptedAccount = nil
                    systemIdentityUnresolved = false
                    if systemImportCandidate?.automatic == true { cancelSystemImport() }
                    if let credentialComparator {
                        var result: SystemCredentialComparison
                        if let cached = passwordCheck, cached.identity == identity, cached.account == account,
                           passwordCheckDate().timeIntervalSince(cached.date) < 30 {
                            result = cached.result
                        } else {
                            let verified = verifiedCredentialSource
                            let source = verified?.identity == identity && verified?.accountID == account.id ? verified?.source : nil
                            result = await compareCredentialsOnce(credentialComparator, identity: identity, account: account, source: source)
                        }
                        guard revision == connectionRevision, !isSwitching, !isSuspended, !isImporting else { return }
                        if result == .unavailable, verifiedConnection?.identity == identity,
                           verifiedConnection?.account == account { result = .same }
                        if result == .unavailable, editor == nil, networkEditor == nil, deletion == nil,
                           (systemJoinVerificationNotBefore.map { passwordCheckDate() >= $0 } ?? true),
                           systemImportCandidate == nil,
                           connectionVerificationGate?.claim(identity: identity, account: account) == true {
                            result = await verifyConnectionCredentials(identity: identity, account: account, revision: revision)
                            connectionVerificationGate?.completed(result: result)
                        }
                        guard revision == connectionRevision, !isSwitching, !isSuspended, !isImporting,
                              accounts.first(where: { $0.id == account.id }) == account else { return }
                        let finalSnapshot = await wifi.snapshot()
                        guard revision == connectionRevision, !hasLiveAppConnection,
                              finalSnapshot.ssid == ssid, finalSnapshot.poweredOn, finalSnapshot.hasUsableAddress else { return }
                        snapshot = finalSnapshot
                        if !demoMode, systemPasswordComparison != result {
                            CredentialDiagnostics.record(.comparisonApplied, comparison: result)
                        }
                        if result == .same { verifiedConnection = (identity, account) }
                        if result == .different { verifiedConnection = nil }
                        systemPasswordComparison = result
                        // Preserve the original cache time; frequent polling must not extend it forever.
                        if passwordCheck?.identity != identity || passwordCheck?.account != account ||
                           passwordCheck.map({ passwordCheckDate().timeIntervalSince($0.date) >= 30 }) != false {
                            passwordCheck = (identity, account, result, passwordCheckDate())
                        }
                        if result == .different { outdatedAccountIDs.insert(account.id); cancelAutomaticReconnect() }
                        if result == .same { outdatedAccountIDs.remove(account.id) }
                    }
                } catch { show(error) }
            } else {
                accountSelection = nil
                systemPasswordComparison = nil
                passwordCheck = nil
                verifiedCredentialSource = nil
                verifiedConnection = nil
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

    private func readSystemConfiguration(ssid: String, accountName: String, username: String?, automatic: Bool,
                                         prepareAccess: @escaping @MainActor (SystemCredentialSource) async throws -> Void = { _ in }) async throws -> SystemConnectionConfiguration {
        guard let systemReader else { throw SystemImportError.unavailable }
        let context = CredentialAccessContext(ssid: ssid, accountName: accountName.isEmpty ? ssid : accountName, username: username)
        if !automatic { credentialAccessContext = context }
        defer { if !automatic { credentialAccessContext = nil } }
        let prompt = "核对账号“\(context.accountName)”的 Wi-Fi“\(ssid)”凭据。"
        return try await systemReader.configuration(ssid: ssid, authorizationPrompt: prompt, prepareAccess: { source in
            if !automatic {
                var updated = context
                updated.stage = .init(source: source)
                self.credentialAccessContext = updated
            }
            try await prepareAccess(source)
        })
    }

    private func verifyConnectionCredentials(identity: SystemConnectionIdentity, account: WiFiAccount,
                                          revision: Int) async -> SystemCredentialComparison {
        guard systemReader != nil, let repository else { return .unavailable }
        isVerifyingConnectionCredentials = true
        let context = CredentialAccessContext(ssid: identity.ssid, accountName: account.displayName, username: identity.username)
        credentialAccessContext = context
        defer {
            isVerifyingConnectionCredentials = false
            credentialAccessContext = nil
            credentialAccessWindow.dismiss()
        }
        func updateContext(_ stage: CredentialAccessContext.Stage) async {
            var updated = context
            updated.stage = stage
            credentialAccessContext = updated
            if !demoMode { await credentialAccessWindow.update(updated) }
        }
        var completedRead = false
        let generation = connectionEventGeneration
        defer {
            if completedRead && (generation != connectionEventGeneration || revision != connectionRevision) {
                connectionVerificationGate?.invalidatePendingRead()
            }
        }
        func stillCurrent() -> Bool {
            revision == connectionRevision && generation == connectionEventGeneration && !isSuspended && !isSwitching &&
                repository.configuration.accounts.first(where: { $0.id == account.id }) == account
        }
        func prepareSystemAccess(_ source: SystemCredentialSource) async throws {
            await updateContext(.init(source: source))
            guard stillCurrent() else { throw SystemImportError.connectionChanged }
        }
        do {
            if !demoMode { await credentialAccessWindow.present(context) }
            guard stillCurrent() else { throw SystemImportError.connectionChanged }
            if !demoMode { CredentialDiagnostics.record(.automaticVerificationStarted) }
            let configuration = try await readSystemConfiguration(ssid: identity.ssid, accountName: account.displayName, username: identity.username,
                                                                automatic: true, prepareAccess: prepareSystemAccess)
            completedRead = true
            guard stillCurrent(), configuration.identity == identity else { throw SystemImportError.connectionChanged }
            guard let password = configuration.password, !password.isEmpty,
                  identity.authentication != .unknown else { throw SystemImportError.missingCredentials }
            await updateContext(.appAccount)
            guard stillCurrent() else { throw SystemImportError.connectionChanged }
            let saved = try await repository.readPassword(for: account.id)
            guard stillCurrent() else { throw SystemImportError.connectionChanged }
            let different = password != saved
            if different {
                // A mismatch must remain stable across both system and saved reads.
                await updateContext(.systemWiFi)
                guard stillCurrent() else { throw SystemImportError.connectionChanged }
                let second = try await readSystemConfiguration(ssid: identity.ssid, accountName: account.displayName, username: identity.username,
                                                              automatic: true, prepareAccess: prepareSystemAccess)
                guard stillCurrent(), second.identity == identity, second.source == configuration.source,
                      second.password == password else {
                    throw SystemImportError.accountChanged
                }
                await updateContext(.appAccount)
                guard stillCurrent() else { throw SystemImportError.connectionChanged }
                let checkedSaved = try await repository.readPassword(for: account.id)
                guard stillCurrent(), checkedSaved == saved else {
                    throw SystemImportError.accountChanged
                }
            }
            let current = await wifi.snapshot()
            guard stillCurrent(), current.ssid == identity.ssid, current.poweredOn, current.hasUsableAddress else {
                throw SystemImportError.connectionChanged
            }
            if let source = configuration.source {
                verifiedCredentialSource = (identity, account.id, source)
            }
            let result: SystemCredentialComparison = different ? .different : .same
            if !demoMode { CredentialDiagnostics.record(.automaticVerificationCompleted, comparison: result, source: configuration.source) }
            return result // Read-only: a difference still requires the user's Update confirmation.
        } catch {
            let code: Int?
            if case let SystemImportError.keychain(_, value) = error { code = value }
            else if let failure = error as? KeychainFailure { code = Int(failure.status) }
            else { code = nil }
            if !demoMode { CredentialDiagnostics.record(.automaticVerificationFailed, comparison: .unavailable,
                                                        reason: .unreadable, errorCode: code) }
            if stillCurrent() {
                notice = AppNotice(text: "账号“\(account.displayName)” · Wi-Fi“\(identity.ssid)”自动核对未完成，可点击灰色状态重试。\(error.localizedDescription)", isError: true)
            }
            return .unavailable
        }
    }

    private func compareCredentialsOnce(_ comparator: any SystemCredentialComparing,
                                        identity: SystemConnectionIdentity, account: WiFiAccount,
                                        source: SystemCredentialSource?) async -> SystemCredentialComparison {
        let current: (identity: SystemConnectionIdentity, account: WiFiAccount, source: SystemCredentialSource?, epoch: UUID, token: UUID, task: Task<SystemCredentialComparison, Never>)
        if let active = activeComparison, active.identity == identity, active.account == account,
           active.source == source, active.epoch == comparisonEpoch {
            current = active
        } else {
            let token = UUID(), epoch = comparisonEpoch
            let task = Task { await comparator.compare(identity: identity, accountID: account.id, expectedSource: source) }
            current = (identity, account, source, epoch, token, task)
            activeComparison = current
        }
        let result = await current.task.value
        if activeComparison?.token == current.token { activeComparison = nil }
        return result
    }

    private func resetConnectionChecks() {
        comparisonEpoch = UUID()
        activeComparison = nil
        connectionEvidence = nil
        pendingImportRead = nil
        systemPasswordComparison = nil
        verifiedCredentialSource = nil
        verifiedConnection = nil
        internetGeneration = UUID()
        internetTask?.cancel()
        internetTask = nil
        internetCheckedAt = nil
        internetStatus = .checking
    }

    private func refreshInternetStatus() {
        guard let internetChecker, snapshot.available, snapshot.poweredOn, snapshot.ssid != nil,
              snapshot.hasUsableAddress, internetTask == nil else { return }
        if let checked = internetCheckedAt, passwordCheckDate().timeIntervalSince(checked) < 30 { return }
        let generation = internetGeneration
        let ssid = snapshot.ssid
        internetTask = Task { @MainActor [weak self] in
            let reachable = await internetChecker.isReachable()
            guard let self, !Task.isCancelled, generation == self.internetGeneration,
                  self.snapshot.ssid == ssid, self.snapshot.poweredOn, self.snapshot.hasUsableAddress else { return }
            self.internetStatus = reachable ? .reachable : .unreachable
            self.internetCheckedAt = self.passwordCheckDate()
            self.internetTask = nil
        }
    }

    func connectionDidChange() async {
        // CoreWLAN may emit SSID, link and power notifications for one transition.
        // Debounce them before reading so one transition does not start competing authorization requests.
        let generation = UUID()
        connectionEventGeneration = generation
        connectionRevision += 1
        pendingImportRead = nil
        guard !isSwitching else { return }
        do { try await Task.sleep(for: connectionEventDelay) } catch { return }
        guard generation == connectionEventGeneration else { return }
        // The explicit switch verifies its own result. Its notifications must not start
        // a competing credential read while association/synchronization is running.
        guard !isSwitching, !isImporting, !isVerifyingConnectionCredentials else { return }
        connectionVerificationGate?.connectionChanged()
        resetConnectionChecks()
        passwordCheck = nil
        hasLiveAppConnection = false
        await refresh()
    }

    func suspendConnectionForSleep() {
        connectionVerificationGate?.observe(ssid: nil)
        resetConnectionChecks()
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

    private func reconcileConnectionNotice() {
        guard let currentNotice = notice else { return }
        if let ssid = currentNotice.recoveringSSID {
            guard snapshot.ssid == ssid, snapshot.poweredOn, snapshot.hasUsableAddress else {
                notice = nil
                return
            }
            if systemPasswordComparison == .same, let selection = accountSelection,
               let account = accounts.first(where: { $0.id == selection.accountID }) {
                notice = AppNotice(text: "Wi-Fi 已恢复连接，当前识别账号：\(account.displayName)。", connection: selection)
            } else {
                notice = AppNotice(text: "Wi-Fi 已恢复连接：\(ssid)。账号信息尚未确认，请查看当前连接状态。", recoveringSSID: ssid, isInformational: true)
            }
        } else if let connection = currentNotice.connection {
            guard snapshot.poweredOn, snapshot.hasUsableAddress, snapshot.ssid == connection.ssid,
                  accountSelection?.accountID == connection.accountID,
                  accountSelection?.username == connection.username else {
                notice = nil
                return
            }
        }
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
        guard automaticReconnectEnabled, reconnectPromptArmed, !reconnectPromptDismissed, !isPresentingReconnectPrompt,
              !awaitingSystemJoinAfterPowerOff, !isSuspended, !isSwitching, !isScanning, !isImporting, !isConfirmingConnection, !systemIdentityUnresolved,
              !automaticReconnectStopped, snapshot.available, snapshot.poweredOn,
              snapshot.ssidIsReadable, demoMode || location.authorized,
              let selection = repository?.configuration.currentConnection,
              selection.isValid(connectedSSID: selection.ssid, networks: networks),
              (snapshot.ssid == nil || (snapshot.ssid == selection.ssid && !snapshot.hasUsableAddress)),
              let network = networks.first(where: { $0.id == selection.networkID }),
              let account = accounts.first(where: { $0.id == selection.accountID }),
              !outdatedAccountIDs.contains(account.id) else { return nil }
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
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            await self.refresh()
            guard !Task.isCancelled, self.automaticReconnectCycle == cycle,
                  let (selection, account, network) = self.automaticReconnectTarget else { return }
            // One prompt per interruption; confirmation never reuses stale network state.
            let eventGeneration = self.connectionEventGeneration
            self.reconnectPromptDismissed = true
            self.isPresentingReconnectPrompt = true
            let approved: Bool
            if let decision = self.reconnectPromptDecision {
                approved = await decision(account, network)
            } else if self.demoMode {
                approved = false
            } else {
                approved = ReconnectPrompt().run(ssid: network.ssid, account: account.displayName)
            }
            self.isPresentingReconnectPrompt = false
            guard approved, !Task.isCancelled, self.automaticReconnectCycle == cycle,
                  self.connectionEventGeneration == eventGeneration,
                  !self.isSuspended, !self.isSwitching, !self.awaitingSystemJoinAfterPowerOff else { return }
            let latest = await self.wifi.snapshot()
            guard !Task.isCancelled, self.automaticReconnectCycle == cycle,
                  self.connectionEventGeneration == eventGeneration, latest.available, latest.poweredOn, latest.ssidIsReadable,
                  (latest.ssid == nil || (latest.ssid == selection.ssid && !latest.hasUsableAddress)),
                  self.repository?.configuration.currentConnection == selection,
                  self.networks.contains(where: { $0.id == network.id && $0.accounts.contains(where: { $0.id == account.id && $0.username == account.username }) })
            else { return }
            self.snapshot = latest
            // Use the existing recovery path once, preserving the system default credentials.
            guard let attempt = self.connectAccount(account, on: network, reconnect: true, automatic: true) else { return }
            await attempt.value
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
            awaitingSystemJoinAfterPowerOff = false
            // Only an explicit account change invalidates the saved identity.
            do { try repository.clearRememberedConnection() }
            catch { show(error); return nil }
            cancelAutomaticReconnect()
            automaticReconnectFailures = 0
            automaticReconnectError = nil
            automaticReconnectNeedsCredentialReview = false
        }
        interruptedAccount = nil
        resetConnectionChecks()
        connectionRevision += 1
        accountSelection = nil
        isSwitching = true
        switchingAccountID = account.id
        switchingNetworkID = network.id
        phase = nil
        authenticationTakingLong = false
        notice = automatic ? AppNotice(text: "正在使用所选账号重新连接…") :
            (afterSaving ? AppNotice(text: "账号已保存，正在使用新凭据重新连接 \(network.ssid)…") : nil)
        return Task {
            var refreshRecoveredConnection = false
            var attemptedPassword: String?
            defer {
                waitHintTask?.cancel()
                waitHintTask = nil
                authenticationTakingLong = false
                isSwitching = false
                switchingAccountID = nil
                switchingNetworkID = nil
                phase = nil
                if refreshRecoveredConnection { Task { await self.refresh() } }
            }
            do {
                if !demoMode { CredentialDiagnostics.record(automatic ? .automaticReconnectStarted : .manualConnectionStarted) }
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
                var recoveryResult: WiFiReconnectResult = .associated
                if automatic {
                    recoveryResult = try await wifi.reconnectAccount(ssid: network.ssid, username: account.username, password: password, progress: progress)
                } else {
                    try await wifi.switchAccount(ssid: network.ssid, username: account.username, password: password, synchronizeSystemCredentials: synchronize, progress: progress)
                }
                snapshot = await wifi.snapshot()
                refreshInternetStatus()
                let selection = automatic ? (remembered ?? SessionAccountSelection(network: network, account: account, source: .successfulSwitch)) :
                    SessionAccountSelection(network: network, account: account, source: .successfulSwitch)
                systemIdentityUnresolved = false
                guard snapshot.available && snapshot.poweredOn,
                      selection.isValid(connectedSSID: snapshot.ssid, networks: networks),
                      snapshot.hasUsableAddress
                else { throw WiFiError.verificationTimeout }
                if automatic, recoveryResult == .systemRecovered {
                    if !demoMode { CredentialDiagnostics.record(.systemRecoveredInstead) }
                    // No application authentication occurred. Observe the system result instead.
                    accountSelection = nil
                    hasLiveAppConnection = false
                    systemIdentityUnresolved = true
                    try repository.clearAutomaticReconnectFailure()
                    sync()
                    notice = AppNotice(text: "Wi-Fi 已恢复连接：\(network.ssid)。正在确认当前账号。", recoveringSSID: network.ssid, isInformational: true)
                    refreshRecoveredConnection = true
                    return
                }
                accountSelection = selection
                hasLiveAppConnection = true
                reconnectPromptArmed = true
                reconnectPromptDismissed = false
                if network.authentication == .enterprise {
                    connectionEvidence = ConnectionEvidence(ssid: network.ssid, requestedAccount: account.displayName,
                                                           requestedUsername: account.username, automatic: automatic)
                }
                systemPasswordComparison = nil
                passwordCheck = nil
                verifiedCredentialSource = nil
                outdatedAccountIDs.remove(account.id)
                do {
                    try repository.rememberConnection(selection, connectedAt: automatic ? nil : Date())
                    sync()
                    notice = AppNotice(text: "\(automatic ? "重新连接成功" : (afterSaving ? "账号已保存并重新连接成功" : "连接成功"))，当前账号：\(account.displayName)。" +
                        (automatic ? "" : (synchronize ? "已同步此 Wi-Fi 的系统账号凭据。" : "已保留原有系统账号凭据，本次使用所选账号。")), connection: selection)
                    if network.authentication == .enterprise {
                        if !demoMode { CredentialDiagnostics.record(.enterpriseAssociationVerified) }
                        await refreshConnectionEvidence()
                    }
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

    private func existingSystemAccounts(_ identity: SystemConnectionIdentity) -> [WiFiAccount] {
        if let linked = matchingSystemAccount(identity) { return [linked] }
        guard identity.authentication == .enterprise, let username = identity.username, !username.isEmpty else { return [] }
        return accounts.filter { $0.username == username }
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

    func beginSystemImport(automatic: Bool = false, updating account: WiFiAccount? = nil) {
        pendingImportRead = nil
        guard canImportSystemConnection, let ssid = snapshot.ssid else { return }
        dismissedImports.insert(ssid)
        if !demoMode { UserDefaults.standard.set(Array(dismissedImports), forKey: "dismissedSystemImports") }
        var target = account
        var linkingNetwork = false
        if target == nil, let identity = observedSystemIdentity, identity.ssid == ssid,
           matchingSystemAccount(identity) == nil {
            let existing = existingSystemAccounts(identity)
            if existing.count == 1 { target = existing[0]; linkingNetwork = true }
        }
        systemImportCandidate = SystemImportCandidate(ssid: ssid, automatic: automatic,
            updatingAccount: target, differenceConfirmed: account != nil && systemPasswordComparison == .different,
            linkingNetwork: linkingNetwork)
        systemImportError = nil
        if !demoMode || CommandLine.arguments.contains("--demo-import") { importWindow.present(model: self) }
    }

    func cancelSystemImport() {
        pendingImportRead = nil
        systemImportCandidate = nil
        systemImportError = nil
        if !demoMode || CommandLine.arguments.contains("--demo-import") { importWindow.dismiss() }
        // Keep isImporting until a pending Keychain call returns. Its result is discarded.
    }

    func confirmSystemImport(label: String) async {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isImporting, let candidate = systemImportCandidate,
              candidate.updatingAccount != nil || !label.isEmpty,
              systemReader != nil, let repository, canImportSystemConnection else { return }
        let importConnectionGeneration = connectionEventGeneration
        connectionRevision += 1 // A previous silent comparison must not publish over this user action.
        isImporting = true
        systemImportError = nil
        cancelAutomaticReconnect()
        defer { isImporting = false }
        do {
            let before = await wifi.snapshot()
            guard before.ssid == candidate.ssid, before.poweredOn, before.hasUsableAddress,
                  systemImportCandidate?.id == candidate.id else { throw SystemImportError.connectionChanged }
            let configuration: SystemConnectionConfiguration
            if let pending = pendingImportRead, pending.candidateID == candidate.id,
               passwordCheckDate().timeIntervalSince(pending.date) < 30 {
                configuration = pending.configuration
            } else {
                do {
                    configuration = try await readSystemConfiguration(ssid: candidate.ssid, accountName: candidate.updatingAccount?.displayName ?? label, username: candidate.updatingAccount?.username, automatic: false)
                } catch {
                    let code: Int?
                    if case let SystemImportError.keychain(_, value) = error { code = value }
                    else { code = nil }
                    if !demoMode {
                        CredentialDiagnostics.record(candidate.isPasswordVerification ? .verificationReadFailed : .importReadFailed,
                            comparison: .unavailable, reason: .unreadable, errorCode: code)
                    }
                    throw error
                }
            }
            pendingImportRead = nil
            let after = await wifi.snapshot()
            guard importConnectionGeneration == connectionEventGeneration,
                  systemImportCandidate?.id == candidate.id, after.ssid == candidate.ssid,
                  after.poweredOn, after.hasUsableAddress, configuration.identity.ssid == candidate.ssid else { throw SystemImportError.connectionChanged }
            let identity = configuration.identity
            if !demoMode { CredentialDiagnostics.record(.importRead, source: configuration.source) }
            guard identity.authentication != .unknown,
                  !identity.authentication.requiresUsername || identity.username?.isEmpty == false,
                  !identity.authentication.requiresSecret || configuration.password?.isEmpty == false else { throw SystemImportError.unavailable }
            if networks.contains(where: { $0.ssid == identity.ssid && $0.authentication != identity.authentication }) {
                throw SystemImportError.ambiguous
            }
            let existing = existingSystemAccounts(identity)
            guard existing.count <= 1 else { throw SystemImportError.ambiguous }
            let id: UUID
            var alreadyVerifiedAccountID: UUID?
            if let target = candidate.updatingAccount {
                guard repository.configuration.accounts.first(where: { $0.id == target.id }) == target,
                      existing.first?.id == target.id else { throw SystemImportError.accountChanged }
                if !candidate.differenceConfirmed {
                    let saved = try repository.password(for: target.id)
                    if saved == (configuration.password ?? "") {
                        alreadyVerifiedAccountID = target.id
                    } else {
                        // An unavailable background read is not evidence of a different password.
                        // Verify first, then ask before writing if authorization reveals a difference.
                        systemImportCandidate = SystemImportCandidate(ssid: candidate.ssid, updatingAccount: target,
                            differenceConfirmed: true, linkingNetwork: candidate.linkingNetwork)
                        pendingImportRead = (systemImportCandidate!.id, configuration, passwordCheckDate())
                        systemPasswordComparison = .different
                        passwordCheck = (identity, target, .different, passwordCheckDate())
                        outdatedAccountIDs.insert(target.id)
                        return
                    }
                }
                let ssids = candidate.linkingNetwork ?
                    networks.filter { target.networkIDs.contains($0.id) }.map(\.ssid) + [identity.ssid] : nil
                if candidate.isPasswordVerification {
                    id = target.id // Already equal: do not rewrite credentials to "repair" a read failure.
                } else {
                    do {
                        id = try repository.saveAccount(accountID: target.id, label: target.label, username: target.username,
                            newPassword: candidate.isPasswordUpdate ? configuration.password : nil,
                            networkSSIDs: ssids, networkAuthentications: [identity.ssid: identity.authentication])
                    } catch { throw SystemImportError.storage }
                }
            } else if let target = existing.first {
                let different = try repository.password(for: target.id) != (configuration.password ?? "")
                let linking = matchingSystemAccount(identity) == nil
                if different || linking {
                    // Once authorization reveals an existing account, show its name before changing it.
                    systemImportCandidate = SystemImportCandidate(ssid: candidate.ssid, updatingAccount: target,
                        differenceConfirmed: different, linkingNetwork: linking)
                    pendingImportRead = (systemImportCandidate!.id, configuration, passwordCheckDate())
                    if different { systemPasswordComparison = .different; outdatedAccountIDs.insert(target.id) }
                    return
                }
                id = target.id
                alreadyVerifiedAccountID = target.id
            } else {
                guard candidate.updatingAccount == nil else { throw SystemImportError.accountChanged }
                if identity.authentication != .enterprise, connectedNetwork?.accounts.isEmpty == false { throw SystemImportError.ambiguous }
                do {
                    id = try repository.saveAccount(label: label, username: identity.username ?? "", newPassword: configuration.password,
                        networkSSIDs: [identity.ssid], networkAuthentications: [identity.ssid: identity.authentication])
                } catch { throw SystemImportError.storage }
            }
            sync() // A committed account must remain visible even if read-back is denied.
            // A write still requires a fresh read-back. A read-only equality check in
            // this uninterrupted operation already verified the same stored value.
            do {
                if alreadyVerifiedAccountID != id,
                   try repository.password(for: id) != (configuration.password ?? "") {
                    throw SystemImportError.savedPasswordUnverified
                }
            } catch {
                if !demoMode { CredentialDiagnostics.record(.savedPasswordVerificationFailed, source: configuration.source) }
                throw SystemImportError.savedPasswordUnverified
            }
            if !demoMode { CredentialDiagnostics.record(.savedPasswordVerified, source: configuration.source) }
            verifiedCredentialSource = configuration.source.map { (identity, id, $0) }
            snapshot = after
            sync()
            guard let network = connectedNetwork, let account = accounts.first(where: { $0.id == id }) else { throw SystemImportError.storage }
            let selection = SessionAccountSelection(network: network, account: account, source: .systemSavedCredentials)
            systemPasswordComparison = .same
            passwordCheck = (identity, account, .same, passwordCheckDate())
            verifiedConnection = (identity, account)
            refreshInternetStatus()
            outdatedAccountIDs.remove(id)
            do {
                try repository.rememberConnection(selection)
                sync()
                accountSelection = selection
                interruptedAccount = nil
                systemIdentityUnresolved = false
                notice = AppNotice(text: candidate.updatingAccount == nil ?
                    "已保存系统 Wi-Fi 配置，并根据系统保存的信息更新账号标记；没有重新连接网络。" :
                    (candidate.isPasswordVerification ? "已核对，系统 Wi-Fi 密码与本应用一致，无需更新。" : candidate.linkingNetwork ? "已将 Wi-Fi 添加到已有账号；没有重新连接网络。" :
                     "已更新 WiFi Switch 中的账号密码，保留原有名称和 Wi-Fi 关联；没有重新连接网络。"))
            } catch {
                notice = AppNotice(text: "配置已保存，但连接标记未能保存。请检查配置文件权限。", isError: true)
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
        // Refreshing account metadata must not mutate Keychain items. Even a label
        // update can require a new application's authorization after an upgrade.
        // New/changed passwords receive their label in the explicit save operation.
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
