using WiFiSwitch.Core;

namespace WiFiSwitch.Windows;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args.Length == 2 && args[0] == "--self-test")
        {
            Environment.ExitCode = SelfTest.Run(args[1]);
            return;
        }
        using var instance = new Mutex(true, @"Local\WiFiSwitch.Windows", out var created);
        if (!created)
        {
            MessageBox.Show("WiFi Switch 已在运行，请点击任务栏通知区域中的双向箭头图标。", "WiFi Switch");
            return;
        }
        try
        {
            // Explicitly isolated demonstration; never reads real configuration or credentials.
            if (args.Contains("--demo", StringComparer.Ordinal))
            {
                var storage = new DemoStorage();
                using var wifi = new DemoWiFi();
                var model = new Controller(new Repository(storage, new DemoVault()), wifi);
                Application.Run(new MainForm(model, true));
                return;
            }
            var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "WiFiSwitch", "accounts.json");
            var repository = new Repository(new JsonStorage(path), new CredentialVault());
            using var diagnostics = new ConnectionDiagnostics(Path.GetDirectoryName(path)!);
            using var service = CreateService(diagnostics);
            var controller = new Controller(repository, service, diagnostics: diagnostics);
            WarnWhenElevated(controller);
            Application.Run(new MainForm(controller, false, diagnostics));
        }
        catch (Exception error)
        {
            MessageBox.Show("无法启动 WiFi Switch，原有账号数据未重置。\n\n" + error.Message, "WiFi Switch",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally { instance.ReleaseMutex(); }
    }

    private static IWiFiService CreateService(ConnectionDiagnostics diagnostics)
    {
        try { return new NativeWiFi(diagnostics); }
        catch (Exception error) { return new UnavailableWiFi(error.Message); }
    }

    // Wi-Fi profiles are isolated per logon session: an elevated session cannot see
    // profiles written by the normal session and vice versa, and connections made
    // from an elevated per-user profile are cancelled by Windows.
    private static void WarnWhenElevated(Controller controller)
    {
        if (!OperatingSystem.IsWindows()) return;
        try
        {
            using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
            if (!new System.Security.Principal.WindowsPrincipal(identity)
                .IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator)) return;
            controller.SetProblem("当前以管理员身份运行。管理员会话保存的 Wi-Fi 配置对普通会话不可见，" +
                "容易导致连接被系统取消或账号无法识别。建议退出后从开始菜单正常启动本应用。");
        }
        catch { /* 检测失败不阻止启动。 */ }
    }
}

internal sealed class UnavailableWiFi(string reason) : IWiFiService
{
    public Task<IReadOnlyList<Adapter>> AdaptersAsync() => Task.FromResult<IReadOnlyList<Adapter>>([]);
    public Task<Snapshot> SnapshotAsync(Guid? adapter, CancellationToken token = default)
        => Task.FromResult(new Snapshot(adapter ?? Guid.Empty, false, false, null, null, false, false, reason));
    public Task<IReadOnlyList<NearbyNetwork>> ScanAsync(Guid adapter, CancellationToken token = default)
        => Task.FromException<IReadOnlyList<NearbyNetwork>>(new ConnectionException(reason));
    public Task ConnectAsync(Guid adapter, Account account, Network network, string password, bool automatic,
        Action<string> progress, CancellationToken token = default) => Task.FromException(new ConnectionException(reason));
    public void Dispose() { }
}

internal sealed class DemoStorage : IConfigurationStorage
{
    private Configuration configuration = new() { Accounts =
    [
        new Account { Label = "日常办公", Username = "work@example.com", Networks = [new() { Ssid = "Office", Authentication = Authentication.Enterprise }] },
        new Account { Label = "手机热点", Networks = [new() { Ssid = "My Phone", Authentication = Authentication.Personal }] }
    ] };
    public Configuration Load() => configuration;
    public void Save(Configuration next) => configuration = next;
}
internal sealed class DemoVault : ICredentialVault
{
    private readonly Dictionary<Guid, string> secrets = [];
    public string? Read(Guid id) => secrets.GetValueOrDefault(id);
    public void Write(Guid id, string password) => secrets[id] = password;
    public void Delete(Guid id) => secrets.Remove(id);
}
internal sealed class DemoWiFi : IWiFiService
{
    private readonly Guid adapter = Guid.NewGuid();
    public Task<IReadOnlyList<Adapter>> AdaptersAsync() => Task.FromResult<IReadOnlyList<Adapter>>([new(adapter, "演示网卡")]);
    public Task<Snapshot> SnapshotAsync(Guid? id, CancellationToken token = default)
        => Task.FromResult(new Snapshot(adapter, true, true, null, null, false));
    public Task<IReadOnlyList<NearbyNetwork>> ScanAsync(Guid id, CancellationToken token = default)
        => Task.FromResult<IReadOnlyList<NearbyNetwork>>([
            new("Office", Authentication.Enterprise, 90, 6, 4), new("My Phone", Authentication.Personal, 76, 7, 4),
            new("Guest", Authentication.Open, 50, 1, 0)]);
    public Task ConnectAsync(Guid id, Account account, Network network, string password, bool automatic,
        Action<string> progress, CancellationToken token = default)
        => Task.FromException(new ConnectionException("演示模式不会连接真实 Wi-Fi。"));
    public void Dispose() { }
}
