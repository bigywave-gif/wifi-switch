using System.ComponentModel;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;
using WiFiSwitch.Core;

namespace WiFiSwitch.Windows;

internal sealed class NativeWiFi : IWiFiService
{
    private readonly IntPtr handle;
    private readonly NotificationCallback callback;
    private readonly SemaphoreSlim operation = new(1);
    private readonly object gate = new();
    private TaskCompletionSource<uint>? scanCompletion;
    private ConnectionAttempt? connectionAttempt;
    private Guid pendingAdapter;
    private string? pendingProfile;
    private bool disposed;
    private readonly ConnectionDiagnostics? diagnostics;
    private readonly uint diagnosticRegistrationResult;
    private readonly uint? onexFallbackResult;
    private readonly uint notificationSources = 28;
    public string? ConnectionWarning { get; private set; }

    public NativeWiFi(ConnectionDiagnostics? diagnostics = null)
    {
        this.diagnostics = diagnostics;
        Check(WlanOpenHandle(2, IntPtr.Zero, out _, out handle), "打开 Wi-Fi 服务");
        callback = OnNotification;
        try
        {
            // Extra diagnostics may require location consent on newer Windows.
            // Preserve basic connection support if those notifications are denied.
            diagnosticRegistrationResult = WlanRegisterNotification(handle, 8 | 16 | 4, false, callback, IntPtr.Zero, IntPtr.Zero, out _);
            if (diagnosticRegistrationResult != 0)
            {
                notificationSources = 8 | 4;
                onexFallbackResult = WlanRegisterNotification(handle, notificationSources, false, callback, IntPtr.Zero, IntPtr.Zero, out _);
                if (onexFallbackResult != 0)
                {
                    notificationSources = 8;
                    Check(WlanRegisterNotification(handle, 8, false, callback, IntPtr.Zero, IntPtr.Zero, out _), "监听 Wi-Fi 连接");
                }
            }
        }
        catch { WlanCloseHandle(handle, IntPtr.Zero); throw; }
    }

    private void Check(uint code, string action, bool locationSensitive = false)
    {
        Trace($"API action={action} code={code} hex=0x{code:X}");
        if (code == 0) return;
        Trace("API errorText=" + new Win32Exception(unchecked((int)code)).Message);
        if (code == 5) throw new ConnectionException(locationSensitive
            ? $"{action}被拒绝（错误 5）。请检查 Windows 设置中的位置访问权限及公司设备策略。Windows 将附近 Wi-Fi 信息纳入位置隐私保护，本应用不采集地理坐标。"
            : $"{action}被拒绝（错误 5）。请检查当前用户的 WLAN 操作权限及公司设备策略；此错误不能直接判断为缺少位置权限。");
        if (code == 1062) throw new ConnectionException("WLAN AutoConfig 服务未运行，请在 Windows 服务中启动它。");
        throw new ConnectionException($"{action}失败：{new Win32Exception((int)code).Message}（{code}）。", code is 86 or 1326);
    }

    public Task<IReadOnlyList<Adapter>> AdaptersAsync() => Task.Run<IReadOnlyList<Adapter>>(() =>
        Interfaces().Select(i => new Adapter(i.Id, i.Description)).ToList());

    private List<InterfaceInfo> Interfaces()
    {
        Check(WlanEnumInterfaces(handle, IntPtr.Zero, out var pointer), "读取 Wi-Fi 网卡");
        try { return ReadList<InterfaceInfo>(pointer); }
        finally { WlanFreeMemory(pointer); }
    }

    private static List<T> ReadList<T>(IntPtr pointer) where T : struct
    {
        var count = Marshal.ReadInt32(pointer);
        if (count < 0 || count > 10000) throw new InvalidDataException("Windows 返回了无效的列表长度。");
        return Enumerable.Range(0, count).Select(i => Marshal.PtrToStructure<T>(IntPtr.Add(pointer, 8 + i * Marshal.SizeOf<T>()))).ToList();
    }

    public Task<Snapshot> SnapshotAsync(Guid? adapter, CancellationToken token = default)
        => Task.Run(() => Snapshot(adapter), token);

    private Snapshot Snapshot(Guid? requested)
    {
        try
        {
            var list = Interfaces();
            var info = requested.HasValue ? list.FirstOrDefault(i => i.Id == requested) :
                list.FirstOrDefault(i => i.State == 1);
            if (info.Id == Guid.Empty && !requested.HasValue) info = list.FirstOrDefault();
            if (info.Id == Guid.Empty) return new(requested ?? Guid.Empty, false, false, null, null, false, true, "没有可用的 Wi-Fi 网卡。");
            var id = info.Id;
            bool powered = true;
            var radioResult = WlanQueryInterface(handle, ref id, 4, IntPtr.Zero, out var radioSize, out var radio, out _);
            if (radioResult == 0)
            {
                try
                {
                    int count = Marshal.ReadInt32(radio);
                    powered = count > 0 && count <= 64 && radioSize >= 4 + 12 * count &&
                        Enumerable.Range(0, count).Any(i => Marshal.ReadInt32(radio, 8 + 12 * i) == 1 &&
                            Marshal.ReadInt32(radio, 12 + 12 * i) == 1);
                }
                finally { WlanFreeMemory(radio); }
            }
            else if (radioResult == 5) return new(id, true, true, null, null, false, false, "读取网卡开关状态被拒绝，请检查 WLAN 操作权限或设备策略。");
            else powered = false; // Do not reconnect when radio state is unknown.
            var result = WlanQueryInterface(handle, ref id, 7, IntPtr.Zero, out _, out var data, out _);
            if (result == 5023) return new(id, true, powered, null, null, false);
            if (result == 5) return new(id, true, powered, null, null, false, false, "读取当前 Wi-Fi 被拒绝，请检查 Windows 位置访问权限或设备策略。");
            Check(result, "读取当前连接");
            try
            {
                var connection = Marshal.PtrToStructure<ConnectionAttributes>(data);
                if (connection.State != 1) return new(id, true, powered, null, null, false);
                var nic = NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(n => Guid.TryParse(n.Id, out var guid) && guid == id);
                var usable = nic?.GetIPProperties().UnicastAddresses.Any(a => UsableAddress(a.Address)) == true;
                return new(id, true, powered, Decode(connection.Association.Ssid), connection.Profile, usable,
                    AccountId: ReadAccountMarker(id, connection.Profile));
            }
            finally { WlanFreeMemory(data); }
        }
        catch (ConnectionException ex) { return new(requested ?? Guid.Empty, false, false, null, null, false, false, ex.Message); }
    }

