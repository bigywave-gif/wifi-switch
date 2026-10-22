namespace WiFiSwitch.Core;

// Used only from the UI synchronization context. Tests exercise the same state transitions.
public sealed class Controller(Repository repository, IWiFiService wifi, TimeProvider? clock = null,
    ConnectionDiagnostics? diagnostics = null)
{
    private readonly TimeProvider clock = clock ?? TimeProvider.System;
    public Configuration Configuration => repository.Configuration;
    public Snapshot State { get; private set; } = new(Guid.Empty, false, false, null, null, false);
    public Selection? Connecting { get; private set; }
    public bool Claiming { get; private set; }
    public bool Busy => Connecting is not null || Claiming;
    public bool IsConnecting(Guid accountId, string ssid)
        => Connecting is { } target && target.AccountId == accountId && target.Ssid == ssid;
    public bool Suspended { get; private set; }
    public string? Notice { get; private set; } = repository.Configuration.Failure is { } initial
        ? (initial.CredentialsRejected ? "认证失败，自动重试已停止，请修改账号。" : $"上次连接异常：{initial.Message}") : null;
    public bool NoticeIsError { get; private set; } = repository.Configuration.Failure is not null;
    public Guid? EditSuggested { get; private set; } = repository.Configuration.Failure is { CredentialsRejected: true } failure
        ? failure.Selection.AccountId : null;
    private Selection? connectionNoticeSelection = repository.Configuration.Failure?.Selection;
    private DateTimeOffset? retryAt;
    private long revision;
    public event Action? Changed;
    public Selection? Active => Configuration.Current is { } c && Rules.Matches(c, State) && State.HasAddress && !Busy &&
        Configuration.Failure is null ? c : null;
    public bool RetryStopped => Configuration.Failure is { } f && (f.CredentialsRejected || f.Count >= 3);

    public IReadOnlyList<Account> OrderedAccounts => Configuration.Accounts.OrderByDescending(a => a.Id == Active?.AccountId).ToList();
    public void DismissNotice() { Notice = null; NoticeIsError = false; EditSuggested = null; connectionNoticeSelection = null; Changed?.Invoke(); }
    public void SetProblem(string message) => SetProblem(message, null);
    public void SetProblem(Exception error) => SetProblem(error.Message, (error as ConnectionException)?.RecoverySelection);
    private void SetProblem(string message, Selection? recoverySelection)
    { Notice = message; NoticeIsError = true; connectionNoticeSelection = recoverySelection; Changed?.Invoke(); }
    public void Suspend() { Suspended = true; revision++; retryAt = null; }
    public void Resume() { Suspended = false; retryAt = null; }

    public async Task CleanupLegacyProfilesAsync()
    {
        try
        {
            var warning = await wifi.CleanupLegacyProfilesAsync();
            if (warning is not null && !Busy && Notice is null)
            { Notice = warning; NoticeIsError = false; Changed?.Invoke(); }
        }
        catch { /* Unavailable Wi-Fi must not prevent account management. */ }
    }

    public async Task RefreshAsync(CancellationToken token = default)
    {
        if (Busy || Suspended) return;
        var stamp = ++revision;
        var state = await wifi.SnapshotAsync(Configuration.PreferredInterface ?? Configuration.Current?.InterfaceId, token);
        if (stamp != revision || Busy || Suspended) return;
        State = state;
        // Never infer an account solely from SSID or overwrite the durable user selection.
        var saved = Configuration.Current;
        if (saved is null || !state.Available || !state.PoweredOn || !state.Readable ||
            state.InterfaceId != saved.InterfaceId ||
            (state.Ssid is not null && !Rules.Matches(saved, state)))
        { retryAt = null; Changed?.Invoke(); return; }
        if (Rules.Matches(saved, state) && state.HasAddress)
        {
            // Windows restored the saved account on its own; the retry stop must
            // not keep a healthy, recognized connection reported as failed.
            if (Configuration.Failure is not null)
            {
                repository.Commit(Configuration with { Failure = null });
                EditSuggested = null;
            }
            // Claim verification can fail without a persisted connection failure.
            // Clear only a status notice for this exact selection; preserve other errors.
            if (connectionNoticeSelection == saved)
            { Notice = null; NoticeIsError = false; EditSuggested = null; connectionNoticeSelection = null; }
            retryAt = null; Changed?.Invoke(); return;
        }
        if (RetryStopped) { retryAt = null; Changed?.Invoke(); return; }
        retryAt ??= clock.GetUtcNow().AddSeconds(10);
        Changed?.Invoke();
        if (clock.GetUtcNow() >= retryAt)
        {
            var account = Configuration.Accounts.Single(a => a.Id == saved.AccountId);
            var network = account.Networks.Single(n => n.Ssid == saved.Ssid);
            await ConnectAsync(account.Id, network.Ssid, true, token);
        }
    }

    // The system is connected to the remembered network with an address, but the
    // account marker does not match (for example the connection was made from the
    // Windows Wi-Fi menu, or the marker was lost). Adopting it is an explicit user
    // decision: SSID alone never identifies an account.
    public bool CanClaim => !Busy && Configuration.Current is { } saved &&
        State.Available && State.PoweredOn && State.Readable && State.HasAddress &&
        State.InterfaceId == saved.InterfaceId && State.Ssid == saved.Ssid &&
        State.ProfileName == saved.ProfileName && !Rules.Matches(saved, State);

    public async Task ClaimCurrentAsync(CancellationToken token = default)
    {
        if (Busy || Suspended) return;
        var saved = Configuration.Current;
        if (!CanClaim || saved is null)
            throw new ConnectionException("当前状态不能认领：请确认系统已连接记录中的 Wi-Fi 并取得 IP 地址。");
        Claiming = true; var stamp = ++revision; retryAt = null;
        Notice = "正在确认当前账号…"; NoticeIsError = false; EditSuggested = null; connectionNoticeSelection = null;
        Changed?.Invoke();
        try
        {
            token.ThrowIfCancellationRequested();
            if (!await wifi.ClaimConnectionAsync(saved.InterfaceId, saved.ProfileName, saved.AccountId))
                throw new ConnectionException(
                    "无法写入账号识别标记。若该网络配置属于其他登录会话（例如以管理员身份运行），请从开始菜单正常启动本应用后重试。");
            // Marker writes may precede the connection/IP snapshot becoming current.
            // Wait briefly, then let normal polling reconcile this exact selection.
            var verified = await ConnectionVerification.WaitAsync(saved, async () =>
            {
                var state = await wifi.SnapshotAsync(saved.InterfaceId, token);
                if (stamp != revision || Suspended) throw new OperationCanceledException();
                State = state;
                return State;
            }, TimeSpan.FromSeconds(5), TimeSpan.FromMilliseconds(250), token);
            if (!verified)
                throw new ConnectionException("账号标记已写入，暂未确认当前连接；系统恢复后此提示会自动清除。",
                    diagnosticCode: "claim_state_unconfirmed", recoverySelection: saved);
            repository.Remember(saved, false);
            Notice = $"已认领当前连接：{saved.Ssid}";
            NoticeIsError = false; EditSuggested = null; connectionNoticeSelection = null;
        }
        finally { Claiming = false; Changed?.Invoke(); }
    }

    public async Task ConnectAsync(Guid accountId, string ssid, bool automatic = false, CancellationToken token = default)
    {
        if (Busy || Suspended) return;
        var account = Configuration.Accounts.Single(a => a.Id == accountId);
        var network = account.Networks.Single(n => n.Ssid == ssid);
        var remembered = Configuration.Current;
        var adapter = Configuration.PreferredInterface ?? remembered?.InterfaceId ?? State.InterfaceId;
        if (adapter == Guid.Empty) throw new ConnectionException("请先选择可用的 Wi-Fi 网卡。");
        if (automatic && (remembered?.AccountId != accountId || remembered.Ssid != ssid || RetryStopped)) return;
        Connecting = new(account.Id, ssid, adapter, Rules.ProfileName(account.Id, ssid));
        revision++; EditSuggested = null; NoticeIsError = false; connectionNoticeSelection = null;
        Notice = automatic ? $"网络异常，正在自动重连（{(Configuration.Failure?.Count ?? 0) + 1}/3）…" : "正在连接…";
        Changed?.Invoke();
        string? password = null;
        bool success = false;
        diagnostics?.Begin(automatic, network.Authentication);
        try
        {
            diagnostics?.Stage("保存连接意图");
            if (!automatic) repository.ClearCurrent();
            diagnostics?.Stage("读取已保存凭据");
            password = network.Authentication == Authentication.Open ? "" : repository.Password(account);
            diagnostics?.Write($"credentials retrieved passwordPresent={!string.IsNullOrEmpty(password)} " +
                $"usernamePresent={!string.IsNullOrWhiteSpace(account.Username)} domainQualified={account.Username.Contains('\\')} upn={account.Username.Contains('@')}");
            await wifi.ConnectAsync(adapter, account, network, password, automatic, message => {
                Notice = message; Changed?.Invoke();
            }, token);
            diagnostics?.Stage("最终连接验证");
            State = await wifi.SnapshotAsync(adapter, token);
            var selection = new Selection(account.Id, ssid, adapter, Rules.ProfileName(account.Id, ssid));
            diagnostics?.Write($"final available={State.Available} poweredOn={State.PoweredOn} readable={State.Readable} " +
                $"matches={Rules.Matches(selection, State)} hasIP={State.HasAddress}");
            if (!Rules.Matches(selection, State) || !State.HasAddress)
                throw new ConnectionException("未确认所选账号的 Wi-Fi 配置已连接并取得 IP 地址。");
            diagnostics?.Stage("保存当前账号状态");
            repository.Remember(selection, !automatic);
            Notice = $"连接成功：{account.DisplayName} · {ssid}";
            NoticeIsError = false; EditSuggested = null; connectionNoticeSelection = null;
            if (wifi.ConnectionWarning is { } warning) Notice += "\n" + warning;
            retryAt = null;
            success = true;
        }
        catch (Exception error)
        {
            diagnostics?.Failure(error);
            // A failed target attempt may have restored the original system profile.
            // Refresh the visible network without marking the failed target successful.
            try { State = await wifi.SnapshotAsync(adapter, token); }
            catch { /* Retain the original failure if status cannot be read. */ }
            var message = error is OperationCanceledException ? "连接已取消。" : error.Message;
            if (!string.IsNullOrEmpty(password)) message = message.Replace(password, "••••••", StringComparison.Ordinal);
            NoticeIsError = true;
            var rejected = error is ConnectionException { CredentialsRejected: true };
            // Preserve the attempted account on authentication failure so its row can show red,
            // but a failed manual switch must never restore the old account as current.
            var failedSelection = automatic ? remembered! :
                new Selection(account.Id, ssid, adapter, Rules.ProfileName(account.Id, ssid));
            var count = automatic ? Math.Min(3, (Configuration.Failure?.Count ?? 0) + 1) : 3;
            try
            {
                repository.Commit(Configuration with { Current = failedSelection,
                    Failure = new(failedSelection, count, message, rejected) });
            }
            catch (Exception saveError) {
                diagnostics?.Write("failure-state persistence failed"); diagnostics?.Failure(saveError);
                message += " 无法保存失败状态：" + saveError.Message; Suspended = true;
            }
            Notice = rejected ? "认证失败，已停止重试。请修改用户名或密码；也请核对证书与网络权限。\n" + message :
                (automatic ? $"自动重连失败（{count}/3）：{message}" : $"连接失败：{message}");
            connectionNoticeSelection = failedSelection;
            if (rejected) EditSuggested = account.Id;
            retryAt = clock.GetUtcNow().AddSeconds(10);
        }
        finally { diagnostics?.End(success); Connecting = null; Changed?.Invoke(); }
    }

    public async Task SaveAccountAsync(Account account, string? newPassword)
    {
        if (Busy) throw new InvalidOperationException("正在连接，请稍后保存。");
        var before = Configuration.Current;
        var credentialsChanged = repository.SaveAccount(account, newPassword);
        revision++;
        Notice = "账号已保存。"; NoticeIsError = false; EditSuggested = null; connectionNoticeSelection = null;
        Changed?.Invoke();
        if (credentialsChanged && before?.AccountId == account.Id && account.Networks.Any(n => n.Ssid == before.Ssid) &&
            State.Available && State.PoweredOn && State.Readable && State.InterfaceId == before.InterfaceId &&
            (State.Ssid is null || Rules.Matches(before, State)))
            await ConnectAsync(account.Id, before.Ssid);
    }

    public void RemoveNetwork(Guid id, string ssid)
    {
        if (Busy) return;
        repository.RemoveNetwork(id, ssid); revision++; Changed?.Invoke();
    }
    public void DeleteAccount(Guid id)
    {
        if (Busy) return;
        repository.DeleteAccount(id); revision++; Changed?.Invoke();
    }
    public void SelectAdapter(Guid id)
    {
        if (Busy) return;
        repository.Commit(Configuration with { PreferredInterface = id });
        revision++; retryAt = null;
    }
    public string ReadPassword(Guid id) => repository.Password(Configuration.Accounts.Single(a => a.Id == id));
    public Task<IReadOnlyList<Adapter>> AdaptersAsync() => wifi.AdaptersAsync();
    public Task<IReadOnlyList<NearbyNetwork>> ScanAsync(CancellationToken token = default)
    {
        var adapter = Configuration.PreferredInterface ?? State.InterfaceId;
        if (adapter == Guid.Empty) throw new ConnectionException("未找到可用的 Wi-Fi 网卡。");
        return wifi.ScanAsync(adapter, token);
    }
}