    private static bool UsableAddress(IPAddress address)
    {
        if (IPAddress.IsLoopback(address) || address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any)) return false;
        if (address.AddressFamily == AddressFamily.InterNetworkV6) return !address.IsIPv6LinkLocal && !address.IsIPv6Multicast;
        var bytes = address.GetAddressBytes();
        return address.AddressFamily == AddressFamily.InterNetwork && !(bytes[0] == 169 && bytes[1] == 254);
    }

    public async Task<IReadOnlyList<NearbyNetwork>> ScanAsync(Guid adapter, CancellationToken token = default)
    {
        await operation.WaitAsync(token);
        try { return await ScanInternal(adapter, token); }
        finally { operation.Release(); }
    }

    private async Task<IReadOnlyList<NearbyNetwork>> ScanInternal(Guid adapter, CancellationToken token)
    {
        var completion = new TaskCompletionSource<uint>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (gate) { pendingAdapter = adapter; scanCompletion = completion; }
        try
        {
            Check(WlanScan(handle, ref adapter, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero), "扫描附近 Wi-Fi", locationSensitive: true);
            var reason = await completion.Task.WaitAsync(TimeSpan.FromSeconds(15), token);
            if (reason != 0) throw ReasonException(reason);
            return Networks(adapter);
        }
        catch (TimeoutException) { throw new ConnectionException("扫描超时，请稍后重试。"); }
        finally { lock (gate) scanCompletion = null; }
    }

    private List<NearbyNetwork> Networks(Guid adapter)
    {
        Check(WlanGetAvailableNetworkList(handle, ref adapter, 0, IntPtr.Zero, out var pointer), "读取附近 Wi-Fi", locationSensitive: true);
        try
        {
            return ReadList<AvailableNetwork>(pointer).Select(n =>
                new NearbyNetwork(Decode(n.Ssid), ProfileXml.Classify(n.Auth, n.SecurityEnabled), n.Signal, n.Auth, n.Cipher))
                .Where(n => n.Ssid.Length > 0)
                .GroupBy(n => n.Ssid, StringComparer.Ordinal).Select(g => {
                    var strongest = g.MaxBy(n => n.Signal)!;
                    return g.Select(n => n.Authentication).Distinct().Count() == 1 ? strongest
                        : strongest with { Authentication = Authentication.Unknown };
                }).OrderByDescending(n => n.Signal).ThenBy(n => n.Ssid, StringComparer.Ordinal).ToList();
        }
        finally { WlanFreeMemory(pointer); }
    }

    public async Task ConnectAsync(Guid adapter, Account account, Network network, string password, bool automatic,
        Action<string> progress, CancellationToken token = default)
    {
        await operation.WaitAsync(token);
        Snapshot? previous = null;
        bool connectionStarted = false;
        var selectedProfile = Rules.ProfileName(account.Id, network.Ssid);
        try
        {
            Trace("begin " + (automatic ? "automatic" : "manual"));
            Trace($"diagnostic registration code={diagnosticRegistrationResult}");
            Trace($"notifications sources={notificationSources} onexFallbackCode={onexFallbackResult}");
            if (OperatingSystem.IsWindows())
            {
                try
                {
                    using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
                    Trace("execution adminToken=" + new System.Security.Principal.WindowsPrincipal(identity)
                        .IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator));
                }
                catch (Exception error) { diagnostics?.Failure(error); }
            }
            diagnostics?.Stage("检查网卡状态");
            ConnectionWarning = null;
            var selection = new Selection(account.Id, network.Ssid, adapter, Rules.ProfileName(account.Id, network.Ssid));
            var state = Snapshot(adapter);
            previous = state;
            TraceSnapshot(state, selection, "initial");
            if (!state.Available || !state.PoweredOn || !state.Readable)
                throw new ConnectionException(state.Problem ?? "Wi-Fi 不可用或已关闭。");
            if (automatic)
            {
                if (Rules.Matches(selection, state) && state.HasAddress) return;
                if (state.Ssid is not null && !Rules.Matches(selection, state))
                    throw new ConnectionException("系统已连接其他网络或账号，停止自动重连。");
            }
            progress("正在查找 Wi-Fi…");
            diagnostics?.Stage("扫描目标网络");
            var visible = await ScanInternal(adapter, token);
            var target = visible.SingleOrDefault(n => n.Ssid == network.Ssid);
            Trace($"scan complete networkCount={visible.Count} targetFound={target is not null}");
            if (target is null && network.Hidden && network.Authentication != Authentication.Unknown)
                target = new(network.Ssid, network.Authentication, 0, network.Authentication switch
                    { Authentication.Enterprise => 6u, Authentication.Personal => 7u, _ => 1u },
                    network.Authentication == Authentication.Open ? 0u : 4u);
            if (target is null) throw new ConnectionException("没有扫描到目标 Wi-Fi；当前连接未主动断开。");
            Trace($"target authentication={target.Authentication} authAlgorithm={target.AuthAlgorithm} cipher={target.CipherAlgorithm} signal={target.Signal}");
            diagnostics?.Stage("读取并检查网络配置");
            var existing = ReadProfile(adapter, selectedProfile);
            Trace($"profile exists={existing is not null} flags={existing?.Flags} grantedAccess=0x{existing?.Access:X}");
            // Check collisions, scope and write access BEFORE interrupting the connection.
            uint profileFlags = ProfilePolicy.WriteFlags(existing?.Xml, existing?.Flags ?? 0, existing?.Access ?? 0, network.Ssid);
            var template = target.Authentication == Authentication.Enterprise
                ? existing?.Xml ?? FindEnterpriseProfile(adapter, network.Ssid) : null;
            // Validate credentials before interrupting the current network.
            var profile = ProfileXml.Build(account, network, target, password, template);
            var preserveEnterpriseProfile = existing is not null && target.Authentication == Authentication.Enterprise;
            if (preserveEnterpriseProfile)
                profile = ProfileXml.EnterpriseFromTemplate(existing!.Xml, selectedProfile, network,
                    preserveConnectionSettings: true);
            // A manual-joining profile loses the adapter to WLAN AutoConfig's own
            // auto-connect after the disconnect barrier, killing the fresh session.
            profile = ProfileXml.WithAutoJoin(profile);
            var writeProfile = existing is null || existing.Xml != profile;
            Trace($"profile plan existingEnterprise={preserveEnterpriseProfile} writeRequired={writeProfile}");
            TraceProfile(profile);
            // A different profile is switched by WlanConnect itself. Only an explicit
            // reauthentication of the SAME active profile needs a disconnect barrier.
            state = Snapshot(adapter);
            if (!state.Available || !state.PoweredOn || !state.Readable)
                throw new ConnectionException(state.Problem ?? "Wi-Fi 状态已变化，已停止连接。");
            if (automatic)
            {
                if (Rules.Matches(selection, state) && state.HasAddress) return;
                if (state.Ssid is not null && !Rules.Matches(selection, state))
                    throw new ConnectionException("系统已连接其他网络或账号，停止自动重连。");
            }
            if (state.ProfileName == selectedProfile && state.Ssid is not null)
            {
                progress("正在等待原认证会话结束…");
                diagnostics?.Stage("结束旧认证会话");
                await DisconnectAndWaitAsync(adapter, token);
            }
            // One shared profile named by the real SSID; credentials belong to the selected account.
            Trace("prepare profile");
            // Promote the target before connecting: after any disconnect WLAN AutoConfig
            // races its highest-priority automatic profile into the adapter, so the
            // target must already outrank every other automatic profile at this point.
            if (writeProfile)
            {
                diagnostics?.Stage("保存网络配置");
                var profileResult = WlanSetProfile(handle, ref adapter, profileFlags, profile, null, true, IntPtr.Zero, out var reason);
                Trace($"profile saved code={profileResult} reason=0x{reason:X} scope={profileFlags}");
                Check(profileResult, "保存连接配置");
                if (reason != 0) throw ReasonException(reason);
            }
            else Trace("profile preserved without WlanSetProfile");
            Check(WlanSetProfilePosition(handle, ref adapter, selectedProfile, 0, IntPtr.Zero), "设置所选连接优先级");
            Trace("profile promoted to highest priority before connecting");
            if (target.Authentication == Authentication.Enterprise)
            {
                diagnostics?.Stage("提交EAP账号凭据");
                var credentialsResult = WlanSetProfileEapXmlUserData(handle, ref adapter, selection.ProfileName, 0,
                    ProfileXml.PeapCredentials(account.Username, password), IntPtr.Zero);
                Trace($"EAP credentials saved code={credentialsResult}");
                Check(credentialsResult, "保存企业认证凭据");
            }
            if (automatic)
            {
                state = Snapshot(adapter);
                if (state.Ssid is not null && !Rules.SameConnection(selection, state))
                    throw new ConnectionException("系统已连接其他网络或账号，停止自动重连。");
            }
            // Finish all target-profile mutations BEFORE WlanConnect. Even a late
            // custom-data write can cancel a live session on affected drivers.
            // This marker identifies the submitted credentials, not authentication
            // success: a fresh completion AND stable link/IP checks are still required.
            diagnostics?.Stage("准备账号识别标记");
            WriteAccountMarker(adapter, selectedProfile, account.Id);
            try
            {
                progress("正在使用所选账号认证…");
                diagnostics?.Stage("等待Windows连接结果");
                connectionStarted = true;
                // Enterprise PEAP paths with a slow RADIUS server can take over a
                // minute; a shorter limit killed authentications that were succeeding.
                await ConnectProfileAsync(adapter, selectedProfile, TimeSpan.FromSeconds(90), token,
                    progress, certificatePromptHint: target.Authentication == Authentication.Enterprise);
                progress("正在确认账号配置与 IP 地址…");
                diagnostics?.Stage("确认IP与账号标记");
                // Read-only from here: rewriting the pre-authentication XML/EAP
                // data discards Windows' newly accepted certificate state and can
                // start a second authentication. Auto-join is already configured.
                int sample = 0;
                var verified = await ConnectionVerification.WaitAsync(selection, () =>
                {
                    state = Snapshot(adapter);
                    TraceSnapshot(state, selection, $"verify sample={++sample}");
                    return state;
                }, TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(1), token);
                if (verified)
                {
                    Trace("verification stableSamples=3; target profile unchanged after authentication");
                    diagnostics?.Stage("清理旧版网络条目");
                    ConnectionWarning = CleanupLegacyProfiles(adapter);
                    Trace($"native connection verified warning={ConnectionWarning is not null}");
                    return;
                }
                throw new ConnectionException("已完成认证，但未确认所选账号配置和可用 IP 地址。");
            }
            catch (TimeoutException) { throw new ConnectionException("连接确认超时，尚未确认账号认证成功。"); }
        }
        catch (Exception error)
        {
            Trace("failed " + error.GetType().Name + (error is ConnectionException ce ? $" reason=0x{ce.Reason:X}" : ""));
            diagnostics?.Failure(error);
            if (previous is not null && !token.IsCancellationRequested &&
                ConnectionRecovery.CanRestore(previous, Snapshot(adapter), selectedProfile, automatic, connectionStarted) &&
                IsDisconnected(adapter))
            {
                progress("目标连接失败，正在尝试恢复原网络…");
                diagnostics?.Stage("尝试恢复原网络");
                string recovery;
                try
                {
                    // Never retry the rejected target's credentials. Restore only the
                    // distinct, unchanged profile Windows was successfully using.
                    Trace("restore previous profile");
                    await ConnectProfileAsync(adapter, previous.ProfileName!, TimeSpan.FromSeconds(20), token);
                    bool restored = false;
                    for (int i = 0; i < 15; i++)
                    {
                        var current = Snapshot(adapter);
                        if (current.ProfileName == previous.ProfileName && current.Ssid == previous.Ssid && current.HasAddress)
                        { restored = true; break; }
                        await Task.Delay(1000, token);
                    }
                    recovery = restored ? "已恢复原网络；所选账号本次连接未成功。" : "未确认原网络恢复，请从 Windows Wi-Fi 菜单重新连接原网络。";
                    Trace(restored ? "restore verified" : "restore not verified");
                }
                catch (Exception restoreError)
                {
                    Trace("restore failed " + restoreError.GetType().Name);
                    recovery = "原网络未能自动恢复，请从 Windows Wi-Fi 菜单重新连接原网络。";
                }
                throw new ConnectionException(error.Message + "\n" + recovery,
                    error is ConnectionException { CredentialsRejected: true }, (error as ConnectionException)?.Reason);
            }
            throw;
        }
        finally
        {
            operation.Release();
        }
    }

    private bool IsDisconnected(Guid adapter)
    {
        try { return Interfaces().Any(i => i.Id == adapter && i.State == 4); }
        catch { return false; } // Do not interrupt another in-progress system connection.
    }

    private async Task DisconnectAndWaitAsync(Guid adapter, CancellationToken token)
    {
        Trace("disconnect requested");
        var result = WlanDisconnect(handle, ref adapter, IntPtr.Zero);
        if (result != 5023) Check(result, "断开原认证会话");
        else Trace("disconnect returned invalid-state; checking actual interface state");
        uint? lastState = null;
        bool observed = false;
        var confirmed = await DisconnectConfirmation.WaitAsync(() =>
        {
            var info = Interfaces().FirstOrDefault(i => i.Id == adapter);
            uint? state = info.Id == Guid.Empty ? null : unchecked((uint)info.State);
            if (!observed || state != lastState)
                Trace($"disconnect state={(state.HasValue ? state.Value.ToString() : "unavailable")}");
            observed = true; lastState = state;
            return state;
        }, TimeSpan.FromSeconds(10), TimeSpan.FromMilliseconds(250), token);
        Trace($"disconnect confirmation={confirmed} finalState={lastState}");
        if (!confirmed)
            throw new ConnectionException("未确认原认证会话稳定断开，已停止重新认证。",
                diagnosticCode: "disconnect_state_unconfirmed");
    }

    private async Task ConnectProfileAsync(Guid adapter, string profile, TimeSpan timeout, CancellationToken token,
        Action<string>? progress = null, bool certificatePromptHint = false)
    {
        var attempt = new ConnectionAttempt(adapter, profile);
        lock (gate) { pendingProfile = profile; pendingAdapter = adapter; connectionAttempt = attempt; }
        try
        {
            Trace("connect requested");
            var parameters = new ConnectionParameters { Profile = profile, BssType = 1 };
            var code = WlanConnect(handle, ref adapter, ref parameters, IntPtr.Zero);
            Trace($"connect returned code={code}");
            Check(code, "连接 Wi-Fi");
            Trace($"connection wait timeoutMs={timeout.TotalMilliseconds}");
            var wait = attempt.Completion.Task.WaitAsync(timeout, token);
            var stopwatch = System.Diagnostics.Stopwatch.StartNew();
            bool hinted = false;
            while (!wait.IsCompleted)
            {
                await Task.WhenAny(wait, Task.Delay(5000, token));
                if (wait.IsCompleted) break;
                TraceNativeState(adapter, profile);
                // Without an explicit server-name/thumbprint trust the supplicant
                // waits for the user to accept the server certificate in the
                // Windows network flyout; tell the user instead of stalling silently.
                if (certificatePromptHint && !hinted && stopwatch.ElapsedMilliseconds >= 10000)
                {
                    hinted = true;
                    Trace("certificate consent hint shown");
                    progress?.Invoke("仍在等待认证。如果 Windows 弹出“继续连接？”的证书确认框（网络浮窗中），请点击“连接”确认服务器证书。");
                }
            }
            var reason = await wait;
            Trace($"connection notification result=0x{reason:X}");
            if (reason != 0)
            {
                var failure = ReasonException(reason);
                Trace("WLAN errorText=" + failure.Message);
                if (failure.CredentialsRejected)
                {
                    var outcome = await StopPendingAttemptAsync(adapter, attempt);
                    throw new ConnectionException(failure.Message + "\n" + outcome, true, reason);
                }
                throw failure;
            }
        }
        catch (TimeoutException)
        {
            Trace("TIMEOUT waiting for connection completion");
            // WaitAsync only stops the managed wait; Windows keeps authenticating
            // unless its pending connection is explicitly stopped.
            uint? lastFailure;
            string? lastPhase;
            lock (gate) { lastFailure = attempt.LastFailure; lastPhase = attempt.LastPhase; }
            var outcome = await StopPendingAttemptAsync(adapter, attempt);
            var detail = lastFailure is { } failure ? "\nWindows 最近报告：" + ReasonException(failure).Message
                : "\nWindows 未返回明确失败原因，不能判断为密码错误或缺少管理员权限。";
            if (certificatePromptHint && lastPhase is not null && lastPhase.Contains("认证", StringComparison.Ordinal))
                detail += "\n若 Windows 的“继续连接？”服务器证书确认框未点击，认证会一直等待；确认证书后重连，" +
                    "或在此 Wi-Fi 的设置中填写 RADIUS 服务器名及根证书指纹以避免每次确认。";
            throw new ConnectionException("等待 Windows 连接结果超时。" + outcome +
                (lastPhase is null ? "" : "\n最后阶段：" + lastPhase + "。") + detail +
                "\n诊断日志：%LOCALAPPDATA%\\WiFiSwitch\\last-connection.log", false, lastFailure);
        }
        finally { lock (gate) { pendingProfile = null; connectionAttempt = null; } }
    }

    private async Task<string> StopPendingAttemptAsync(Guid adapter, ConnectionAttempt attempt)
    {
        try
        {
            var code = WlanQueryInterface(handle, ref adapter, 7, IntPtr.Zero, out var size, out var pointer, out _);
            Trace($"stop pending query code={code}");
            if (code != 0)
                return IsDisconnected(adapter) ? "Windows 当前已断开。" :
                    "无法确认 Windows 当前连接状态，未强制断开；系统可能仍在连接。";
            ConnectionAttributes current;
            try
            {
                if (size < Marshal.SizeOf<ConnectionAttributes>())
                    return "Windows 返回的连接状态不完整，未强制断开。";
                current = Marshal.PtrToStructure<ConnectionAttributes>(pointer);
            }
            finally { WlanFreeMemory(pointer); }
            bool canStop, authInProgress;
            lock (gate)
            {
                canStop = attempt.CanStop(current.State, current.Profile);
                authInProgress = canStop && !attempt.ShouldInterrupt(current.State, current.Profile);
            }
            Trace($"stop pending state={current.State} canStop={canStop} authInProgress={authInProgress}");
            if (authInProgress)
                return "802.1X 认证仍在进行，未强制断开；Windows 可能稍后自行完成连接，请稍后查看网络状态。";
            if (!canStop)
                return current.State == 1 ? "Windows 已建立连接，但应用未确认本次请求成功；已保留系统连接。" :
                    "未确认系统仍在执行本次请求，未强制断开其他连接。";
            await DisconnectAndWaitAsync(adapter, CancellationToken.None);
            Trace("pending connection stopped");
            return "已结束本次仍在进行的连接，请查看原因后手动重连。";
        }
        catch (Exception error)
        {
            Trace("pending stop failed " + error.GetType().Name);
            return "未能确认 Windows 已结束连接，系统可能仍在连接。";
        }
    }

    private void Trace(string message)
        => diagnostics?.Write(message);

    // Non-reversible correlation tag: identifies which saved profile emitted an
    // event without writing network names into diagnostics.
    internal static string ShortHash(string value)
        => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)))[..8].ToLowerInvariant();

    private void TraceSnapshot(Snapshot state, Selection selection, string label)
        => Trace($"{label} available={state.Available} radioOn={state.PoweredOn} readable={state.Readable} " +
            $"profileMatches={state.ProfileName == selection.ProfileName} accountMarkerMatches={state.AccountId == selection.AccountId} " +
            $"hasIP={state.HasAddress} matches={Rules.Matches(selection, state)}");

    private void TraceNativeState(Guid adapter, string profile)
    {
        try
        {
            var info = Interfaces().FirstOrDefault(i => i.Id == adapter);
            var stateName = info.State switch {
                0 => "网卡未就绪", 1 => "已连接", 2 => "临时网络", 3 => "正在断开",
                4 => "已断开", 5 => "正在关联接入点", 6 => "正在发现网络", 7 => "正在认证", _ => "未知" };
            var current = Snapshot(adapter);
            Trace($"HEARTBEAT interfaceState={info.State} state={stateName} available={current.Available} " +
                $"readable={current.Readable} radioOn={current.PoweredOn} targetConnected={current.ProfileName == profile} hasIP={current.HasAddress}");
        }
        catch (Exception error) { diagnostics?.Failure(error); }
    }

    private void TraceProfile(string xml)
    {
        // Log only explicitly selected non-identifying settings, never the XML or a hash of password-containing XML.
        var doc = XDocument.Parse(xml);
        string Flag(string name)
        {
            var text = doc.Descendants().FirstOrDefault(e => e.Name.LocalName == name)?.Value;
            return text is null ? "unset" : text is "true" or "1" ? "true" : text is "false" or "0" ? "false" : "other";
        }
        var types = doc.Descendants().Where(e => e.Name.LocalName == "Type")
            .Select(e => uint.TryParse(e.Value, out var type) ? type.ToString() : "unknown");
        Trace($"profile eapTypes={string.Join(",", types)} cacheUserData={Flag("cacheUserData")} " +
            $"useLogonCredentials={Flag("UseWinLogonCredentials")} serverValidation={Flag("PerformServerValidation")} " +
            $"disableCertPrompt={Flag("DisableUserPromptForServerValidation")} fastReconnect={Flag("FastReconnect")}");
    }

    private string? FindEnterpriseProfile(Guid adapter, string ssid)
    {
        Check(WlanGetProfileList(handle, ref adapter, IntPtr.Zero, out var list), "读取网络配置");
        try
        {
            foreach (var profile in ReadList<ProfileInfo>(list).OrderBy(p => p.Name.StartsWith("WiFiSwitch-", StringComparison.Ordinal)))
            {
                uint flags = 0; // Do not request plaintext keys.
                var result = WlanGetProfile(handle, ref adapter, profile.Name, IntPtr.Zero, out var xmlPointer, ref flags, out _);
                if (result != 0) continue;
                try
                {
                    var xml = Marshal.PtrToStringUni(xmlPointer)!;
                    var doc = XDocument.Parse(xml);
                    XNamespace w = ProfileXml.WlanNamespace;
                    var name = doc.Root?.Element(w + "SSIDConfig")?.Element(w + "SSID");
                    var hex = name?.Element(w + "hex")?.Value;
                    bool matches = hex is not null ? hex.Equals(Convert.ToHexString(Encoding.UTF8.GetBytes(ssid)), StringComparison.OrdinalIgnoreCase)
                        : name?.Element(w + "name")?.Value == ssid;
                    if (matches && doc.Descendants(w + "useOneX").Any(n => n.Value is "true" or "1")) return xml;
                }
                finally { WlanFreeMemory(xmlPointer); }
            }
            return null;
        }
        finally { WlanFreeMemory(list); }
    }

    private sealed record SavedProfile(string Xml, uint Flags, uint Access);
    private SavedProfile? ReadProfile(Guid adapter, string name)
    {
        uint flags = 0; // Never request plaintext keys.
        var code = WlanGetProfile(handle, ref adapter, name, IntPtr.Zero, out var pointer, ref flags, out var access);
        if (code == 1168) return null;
        Check(code, "读取网络配置");
        try { return new(Marshal.PtrToStringUni(pointer)!, flags, access); }
        finally { WlanFreeMemory(pointer); }
    }

    private Guid? ReadAccountMarker(Guid adapter, string profile)
    {
        var code = WlanGetProfileCustomUserData(handle, ref adapter, profile, IntPtr.Zero, out var size, out var pointer);
        if (code != 0) return null;
        try
        {
            if (size == 0 || size > 128 || pointer == IntPtr.Zero) return null;
            var bytes = new byte[size]; Marshal.Copy(pointer, bytes, 0, bytes.Length);
            return ProfilePolicy.ReadAccountMarker(bytes);
        }
        finally { if (pointer != IntPtr.Zero) WlanFreeMemory(pointer); }
    }
    private void WriteAccountMarker(Guid adapter, string profile, Guid accountId)
    {
        if (ReadAccountMarker(adapter, profile) == accountId) return;
        var data = ProfilePolicy.AccountMarker(accountId);
        Check(WlanSetProfileCustomUserData(handle, ref adapter, profile, (uint)data.Length, data, IntPtr.Zero), "保存当前账号标记");
    }

    public async Task<string?> CleanupLegacyProfilesAsync()
    {
        await operation.WaitAsync();
        try
        {
            return await Task.Run(() => {
                var warnings = Interfaces().Select(i => CleanupLegacyProfiles(i.Id)).Where(s => s is not null);
                var text = string.Join("\n", warnings);
                return text.Length == 0 ? null : text;
            });
        }
        finally { operation.Release(); }
    }

    public Task<bool> ClaimConnectionAsync(Guid adapter, string profile, Guid accountId) => Task.Run(() =>
    {
        // A profile from another logon session (for example an elevated one) is
        // simply absent here; precise WLAN errors still surface to the caller.
        if (ReadProfile(adapter, profile) is null) return false;
        WriteAccountMarker(adapter, profile, accountId);
        return ReadAccountMarker(adapter, profile) == accountId;
    });

    private string? CleanupLegacyProfiles(Guid adapter)
    {
        try { return CleanupLegacyProfilesChecked(adapter); }
        catch { return "旧版网络条目暂未清理，可在网络稳定后重新打开应用再试。"; }
    }
    private string? CleanupLegacyProfilesChecked(Guid adapter)
    {
        bool deferred = false;
        Check(WlanGetProfileList(handle, ref adapter, IntPtr.Zero, out var pointer), "读取旧版网络配置");
        try
        {
            foreach (var item in ReadList<ProfileInfo>(pointer))
            {
                if (!item.Name.StartsWith("WiFiSwitch-", StringComparison.Ordinal) || (item.Flags & 2) == 0) continue;
                var profile = ReadProfile(adapter, item.Name);
                if (profile is null || !Rules.IsLegacyProfile(item.Name, ProfilePolicy.Ssid(profile.Xml))) continue;
                var state = Snapshot(adapter);
                bool idle = Interfaces().Any(i => i.Id == adapter && i.State is 1 or 4);
                if (!ProfilePolicy.CanDeleteLegacy(item.Name, profile.Xml, profile.Flags, state, idle))
                { deferred = true; continue; }
                Check(WlanDeleteProfile(handle, ref adapter, item.Name, IntPtr.Zero), "清理旧版网络条目");
            }
        }
        finally { WlanFreeMemory(pointer); }
        return deferred ? "正在使用或暂时无法确认的旧版网络条目已保留；通过本应用连接成功后再清理，不会为清理主动断网。" : null;
    }

    private void OnNotification(ref Notification notification, IntPtr context)
    {
        // No UI, filesystem, credentials or WLAN calls from a native callback.
        try
        {
            lock (gate)
            {
                if (notification.InterfaceId != pendingAdapter) return;
                if (notification.Source == 4)
                {
                    Trace(DescribeOneX(notification.Code, notification.Data, notification.Size));
                    // Status 1 (in progress) keeps the timeout from interrupting authentication.
                    if (notification.Code == 1 && notification.Size >= 40 && notification.Data != IntPtr.Zero)
                        connectionAttempt?.NotifyOneX(unchecked((uint)Marshal.ReadInt32(notification.Data)));
                    return;
                }
                if (notification.Source == 16)
                {
                    Trace($"MSM code={notification.Code}");
                    if (notification.Code is >= 1 and <= 6 or 9 or 10 &&
                        notification.Size >= Marshal.SizeOf<MsmNotification>() && notification.Data != IntPtr.Zero)
                    {
                        var data = Marshal.PtrToStructure<MsmNotification>(notification.Data);
                        var phase = notification.Code switch
                        {
                            1 => "正在与接入点关联", 2 => "已与接入点关联", 3 => "正在进行安全认证",
                            4 => "无线链路已连接", 5 => "正在漫游", 6 => "漫游结束",
                            9 => "正在解除关联", _ => "无线链路已断开"
                        };
                        Trace($"MSM stage={phase} target={data.Profile == pendingProfile} profileHash={ShortHash(data.Profile)} reason=0x{data.Reason:X}");
                        connectionAttempt?.NotifyPhase(notification.InterfaceId, data.Profile, phase, data.Reason);
                    }
                    return;
                }
                if (notification.Source != 8) return;
                Trace($"ACM code={notification.Code}");
                if (notification.Code is 7 or 8)
                {
                    if (notification.Code == 8 && notification.Size >= 4 && notification.Data != IntPtr.Zero)
                        Trace($"scan failed reason=0x{unchecked((uint)Marshal.ReadInt32(notification.Data)):X}");
                    scanCompletion?.TrySetResult(notification.Code == 7 ? 0 : notification.Size >= 4 ?
                        unchecked((uint)Marshal.ReadInt32(notification.Data)) : 1);
                }
                if (notification.Code is 9 or 10 or 11 && notification.Size >= 568)
                {
                    var data = Marshal.PtrToStructure<ConnectionNotification>(notification.Data);
                    Trace($"connection event={notification.Code} target={data.Profile == pendingProfile} profileHash={ShortHash(data.Profile)} reason=0x{data.Reason:X}");
                    connectionAttempt?.Notify(notification.InterfaceId, data.Profile, notification.Code, data.Reason);
                }
            }
        }
        catch (Exception error) {
            Trace("notification decode failed type=" + error.GetType().Name);
            // Never allow managed exceptions to cross a native callback boundary.
        }
    }

    internal static string DescribeOneX(uint code, IntPtr data, uint size)
    {
        var prefix = $"ONEX code={code} payloadBytes={size}";
        if (data == IntPtr.Zero) return prefix + " noData";
        uint Read(int offset) => unchecked((uint)Marshal.ReadInt32(data, offset));
        if (code == 2 && size >= 4) return prefix + $" authRestartReason={Read(0)}";
        if (code != 1 || size < 40) return prefix + " statusUnavailable";
        // ONEX_RESULT_UPDATE_DATA: only numeric status/error fields are read.
        // authParams and RootCauseString can contain identities and are never read.
        var status = Read(0);
        var statusName = status switch {
            0 => "未开始", 1 => "进行中", 2 => "未找到802.1X认证方", 3 => "成功", 4 => "失败", _ => "未知或无效" };
        var result = prefix + $" status={status} state={statusName} reason=0x{Read(4):X} error=0x{Read(8):X8} " +
            $"backendSupport={Read(12)} backendEngaged={Read(16) != 0}";
        if ((Read(20) & 2) != 0)
        {
            var length = Read(32);
            var offset = Read(36);
            // Bounds check the variable blob without copying it into logs.
            if (length >= 4 && offset >= 40 && offset <= int.MaxValue && offset <= size && length <= size - offset)
            {
                var error = Read((int)offset);
                var category = error switch {
                    0x80420111 or 0x80420112 => "凭据被拒绝",
                    0x80420201 => "服务器证书无效", 0x80420202 => "服务器证书过期",
                    0x80420203 => "服务器证书已撤销", 0x80420400 => "缺少服务器根证书",
                    0x80420016 => "EAP方法不兼容", 0x80420019 => "EAP配置XML无效",
                    0x80420015 => "认证失败", _ => "未分类，请按原始错误码排查" };
                result += $" eapError=0x{error:X8} category={category}";
            }
            else result += " invalidEapErrorBlob";
        }
        return result;
    }

    private static ConnectionException ReasonException(uint reason)
    {
        if (reason == 0x38001)
            return new ConnectionException("Windows 取消了本次连接（0x38001）。这不是密码错误的明确结论；可能涉及连接请求冲突或系统认证窗口被取消。", false, reason);
        var text = new StringBuilder(1024);
        WlanReasonCodeToString(reason, (uint)text.Capacity, text, IntPtr.Zero);
        return new ConnectionException($"Windows Wi-Fi：{text}（0x{reason:X}）。", ProfileXml.IsCredentialFailure(reason), reason);
    }
    private static string Decode(Ssid ssid)
    {
        if (ssid.Length > 32) return "";
        try { return new UTF8Encoding(false, true).GetString(ssid.Bytes, 0, (int)ssid.Length); }
        catch (DecoderFallbackException) { return ""; } // No lossy name that could connect the wrong network.
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        WlanRegisterNotification(handle, 0, false, null, IntPtr.Zero, IntPtr.Zero, out _);
        WlanCloseHandle(handle, IntPtr.Zero);
        GC.KeepAlive(callback);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct InterfaceInfo { public Guid Id; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Description; public int State; }
    [StructLayout(LayoutKind.Sequential)] private struct Ssid { public uint Length; [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] Bytes; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct AvailableNetwork
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Profile;
        public Ssid Ssid;
        public uint BssType, BssidCount;
        [MarshalAs(UnmanagedType.Bool)] public bool Connectable;
        public uint NotConnectableReason, PhyCount;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)] public uint[] PhyTypes;
        [MarshalAs(UnmanagedType.Bool)] public bool MorePhys;
        public uint Signal;
        [MarshalAs(UnmanagedType.Bool)] public bool SecurityEnabled;
        public uint Auth, Cipher, Flags, Reserved;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Association
    {
        public Ssid Ssid; public uint BssType;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)] public byte[] Bssid;
        public uint PhyType, PhyIndex, Signal, RxRate, TxRate;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ConnectionAttributes
    {
        public uint State, Mode;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Profile;
        public Association Association;
        [MarshalAs(UnmanagedType.Bool)] public bool Security, OneX;
        public uint Auth, Cipher;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProfileInfo { [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Name; public uint Flags; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ConnectionParameters
    {
        public uint Mode;
        [MarshalAs(UnmanagedType.LPWStr)] public string Profile;
        public IntPtr Ssid, DesiredBssidList;
        public uint BssType, Flags;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Notification { public uint Source, Code; public Guid InterfaceId; public uint Size; public IntPtr Data; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ConnectionNotification
    {
        public uint Mode; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Profile;
        public Ssid Ssid; public uint BssType, Security, Reason, Flags;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MsmNotification
    {
        public uint Mode;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Profile;
        public Ssid Ssid; public uint BssType;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)] public byte[] Bssid;
        public uint Security, FirstPeer, LastPeer, Reason;
    }
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate void NotificationCallback(ref Notification notification, IntPtr context);
    [DllImport("wlanapi.dll")] private static extern uint WlanOpenHandle(uint version, IntPtr reserved, out uint negotiated, out IntPtr handle);
    [DllImport("wlanapi.dll")] private static extern uint WlanCloseHandle(IntPtr handle, IntPtr reserved);
    [DllImport("wlanapi.dll")] private static extern void WlanFreeMemory(IntPtr pointer);
    [DllImport("wlanapi.dll")] private static extern uint WlanEnumInterfaces(IntPtr handle, IntPtr reserved, out IntPtr list);
    [DllImport("wlanapi.dll")] private static extern uint WlanQueryInterface(IntPtr handle, ref Guid adapter, uint opcode, IntPtr reserved, out uint size, out IntPtr data, out uint valueType);
    [DllImport("wlanapi.dll")] private static extern uint WlanScan(IntPtr handle, ref Guid adapter, IntPtr ssid, IntPtr ie, IntPtr reserved);
    [DllImport("wlanapi.dll")] private static extern uint WlanGetAvailableNetworkList(IntPtr handle, ref Guid adapter, uint flags, IntPtr reserved, out IntPtr list);
    [DllImport("wlanapi.dll")] private static extern uint WlanGetProfileList(IntPtr handle, ref Guid adapter, IntPtr reserved, out IntPtr list);
    [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] private static extern uint WlanGetProfile(IntPtr handle, ref Guid adapter, string name, IntPtr reserved, out IntPtr xml, ref uint flags, out uint access);
    [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] private static extern uint WlanSetProfile(IntPtr handle, ref Guid adapter, uint flags, string xml, string? securityDescriptor, [MarshalAs(UnmanagedType.Bool)] bool overwrite, IntPtr reserved, out uint reason);
    [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] private static extern uint WlanSetProfileEapXmlUserData(IntPtr handle, ref Guid adapter, string name, uint flags, string xml, IntPtr reserved);
    [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] private static extern uint WlanSetProfilePosition(IntPtr handle, ref Guid adapter, string name, uint position, IntPtr reserved);
    [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] private static extern uint WlanDeleteProfile(IntPtr handle, ref Guid adapter, string name, IntPtr reserved);
    [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] private static extern uint WlanGetProfileCustomUserData(IntPtr handle, ref Guid adapter, string name, IntPtr reserved, out uint size, out IntPtr data);
    [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] private static extern uint WlanSetProfileCustomUserData(IntPtr handle, ref Guid adapter, string name, uint size, byte[] data, IntPtr reserved);
    [DllImport("wlanapi.dll")] private static extern uint WlanDisconnect(IntPtr handle, ref Guid adapter, IntPtr reserved);
    [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] private static extern uint WlanConnect(IntPtr handle, ref Guid adapter, ref ConnectionParameters parameters, IntPtr reserved);
    [DllImport("wlanapi.dll")] private static extern uint WlanRegisterNotification(IntPtr handle, uint source, [MarshalAs(UnmanagedType.Bool)] bool ignoreDuplicate, NotificationCallback? callback, IntPtr context, IntPtr reserved, out uint previous);
    [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] private static extern uint WlanReasonCodeToString(uint reason, uint length, StringBuilder text, IntPtr reserved);
}
