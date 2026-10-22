using System.Text.Json;
using System.Xml.Linq;
using WiFiSwitch.Core;

var cases = new List<(string Name, Func<Task> Test)>();
void Test(string name, Action test) => cases.Add((name, () => { test(); return Task.CompletedTask; }));
void Async(string name, Func<Task> test) => cases.Add((name, test));
void Assert(bool condition, string message = "Assertion failed") { if (!condition) throw new Exception(message); }
void Throws(Action action) { try { action(); } catch { return; } throw new Exception("Expected failure"); }

Async("diagnostics capture credential read failure before native connection without leaking identity", async () => {
    var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
    try {
        using var log = new ConnectionDiagnostics(directory);
        var f = new Fixture(); var a = f.Add("private-label-and-user"); f.Vault.Delete(a.Id);
        var model = new Controller(f.Repo, f.Wifi, f.Clock, log);
        await model.RefreshAsync(); await model.ConnectAsync(a.Id, "Office");
        var text = File.ReadAllText(Path.Combine(directory, "last-connection.log"));
        Assert(text.Contains("读取已保存凭据") && text.Contains("END success=False"));
        Assert(!text.Contains(a.Username) && !text.Contains("Office") && !text.Contains("synthetic-secret"));
        Assert(f.Wifi.ConnectCalls == 0 && !model.Busy);
    } finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
});
Async("diagnostics capture native errors and persistence failure without exception message secrets", async () => {
    var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
    try {
        using var log = new ConnectionDiagnostics(directory);
        var f = new Fixture(); var a = f.Add("sensitive-account");
        var model = new Controller(f.Repo, f.Wifi, f.Clock, log);
        await model.RefreshAsync();
        f.Wifi.Error = new System.ComponentModel.Win32Exception(5, "sensitive-account synthetic-secret");
        await model.ConnectAsync(a.Id, "Office");
        var text = File.ReadAllText(Path.Combine(directory, "last-connection.log"));
        Assert(text.Contains("nativeCode=5") && !text.Contains("synthetic-secret") && !text.Contains(a.Username));
        f.Wifi.Error = null; f.Wifi.AfterConnect = () => f.Storage.Fail = true;
        await model.ConnectAsync(a.Id, "Office");
        text = File.ReadAllText(Path.Combine(directory, "last-connection.log"));
        Assert(text.Contains("保存当前账号状态") && text.Contains("END success=False") && !text.Contains("END success=True"));
    } finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
});
Async("diagnostics flush an unfinished attempt and retain bounded history in exported archive", async () => {
    var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
    try {
        using var log = new ConnectionDiagnostics(directory);
        log.Begin(false, Authentication.Enterprise); log.Stage("等待系统");
        for (int i = 0; i < 30 && !File.Exists(Path.Combine(directory, "last-connection.log")); i++) await Task.Delay(100);
        Assert(File.ReadAllText(Path.Combine(directory, "last-connection.log")).Contains("active=True"));
        for (int i = 0; i < 12; i++) { log.Begin(false, Authentication.Open); log.Write("iteration=" + i); log.End(true); }
        log.Begin(false, Authentication.Enterprise);
        for (int i = 0; i < 1700; i++) log.Write("sample=" + i);
        log.End(false);
        var archivePath = Path.Combine(directory, "export.zip");
        log.Export(archivePath);
        using var archive = System.IO.Compression.ZipFile.OpenRead(archivePath);
        Assert(archive.Entries.Count == 11 && archive.Entries.All(e => e.Name == "README.txt" || e.Name.EndsWith(".log")));
        var text = File.ReadAllText(Path.Combine(directory, "last-connection.log"));
        Assert(text.Contains("droppedOldLines=203") && text.Contains("sample=1699") && text.Split('\n').Length < 1510);
    } finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
});
Async("diagnostic write failure cannot break a successful connection and memory can be exported", async () => {
    var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(directory);
    var blocked = Path.Combine(directory, "not-a-directory"); File.WriteAllText(blocked, "fixture");
    try {
        using var log = new ConnectionDiagnostics(blocked);
        var f = new Fixture(); var a = f.Add("Group");
        var model = new Controller(f.Repo, f.Wifi, f.Clock, log);
        await model.RefreshAsync(); await model.ConnectAsync(a.Id, "Office");
        Assert(model.Active?.AccountId == a.Id && log.WriteError is not null);
        var archivePath = Path.Combine(directory, "export.zip"); log.Export(archivePath);
        using var archive = System.IO.Compression.ZipFile.OpenRead(archivePath);
        using var reader = new StreamReader(archive.Entries.Single(e => e.Name.EndsWith(".log")).Open());
        Assert(reader.ReadToEnd().Contains("END success=True"));
    } finally { Directory.Delete(directory, true); }
});
Test("latest-log write failure still bounds retained and exported connection history", () => {
    var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
    try {
        using var log = new ConnectionDiagnostics(directory);
        log.Begin(false, Authentication.Open); log.End(true);
        Directory.CreateDirectory(Path.Combine(directory, "last-connection.log.tmp"));
        for (int i = 0; i < 12; i++) { log.Begin(false, Authentication.Open); log.Write("iteration=" + i); log.End(true); }
        Assert(log.WriteError is not null);
        Assert(Directory.GetFiles(Path.Combine(directory, "diagnostics"), "*.log").Length == 10);
        var archivePath = Path.Combine(directory, "export.zip"); log.Export(archivePath);
        using var archive = System.IO.Compression.ZipFile.OpenRead(archivePath);
        Assert(archive.Entries.Count == 11);
    } finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
});
Test("802.1X decoder reads numeric errors only and rejects truncated or out-of-bounds blobs", () => {
    var pointer = System.Runtime.InteropServices.Marshal.AllocHGlobal(128);
    try {
        var data = new byte[128];
        System.Text.Encoding.UTF8.GetBytes("private-identity-and-password").CopyTo(data, 80);
        void Word(int offset, uint value) => BitConverter.GetBytes(value).CopyTo(data, offset);
        Word(0, 4); Word(4, 0x50005); Word(8, 0x80420015); Word(16, 1);
        Word(20, 2); Word(32, 4); Word(36, 40); Word(40, 0x80420202);
        void Copy() => System.Runtime.InteropServices.Marshal.Copy(data, 0, pointer, data.Length);
        Copy();
        var text = WiFiSwitch.Windows.NativeWiFi.DescribeOneX(1, pointer, 128);
        Assert(text.Contains("服务器证书过期") && text.Contains("error=0x80420015") && text.Contains("backendEngaged=True"));
        Assert(!text.Contains("private") && !text.Contains("password"));
        Assert(WiFiSwitch.Windows.NativeWiFi.DescribeOneX(1, pointer, 39).Contains("statusUnavailable"));
        Word(36, uint.MaxValue); Copy();
        Assert(WiFiSwitch.Windows.NativeWiFi.DescribeOneX(1, pointer, 128).Contains("invalidEapErrorBlob"));
        Word(36, 126); Copy();
        Assert(WiFiSwitch.Windows.NativeWiFi.DescribeOneX(1, pointer, 128).Contains("invalidEapErrorBlob"));
        Assert(WiFiSwitch.Windows.NativeWiFi.DescribeOneX(1, IntPtr.Zero, 128).Contains("noData"));
    } finally { System.Runtime.InteropServices.Marshal.FreeHGlobal(pointer); }
});

Test("new installation has no accounts", () => {
    var fixture = new Fixture(); Assert(fixture.Repo.Configuration.Accounts.Count == 0);
});
Test("stale cancelled completion cannot finish a new connection before its start", () => {
    var id = Guid.NewGuid();
    var attempt = new ConnectionAttempt(id, "target");
    attempt.Notify(id, "target", 10, 0x38001);
    Assert(!attempt.Completion.Task.IsCompleted);
    attempt.Notify(id, "target", 9, 0);
    attempt.Notify(id, "target", 10, 0);
    Assert(attempt.Completion.Task.Result == 0);
});
Test("connection notifications are isolated by adapter and profile", () => {
    var id = Guid.NewGuid();
    var attempt = new ConnectionAttempt(id, "target");
    attempt.Notify(Guid.NewGuid(), "target", 9, 0);
    attempt.Notify(id, "other", 9, 0);
    attempt.Notify(id, "target", 10, 0);
    Assert(!attempt.Completion.Task.IsCompleted);
    attempt.Notify(id, "target", 9, 0);
    attempt.Notify(id, "other", 10, 0x38001);
    Assert(!attempt.Completion.Task.IsCompleted);
    attempt.Notify(id, "target", 10, 0x38001);
    Assert(attempt.Completion.Task.Result == 0x38001);
    Assert(!ProfileXml.IsCredentialFailure(0x38001));
});
Test("authentication rejection ends attempt immediately without waiting for completion", () => {
    var id = Guid.NewGuid();
    var attempt = new ConnectionAttempt(id, "target");
    attempt.Notify(id, "target", 9, 0);
    attempt.Notify(id, "target", 11, 0x50005);
    Assert(attempt.Completion.Task.Result == 0x50005);
});
Test("timeout stops only a started matching pending connection", () => {
    var id = Guid.NewGuid();
    var attempt = new ConnectionAttempt(id, "target");
    Assert(!attempt.CanStop(7, "target"));
    attempt.Notify(id, "target", 9, 0);
    foreach (uint state in new uint[] { 5, 6, 7 }) Assert(attempt.CanStop(state, "target"));
    foreach (uint state in new uint[] { 0, 1, 2, 3, 4, 8 }) Assert(!attempt.CanStop(state, "target"));
    Assert(!attempt.CanStop(7, null));
    Assert(!attempt.CanStop(7, "other"));
    attempt.Notify(Guid.NewGuid(), "other", 9, 0);
    Assert(attempt.CanStop(7, "target"));
    attempt.Notify(id, "other", 9, 0);
    Assert(!attempt.CanStop(7, "target"));
    attempt.Notify(id, "target", 10, 0);
    Assert(!attempt.Completion.Task.IsCompleted);
});
Test("timeout keeps an in-progress authentication running and still stops other states", () => {
    var id = Guid.NewGuid();
    var attempt = new ConnectionAttempt(id, "target");
    Assert(!attempt.ShouldInterrupt(7, "target"));
    attempt.Notify(id, "target", 9, 0);
    Assert(attempt.ShouldInterrupt(7, "target"));
    attempt.NotifyOneX(1);
    Assert(!attempt.ShouldInterrupt(7, "target"));
    Assert(attempt.ShouldInterrupt(6, "target"));
    attempt.NotifyOneX(4);
    Assert(attempt.ShouldInterrupt(7, "target"));
    Assert(!attempt.ShouldInterrupt(1, "target"));
    var fresh = new ConnectionAttempt(id, "target");
    fresh.NotifyOneX(1);
    Assert(fresh.LastOneXStatus is null);
    fresh.Notify(id, "target", 9, 0);
    Assert(fresh.ShouldInterrupt(7, "target"));
});
Test("intermediate failures remain diagnostic while Windows may try another access point", () => {
    var id = Guid.NewGuid();
    var attempt = new ConnectionAttempt(id, "target");
    attempt.Notify(id, "target", 11, 123);
    Assert(attempt.LastFailure is null);
    attempt.Notify(id, "target", 9, 0);
    attempt.Notify(id, "target", 11, 123);
    Assert(attempt.LastFailure == 123 && !attempt.Completion.Task.IsCompleted);
    attempt.Notify(id, "other", 11, 456);
    Assert(attempt.LastFailure == 123);
    attempt.Notify(id, "target", 10, 0);
    Assert(attempt.Completion.Task.Result == 0);
});
Test("phase diagnostics never claim authentication success or consume another request", () => {
    var id = Guid.NewGuid();
    var attempt = new ConnectionAttempt(id, "target");
    attempt.NotifyPhase(id, "target", "old", 123);
    Assert(attempt.LastPhase is null);
    attempt.Notify(id, "target", 9, 0);
    attempt.NotifyPhase(id, "target", "authenticating", 0);
    attempt.NotifyPhase(Guid.NewGuid(), "target", "other adapter", 123);
    attempt.NotifyPhase(id, "other", "other profile", 123);
    Assert(attempt.LastPhase == "authenticating" && attempt.LastFailure is null);
    attempt.NotifyPhase(id, "target", "failed", 321);
    Assert(attempt.LastFailure == 321 && !attempt.Completion.Task.IsCompleted);
    attempt.Notify(id, "other", 9, 0);
    attempt.NotifyPhase(id, "target", "stale", 456);
    Assert(attempt.LastPhase == "failed" && attempt.LastFailure == 321);
});
Test("explicit credential rejection in security notifications stops the wait", () => {
    var id = Guid.NewGuid();
    var attempt = new ConnectionAttempt(id, "target");
    attempt.Notify(id, "target", 9, 0);
    attempt.NotifyPhase(id, "target", "authentication failed", 0x50005);
    Assert(attempt.Completion.Task.Result == 0x50005);
});
Test("recovery only restores a distinct previously working profile after manual failure", () => {
    var id = Guid.NewGuid();
    var previous = new Snapshot(id, true, true, "Office", "old-profile", true);
    var disconnected = previous with { Ssid = null, ProfileName = null, HasAddress = false };
    Assert(ConnectionRecovery.CanRestore(previous, disconnected, "target", false, true));
    Assert(!ConnectionRecovery.CanRestore(previous, disconnected, "old-profile", false, true));
    Assert(!ConnectionRecovery.CanRestore(previous, disconnected, "target", true, true));
    Assert(!ConnectionRecovery.CanRestore(previous, disconnected, "target", false, false));
    Assert(!ConnectionRecovery.CanRestore(previous with { HasAddress = false }, disconnected, "target", false, true));
    Assert(!ConnectionRecovery.CanRestore(previous, previous with { ProfileName = "external" }, "target", false, true));
    Assert(!ConnectionRecovery.CanRestore(previous, disconnected with { PoweredOn = false }, "target", false, true));
    Assert(!ConnectionRecovery.CanRestore(previous, disconnected with { Readable = false }, "target", false, true));
    Assert(!ConnectionRecovery.CanRestore(previous, disconnected with { InterfaceId = Guid.NewGuid() }, "target", false, true));
});
Test("native WLAN structs match Windows SDK x64 ABI", () => {
    var types = new Dictionary<string, int> {
        ["InterfaceInfo"] = 532, ["Ssid"] = 36, ["AvailableNetwork"] = 628,
        ["Association"] = 68, ["ConnectionAttributes"] = 604, ["ProfileInfo"] = 516,
        ["ConnectionParameters"] = 40, ["Notification"] = 40, ["ConnectionNotification"] = 568,
        ["MsmNotification"] = 580 };
    foreach (var item in types) {
        var type = typeof(WiFiSwitch.Windows.NativeWiFi).GetNestedType(item.Key, System.Reflection.BindingFlags.NonPublic)!;
        Assert(System.Runtime.InteropServices.Marshal.SizeOf(type) == item.Value, "ABI size mismatch: " + item.Key);
    }
    var credentials = typeof(WiFiSwitch.Windows.CredentialVault).GetNestedType("Credential", System.Reflection.BindingFlags.NonPublic)!;
    Assert(System.Runtime.InteropServices.Marshal.SizeOf(credentials) == 80, "Credential x64 ABI mismatch");
});
Test("required fields vary with authentication", () => {
    Assert(!Rules.RequiresUsername([]) && Rules.RequiresPassword([]));
    Assert(!Rules.RequiresUsername([new() { Authentication = Authentication.Personal }]));
    Assert(!Rules.RequiresPassword([new() { Authentication = Authentication.Open }]));
    Assert(Rules.RequiresUsername([new() { Authentication = Authentication.Open }, new() { Authentication = Authentication.Enterprise }]));
});
Test("SSID validation uses UTF8 byte count", () => {
    Rules.ValidateSsid("  leading spaces");
    Throws(() => Rules.ValidateSsid(new string('中', 11)));
    Throws(() => Rules.ValidateSsid("bad\0ssid")); Throws(() => Rules.ValidateSsid(" "));
});
Test("save credentials separately and preserve empty edited password", () => {
    var f = new Fixture(); var a = f.Add("Group"); var secret = f.Repo.Password(a);
    f.Repo.SaveAccount(a with { Label = "Renamed" }, null);
    Assert(f.Repo.Password(a) == secret);
    Assert(!JsonSerializer.Serialize(f.Repo.Configuration).Contains("synthetic-secret", StringComparison.Ordinal));
});
Test("metadata failure rolls back a changed credential", () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Storage.Fail = true;
    Throws(() => f.Repo.SaveAccount(a with { Label = "Changed" }, "different-secret"));
    Assert(f.Vault.Read(a.Id) == "synthetic-secret");
    Assert(f.Repo.Configuration.Accounts.Single().Label == "Group");
});
Test("new account metadata failure removes new credential", () => {
    var f = new Fixture(); f.Storage.Fail = true; var a = new Account { Username = "user" };
    Throws(() => f.Repo.SaveAccount(a, "synthetic-secret")); Assert(f.Vault.Read(a.Id) is null);
});
Test("delete rollback retains credential and metadata", () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Storage.Fail = true;
    Throws(() => f.Repo.DeleteAccount(a.Id));
    Assert(f.Repo.Configuration.Accounts.Count == 1 && f.Vault.Read(a.Id) == "synthetic-secret");
});
Test("missing saved credential can be replaced or account deleted", () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Vault.Delete(a.Id);
    f.Repo.SaveAccount(a, "replacement-secret");
    Assert(f.Repo.Password(a) == "replacement-secret");
    f.Vault.Delete(a.Id); f.Repo.DeleteAccount(a.Id);
    Assert(f.Repo.Configuration.Accounts.Count == 0);
});
Test("one account multiple networks and remove only association", () => {
    var f = new Fixture(); var a = f.Add("Group");
    f.Repo.SaveAccount(a with { Networks = [..a.Networks, new() { Ssid = "Campus", Authentication = Authentication.Enterprise }] }, null);
    f.Repo.RemoveNetwork(a.Id, "Office");
    Assert(f.Repo.Configuration.Accounts.Single().Networks.Single().Ssid == "Campus");
    Assert(f.Vault.Read(a.Id) == "synthetic-secret");
});
Test("all accounts share the real SSID profile name", () => {
    var id = Guid.NewGuid();
    Assert(Rules.ProfileName(id, "Office") == "Office");
    Assert(Rules.ProfileName(id, "Office") == Rules.ProfileName(Guid.NewGuid(), "Office"));
    Assert(Rules.ProfileName(id, "Office") != Rules.ProfileName(id, "office"));
});
Test("shared profile account marker prevents attributing another account", () => {
    var f = new Fixture(); var a = f.Add("Group"); var b = f.Add("Studio");
    var state = f.Wifi.State with { ProfileName = "Office", AccountId = a.Id };
    Assert(Rules.Matches(f.Selection(a), state));
    Assert(!Rules.Matches(f.Selection(b), state));
    Assert(!Rules.Matches(f.Selection(a), state with { AccountId = null }));
    Assert(ProfilePolicy.ReadAccountMarker(ProfilePolicy.AccountMarker(a.Id)) == a.Id);
    Assert(ProfilePolicy.ReadAccountMarker(System.Text.Encoding.UTF8.GetBytes(a.Id.ToString())) is null);
});
Test("old saved current and failure records load without renaming or reading passwords", () => {
    var f = new Fixture(); var a = f.Add("Group");
    var legacy = f.Selection(a) with { ProfileName = Rules.LegacyProfileName(a.Id, "Office") };
    f.Repo.Commit(f.Repo.Configuration with { Current = legacy, Failure = new(legacy, 3, "cancelled", false) });
    var reads = f.Vault.Reads;
    var loaded = new Repository(f.Storage, f.Vault);
    Assert(loaded.Configuration.Current == legacy && loaded.Configuration.Failure?.Count == 3);
    Assert(f.Vault.Reads == reads);
    Assert(Rules.Matches(legacy, f.Wifi.State with { ProfileName = legacy.ProfileName }));
});
Test("legacy cleanup requires exact name hash per-user scope and inactive readable interface", () => {
    var id = Guid.NewGuid(); var name = Rules.LegacyProfileName(id, "Office");
    var a = new Account { Id = id };
    var network = new Network { Ssid = "Office", Authentication = Authentication.Open };
    var xml = ProfileXml.Build(a, network, new("Office", Authentication.Open, 80, 1, 0), "");
    var state = new Snapshot(Guid.NewGuid(), true, true, "Office", "Office", true);
    Assert(ProfilePolicy.CanDeleteLegacy(name, xml, 2, state, true));
    Assert(!ProfilePolicy.CanDeleteLegacy("Office", xml, 2, state, true));
    Assert(!ProfilePolicy.CanDeleteLegacy(name, xml, 0, state, true));
    Assert(!ProfilePolicy.CanDeleteLegacy(name, xml, 3, state, true));
    Assert(!ProfilePolicy.CanDeleteLegacy(name, xml, 2, state with { ProfileName = name }, true));
    Assert(!ProfilePolicy.CanDeleteLegacy(name, xml, 2, state with { Readable = false }, true));
    Assert(!ProfilePolicy.CanDeleteLegacy(name, xml, 2, state, false));
    Assert(!Rules.IsLegacyProfile(name, "Another Wi-Fi"));
    Assert(!Rules.IsLegacyProfile("WiFiSwitch-not-ours", "Office"));
});
Test("shared profile preserves scope and rejects policy collisions and insufficient access before disconnect", () => {
    var a = new Account();
    var xml = ProfileXml.Build(a, new() { Ssid = "Office" }, new("Office", Authentication.Open, 70, 1, 0), "");
    Assert(ProfilePolicy.ReuseFlags(xml, "Office", 0, 0x70023) == 0);
    Assert(ProfilePolicy.ReuseFlags(xml, "Office", 2, 0x70023) == 2);
    Throws(() => ProfilePolicy.ReuseFlags(xml, "Other", 2, 0x70023));
    Throws(() => ProfilePolicy.ReuseFlags(xml, "Office", 1, 0x70023));
    Throws(() => ProfilePolicy.ReuseFlags(xml, "Office", 0, 0x20021));
});
Test("new profiles default to all-user scope while an existing scope is preserved", () => {
    var xml = ProfileXml.Build(new Account(), new() { Ssid = "Office" }, new("Office", Authentication.Open, 70, 1, 0), "");
    Assert(ProfilePolicy.WriteFlags(null, 0, 0, "Office") == 0);
    Assert(ProfilePolicy.WriteFlags(xml, 2, 0x70023, "Office") == 2);
    Assert(ProfilePolicy.WriteFlags(xml, 0, 0x70023, "Office") == 0);
    Throws(() => ProfilePolicy.WriteFlags(xml, 1, 0x70023, "Office"));
    Throws(() => ProfilePolicy.WriteFlags(xml, 2, 0x20021, "Office"));
});
Test("generated profiles show the real network name for every account", () => {
    XNamespace w = ProfileXml.WlanNamespace;
    foreach (var auth in new[] { Authentication.Enterprise, Authentication.Personal, Authentication.Open })
    {
        var a = new Account { Username = "synthetic-user" };
        var network = new Network { Ssid = "Office", Authentication = auth };
        var nearby = new NearbyNetwork("Office", auth, 90, auth == Authentication.Enterprise ? 6u : auth == Authentication.Personal ? 7u : 1u,
            auth == Authentication.Open ? 0u : 4u);
        var xml = ProfileXml.Build(a, network, nearby, "synthetic-secret");
        Assert(XDocument.Parse(xml).Root!.Element(w + "name")!.Value == "Office");
        Assert(ProfilePolicy.Ssid(xml) == "Office");
        Assert(!xml.Contains("WiFiSwitch-", StringComparison.Ordinal));
    }
});
Test("SSID alone never proves current account", () => {
    var f = new Fixture(); var a = f.Add("Group"); var selection = f.Selection(a);
    Assert(!Rules.Matches(selection, f.Wifi.State with { ProfileName = "Office" }));
    Assert(!Rules.Matches(selection, f.Wifi.State with { ProfileName = selection.ProfileName, InterfaceId = Guid.NewGuid() }));
});
Async("switch from Studio to Group persists and restores Group", async () => {
    var f = new Fixture(); var group = f.Add("Group"); var studio = f.Add("Studio");
    var model = f.Model(); await model.RefreshAsync();
    await model.ConnectAsync(studio.Id, "Office"); await model.ConnectAsync(group.Id, "Office");
    Assert(model.Active?.AccountId == group.Id && f.Repo.Configuration.Current?.AccountId == group.Id);
    var reopened = new Controller(new Repository(f.Storage, f.Vault), f.Wifi, f.Clock);
    await reopened.RefreshAsync();
    Assert(reopened.Active?.AccountId == group.Id && f.Wifi.ConnectCalls == 2);
    Assert(reopened.OrderedAccounts.First().Id == group.Id);
});
Async("pending connection belongs only to the selected account and network and rejects concurrent requests", async () => {
    var f = new Fixture(); var target = f.Add("Group"); var other = f.Add("Studio");
    target = target with { Networks = [.. target.Networks, new() { Ssid = "Phone", Authentication = Authentication.Open }] };
    f.Repo.SaveAccount(target, null); f.Remember(other);
    var pending = new TaskCompletionSource(); f.Wifi.ConnectWait = pending.Task;
    var model = f.Model(); await model.RefreshAsync();
    var observed = new List<Selection?>(); model.Changed += () => observed.Add(model.Connecting);
    var connection = model.ConnectAsync(target.Id, "Office");
    try {
        Assert(model.Busy && model.IsConnecting(target.Id, "Office"));
        Assert(!model.IsConnecting(other.Id, "Office") && !model.IsConnecting(target.Id, "Phone"));
        Assert(observed.First() == f.Selection(target), "The first render must already know the selected row");
        await model.ConnectAsync(other.Id, "Office");
        await model.ConnectAsync(target.Id, "Phone");
        Assert(f.Wifi.ConnectCalls == 1 && model.Connecting == f.Selection(target));
    } finally { pending.TrySetResult(); await connection; }
    Assert(!model.Busy && model.Connecting is null && observed.Last() is null);
    Assert(model.Active?.AccountId == target.Id);
});
Async("failed and cancelled attempts clear the connecting row before the next manual or automatic attempt", async () => {
    foreach (var cancel in new[] { false, true }) {
        var f = new Fixture(); var a = f.Add("Group"); f.Remember(a);
        var pending = new TaskCompletionSource(); f.Wifi.ConnectWait = pending.Task;
        var model = f.Model(); await model.RefreshAsync();
        using var cts = new CancellationTokenSource();
        var connection = model.ConnectAsync(a.Id, "Office", automatic: true, token: cts.Token);
        Assert(model.IsConnecting(a.Id, "Office") && model.Connecting == f.Selection(a));
        if (cancel) cts.Cancel(); else { f.Wifi.Error = new ConnectionException("synthetic rejection", true); pending.SetResult(); }
        await connection;
        Assert(!model.Busy && model.Connecting is null && !model.IsConnecting(a.Id, "Office") && model.NoticeIsError);
        var next = f.Add("Next");
        f.Wifi.Error = null; f.Wifi.ConnectWait = null;
        await model.ConnectAsync(next.Id, "Office");
        Assert(model.Active?.AccountId == next.Id && model.Connecting is null && f.Wifi.ConnectCalls == 2);
    }
});
Async("reopen and sleep do not read secret or reconnect", async () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Remember(a); var reads = f.Vault.Reads;
    var model = f.Model(); await model.RefreshAsync(); model.Suspend(); f.Clock.Advance(100);
    await model.RefreshAsync(); model.Resume(); await model.RefreshAsync();
    Assert(model.Active?.AccountId == a.Id && f.Vault.Reads == reads && f.Wifi.ConnectCalls == 0);
});
Async("external profile does not inherit old green account or trigger reconnect", async () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Remember(a);
    f.Wifi.State = f.Wifi.State with { ProfileName = "system-profile" };
    var model = f.Model(); await model.RefreshAsync(); f.Clock.Advance(100); await model.RefreshAsync();
    Assert(model.Active is null && f.Wifi.ConnectCalls == 0 && model.Configuration.Current?.AccountId == a.Id);
});
Async("startup unavailable, Wi-Fi off and unreadable preserve records", async () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Remember(a);
    var model = f.Model();
    foreach (var state in new[] { f.Wifi.State with { Available = false }, f.Wifi.State with { PoweredOn = false }, f.Wifi.State with { Readable = false } })
    { f.Wifi.State = state; await model.RefreshAsync(); f.Clock.Advance(100); await model.RefreshAsync(); }
    Assert(model.Configuration.Current?.AccountId == a.Id && f.Wifi.ConnectCalls == 0);
});
Async("authentication rejection stops after one and persists across restart", async () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Remember(a);
    f.Wifi.State = f.Wifi.State with { Ssid = null, ProfileName = null, HasAddress = false };
    f.Wifi.Error = new ConnectionException("EAP rejected", true);
    var model = f.Model(); await model.RefreshAsync(); f.Clock.Advance(11); await model.RefreshAsync();
    Assert(f.Wifi.ConnectCalls == 1 && model.RetryStopped && model.EditSuggested == a.Id);
    var reopened = f.Model(); f.Clock.Advance(100); await reopened.RefreshAsync();
    Assert(f.Wifi.ConnectCalls == 1 && reopened.RetryStopped);
});
Async("network failure retries three times then requires manual reconnect", async () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Remember(a);
    f.Wifi.State = f.Wifi.State with { Ssid = null, ProfileName = null, HasAddress = false };
    f.Wifi.Error = new ConnectionException("network timeout"); var model = f.Model();
    await model.RefreshAsync();
    for (int i = 0; i < 6; i++) { f.Clock.Advance(11); await model.RefreshAsync(); }
    Assert(f.Wifi.ConnectCalls == 3 && model.Configuration.Failure?.Count == 3 && model.RetryStopped);
    f.Wifi.Error = null; await model.ConnectAsync(a.Id, "Office");
    Assert(model.Active?.AccountId == a.Id && !model.RetryStopped);
});
Async("a healthy recognized connection clears the stopped failure without reconnecting", async () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Remember(a);
    var healthy = f.Wifi.State;
    f.Wifi.State = healthy with { Ssid = null, ProfileName = null, HasAddress = false, AccountId = null };
    f.Wifi.Error = new ConnectionException("network timeout"); var model = f.Model();
    await model.RefreshAsync();
    for (int i = 0; i < 6; i++) { f.Clock.Advance(11); await model.RefreshAsync(); }
    Assert(f.Wifi.ConnectCalls == 3 && model.RetryStopped);
    f.Wifi.Error = null; f.Wifi.State = healthy;
    f.Clock.Advance(11); await model.RefreshAsync();
    Assert(model.Active?.AccountId == a.Id && !model.RetryStopped && f.Wifi.ConnectCalls == 3);
    Assert(model.Notice is null && !model.NoticeIsError && model.EditSuggested is null);
});
Async("late manual connection recovery removes the final-verification error and persists without retry", async () => {
    var f = new Fixture(); var a = f.Add("Group"); var model = f.Model();
    await model.RefreshAsync();
    f.Wifi.AfterConnect = () => f.Wifi.State = f.Wifi.State with { HasAddress = false };
    await model.ConnectAsync(a.Id, "Office");
    Assert(model.NoticeIsError && model.Notice!.Contains("未确认所选账号") && model.Active is null);
    f.Wifi.State = f.Wifi.State with { HasAddress = true };
    await model.RefreshAsync();
    Assert(model.Active?.AccountId == a.Id && model.Configuration.Failure is null);
    Assert(model.Notice is null && !model.NoticeIsError && model.EditSuggested is null && f.Wifi.ConnectCalls == 1);
    var reopened = new Controller(new Repository(f.Storage, f.Vault), f.Wifi, f.Clock);
    await reopened.RefreshAsync();
    Assert(reopened.Active?.AccountId == a.Id && !reopened.NoticeIsError && f.Wifi.ConnectCalls == 1);
});
Async("a persisted failure notice clears after recognized recovery on restart", async () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Remember(a);
    f.Repo.Commit(f.Repo.Configuration with { Failure = new(f.Selection(a), 3, "authentication timeout", true) });
    var model = new Controller(new Repository(f.Storage, f.Vault), f.Wifi, f.Clock);
    Assert(model.NoticeIsError && model.EditSuggested == a.Id);
    await model.RefreshAsync();
    Assert(model.Active?.AccountId == a.Id && model.Notice is null && !model.NoticeIsError);
    Assert(model.EditSuggested is null && f.Wifi.ConnectCalls == 0);
});
Async("failure notice survives an unrecognized or unhealthy connection", async () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Remember(a); var healthy = f.Wifi.State;
    f.Repo.Commit(f.Repo.Configuration with { Failure = new(f.Selection(a), 3, "connection timeout", false) });
    var model = f.Model(); var notice = model.Notice;
    foreach (var state in new[] {
        healthy with { AccountId = null }, healthy with { AccountId = Guid.NewGuid() },
        healthy with { HasAddress = false }, healthy with { InterfaceId = Guid.NewGuid() },
        healthy with { ProfileName = "other" }, healthy with { Ssid = "Other" },
        healthy with { Available = false }, healthy with { PoweredOn = false }, healthy with { Readable = false }
    }) {
        f.Wifi.State = state; f.Clock.Advance(100); await model.RefreshAsync();
        Assert(model.Active is null && model.Configuration.Failure is not null && model.Notice == notice && model.NoticeIsError);
    }
    Assert(f.Wifi.ConnectCalls == 0);
});
Async("network recovery preserves newer unrelated errors and dismissed notices", async () => {
    foreach (var dismiss in new[] { false, true }) {
        var f = new Fixture(); var a = f.Add("Group"); f.Remember(a);
        f.Repo.Commit(f.Repo.Configuration with { Failure = new(f.Selection(a), 3, "connection timeout", false) });
        var model = f.Model();
        if (dismiss) model.DismissNotice(); else model.SetProblem("无法导出诊断：拒绝访问。");
        await model.RefreshAsync();
        Assert(model.Active?.AccountId == a.Id && model.Configuration.Failure is null);
        Assert(dismiss ? model.Notice is null && !model.NoticeIsError :
            model.Notice == "无法导出诊断：拒绝访问。" && model.NoticeIsError);
    }
});
Async("failed recovery persistence does not falsely clear the error", async () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Remember(a);
    f.Repo.Commit(f.Repo.Configuration with { Failure = new(f.Selection(a), 3, "connection timeout", false) });
    var model = f.Model(); f.Storage.Fail = true;
    try { await model.RefreshAsync(); throw new Exception("Expected storage failure"); }
    catch (IOException) { }
    Assert(model.Configuration.Failure is not null && model.NoticeIsError && model.Active is null);
});
Async("claim adopts the current system connection and clears the stopped failure", async () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Remember(a);
    f.Wifi.State = f.Wifi.State with { AccountId = null };
    f.Repo.Commit(f.Repo.Configuration with { Failure = new(f.Selection(a), 3, "timeout", false) });
    var model = f.Model(); await model.RefreshAsync();
    Assert(model.Active is null && model.CanClaim);
    await model.ClaimCurrentAsync();
    Assert(model.Active?.AccountId == a.Id && f.Wifi.ClaimCalls == 1);
    Assert(model.Configuration.Failure is null && model.Configuration.Current?.AccountId == a.Id && !model.NoticeIsError);
});
Async("claim waits for delayed marker and IP visibility without another claim or connection", async () => {
    var f = new Fixture(); var a = f.Add("Group"); var other = f.Add("Other"); f.Remember(a);
    var healthy = f.Wifi.State; f.Wifi.State = healthy with { AccountId = null };
    var model = f.Model(); await model.RefreshAsync();
    f.Wifi.Snapshots = new([healthy with { AccountId = null }, healthy with { HasAddress = false }, healthy, healthy, healthy]);
    var claim = model.ClaimCurrentAsync();
    Assert(model.Claiming && model.Busy && model.Connecting is null && !model.CanClaim);
    await model.ClaimCurrentAsync(); await model.ConnectAsync(other.Id, "Office");
    Assert(f.Wifi.ClaimCalls == 1 && f.Wifi.ConnectCalls == 0);
    await claim;
    Assert(model.Active?.AccountId == a.Id && !model.NoticeIsError && !model.Busy && !model.Claiming);
    Assert(model.Notice!.StartsWith("已认领当前连接") && f.Wifi.Snapshots.Count == 0);
});
Async("claim timeout notice clears on late recovery even without a persisted connection failure", async () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Remember(a);
    var healthy = f.Wifi.State; f.Wifi.State = healthy with { AccountId = null };
    var model = f.Model(); await model.RefreshAsync();
    // Simulate Windows briefly dropping the link after the marker was written.
    f.Wifi.AfterClaim = () => f.Wifi.State = healthy with { HasAddress = false };
    try { await model.ClaimCurrentAsync(); throw new Exception("Expected unconfirmed status"); }
    catch (ConnectionException error) {
        Assert(error.DiagnosticCode == "claim_state_unconfirmed" && error.RecoverySelection == f.Selection(a));
        model.SetProblem(error); // Same exception path as the actual claim button.
    }
    Assert(model.NoticeIsError && model.Configuration.Failure is null && !model.Busy && model.Active is null);
    var notice = model.Notice;
    foreach (var wrong in new[] {
        healthy with { AccountId = null }, healthy with { AccountId = Guid.NewGuid() },
        healthy with { HasAddress = false }, healthy with { InterfaceId = Guid.NewGuid() },
        healthy with { ProfileName = "other" }, healthy with { Ssid = "Other" },
        healthy with { Available = false }, healthy with { PoweredOn = false }, healthy with { Readable = false }
    }) {
        f.Wifi.State = wrong; await model.RefreshAsync();
        Assert(model.Notice == notice && model.NoticeIsError && model.Active is null);
    }
    f.Wifi.State = healthy; await model.RefreshAsync();
    Assert(model.Active?.AccountId == a.Id && model.Notice is null && !model.NoticeIsError && model.EditSuggested is null);
    Assert(f.Wifi.ConnectCalls == 0 && f.Wifi.ClaimCalls == 1);
});
Async("connection recovery clears only the matching status notice and preserves later errors", async () => {
    foreach (var mode in new[] { "unrelated", "other-account", "dismissed" }) {
        var f = new Fixture(); var a = f.Add("Group"); var other = f.Add("Other"); f.Remember(a);
        var model = f.Model(); await model.RefreshAsync();
        model.SetProblem(new ConnectionException("temporary claim status", recoverySelection: f.Selection(a)));
        if (mode == "unrelated") model.SetProblem(new IOException("save failed"));
        if (mode == "other-account") model.SetProblem(new ConnectionException("other claim status", recoverySelection: f.Selection(other)));
        if (mode == "dismissed") model.DismissNotice();
        var notice = model.Notice; await model.RefreshAsync();
        Assert(model.Active?.AccountId == a.Id && model.Notice == notice);
        Assert(model.NoticeIsError == (mode != "dismissed"));
    }
});
Async("claim permission and storage errors are not mistaken for recoverable network status", async () => {
    foreach (var denied in new[] { false, true }) {
        var f = new Fixture(); var a = f.Add("Group"); f.Remember(a); var healthy = f.Wifi.State;
        f.Wifi.State = healthy with { AccountId = null }; var model = f.Model(); await model.RefreshAsync();
        f.Wifi.ClaimResult = !denied; f.Storage.Fail = !denied;
        Exception? failure = null;
        try { await model.ClaimCurrentAsync(); } catch (Exception error) { failure = error; model.SetProblem(error); }
        Assert(failure is not null && (failure as ConnectionException)?.RecoverySelection is null);
        Assert(model.NoticeIsError && !model.Busy);
        var notice = model.Notice; f.Storage.Fail = false; f.Wifi.State = healthy;
        await model.RefreshAsync();
        Assert(model.Notice == notice && model.NoticeIsError);
    }
});
Async("cancelled or suspended claim releases busy state without reporting success", async () => {
    foreach (var suspend in new[] { false, true }) {
        var f = new Fixture(); var a = f.Add("Group"); f.Remember(a);
        f.Wifi.State = f.Wifi.State with { AccountId = null }; var model = f.Model(); await model.RefreshAsync();
        using var cts = new CancellationTokenSource(); var claim = model.ClaimCurrentAsync(cts.Token);
        Assert(model.Busy && model.Claiming);
        if (suspend) model.Suspend(); else cts.Cancel();
        try { await claim; throw new Exception("Expected cancellation"); } catch (OperationCanceledException) { }
        Assert(!model.Busy && !model.Claiming && model.Notice?.StartsWith("已认领") != true);
    }
});
Async("claim is refused when disconnected, on another network, without address, or unwritable", async () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Remember(a); var model = f.Model();
    foreach (var state in new[] {
        f.Wifi.State with { Ssid = null, ProfileName = null, HasAddress = false },
        f.Wifi.State with { Ssid = "Other" },
        f.Wifi.State with { HasAddress = false },
        f.Wifi.State with { InterfaceId = Guid.NewGuid() } })
    {
        f.Wifi.State = state; await model.RefreshAsync();
        Assert(!model.CanClaim);
        try { await model.ClaimCurrentAsync(); throw new Exception("claim should fail"); }
        catch (ConnectionException) { }
    }
    f.Wifi.State = f.Wifi.State with { InterfaceId = f.Wifi.AdapterId, AccountId = null };
    await model.RefreshAsync();
    Assert(model.CanClaim && f.Wifi.ConnectCalls == 0);
    f.Wifi.ClaimResult = false;
    try { await model.ClaimCurrentAsync(); throw new Exception("claim should fail"); }
    catch (ConnectionException) { }
    Assert(model.Active is null && f.Wifi.ClaimCalls == 1);
});
Async("system recovery cancels scheduled automatic reconnect", async () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Remember(a); var healthy = f.Wifi.State;
    f.Wifi.State = healthy with { HasAddress = false }; var model = f.Model(); await model.RefreshAsync();
    f.Wifi.State = healthy; f.Clock.Advance(11); await model.RefreshAsync();
    Assert(model.Active is not null && f.Wifi.ConnectCalls == 0);
});
Async("current credentials save reconnects only the active network", async () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Remember(a); var model = f.Model(); await model.RefreshAsync();
    await model.SaveAccountAsync(a with { Username = "updated" }, "updated-secret");
    Assert(f.Wifi.ConnectCalls == 1 && f.Wifi.LastUsername == "updated" && f.Wifi.LastPassword == "updated-secret");
    Assert(model.Active?.AccountId == a.Id);
});
Async("description and other account updates do not reconnect", async () => {
    var f = new Fixture(); var a = f.Add("Group"); var b = f.Add("Studio"); f.Remember(a);
    var model = f.Model(); await model.RefreshAsync();
    await model.SaveAccountAsync(a with { Label = "Updated" }, null);
    await model.SaveAccountAsync(b with { Username = "new" }, "new-secret");
    Assert(f.Wifi.ConnectCalls == 0 && model.Active?.AccountId == a.Id);
});
Async("persisted connection write failure does not report success", async () => {
    var f = new Fixture(); var a = f.Add("Group"); var model = f.Model(); await model.RefreshAsync();
    f.Wifi.AfterConnect = () => f.Storage.Fail = true;
    await model.ConnectAsync(a.Id, "Office");
    Assert(model.NoticeIsError && model.Active is null && model.Suspended);
});
Async("wrong final profile and no IP do not report success", async () => {
    foreach (var wrongProfile in new[] { true, false }) {
        var f = new Fixture(); var a = f.Add("Group"); var model = f.Model(); await model.RefreshAsync();
        f.Wifi.AfterConnect = () => f.Wifi.State = f.Wifi.State with { ProfileName = wrongProfile ? "wrong" : f.Wifi.State.ProfileName, HasAddress = false };
        await model.ConnectAsync(a.Id, "Office");
        Assert(model.Active is null && model.NoticeIsError);
    }
});
Test("authentication error codes distinguish rejection from timeout", () => {
    Assert(ProfileXml.IsCredentialFailure(0x50005));
    Assert(ProfileXml.IsCredentialFailure(0x2800D));
    Assert(!ProfileXml.IsCredentialFailure(0x48002));
    Assert(!ProfileXml.IsCredentialFailure(0x50006));
});
Test("EAP user credentials roundtrip XML escaping and domain", () => {
    var xml = XDocument.Parse(ProfileXml.PeapCredentials(@"CORP\a<&", "p<&\"'"));
    Assert(xml.Descendants().Single(e => e.Name.LocalName == "Username").Value == "a<&");
    Assert(xml.Descendants().Single(e => e.Name.LocalName == "LogonDomain").Value == "CORP");
    Assert(xml.Descendants().Single(e => e.Name.LocalName == "Password").Value == "p<&\"'");
});
Test("enterprise profile retains certificate validation and disables logon credentials", () => {
    var a = new Account { Username = "user" }; var n = new Network { Ssid = "公司<&", Authentication = Authentication.Enterprise, ServerNames = "radius.example.com" };
    var xml = ProfileXml.Build(a, n, new(n.Ssid, Authentication.Enterprise, 90, 6, 4), "synthetic-secret");
    var document = XDocument.Parse(xml);
    Assert(!xml.Contains("synthetic-secret"));
    Assert(document.Descendants().Single(e => e.Name.LocalName == "PerformServerValidation").Value == "true");
    Assert(document.Descendants().Single(e => e.Name.LocalName == "UseWinLogonCredentials").Value == "false");
    var cloned = XDocument.Parse(ProfileXml.EnterpriseFromTemplate(xml, "second-profile", n));
    Assert(cloned.Descendants().Single(e => e.Name.LocalName == "ServerNames").Value == "radius.example.com");
});
Test("compatible Windows enterprise configuration is retained byte for byte", () => {
    var n = new Network { Ssid = "Office", Authentication = Authentication.Enterprise };
    var xml = ProfileXml.Build(new() { Username = "user" }, n, new("Office", Authentication.Enterprise, 90, 6, 4), "secret");
    XNamespace w = ProfileXml.WlanNamespace;
    var document = XDocument.Parse(xml);
    document.Root!.Element(w + "connectionMode")!.Value = "auto";
    document.Root.Element(w + "connectionMode")!.AddAfterSelf(new XElement(w + "autoSwitch", true));
    // Include opaque Windows extension settings and certificate restrictions.
    document.Descendants().Single(e => e.Name.LocalName == "ServerNames").Value = "radius.example.test";
    document.Root.Add(new XElement(XName.Get("Policy", "urn:windows-extension"), "preserve-me"));
    xml = document.ToString();
    Assert(ProfileXml.EnterpriseFromTemplate(xml, "Office", n, true) == xml);
    // Manual joining must also retain its original mode.
    document.Root.Element(w + "connectionMode")!.Value = "manual";
    xml = document.ToString();
    Assert(ProfileXml.EnterpriseFromTemplate(xml, "Office", n, true) == xml);
});
Test("link identity alone cannot verify the submitted account", () => {
    var f = new Fixture(); var a = f.Add("Group"); var selection = f.Selection(a);
    var state = new Snapshot(f.Wifi.AdapterId, true, true, "Office", "Office", true);
    Assert(Rules.SameConnection(selection, state));
    Assert(Rules.SameConnection(selection, state with { AccountId = null }));
    Assert(!Rules.Matches(selection, state with { AccountId = null }));
    Assert(!Rules.SameConnection(selection, state with { Ssid = "Other" }));
    Assert(!Rules.SameConnection(selection, state with { InterfaceId = Guid.NewGuid() }));
    Assert(!Rules.SameConnection(selection, state with { Readable = false }));
    Assert(!Rules.SameConnection(selection, state with { ProfileName = "other" }));
});
Async("connection verification waits through consent and DHCP transitions for three healthy account samples", async () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Remember(a); var healthy = f.Wifi.State;
    var samples = new Queue<Snapshot>([
        healthy with { Ssid = null, ProfileName = null, HasAddress = false },
        healthy with { HasAddress = false }, healthy, healthy,
        healthy with { HasAddress = false }, healthy, healthy, healthy
    ]);
    Assert(await ConnectionVerification.WaitAsync(f.Selection(a), () => samples.Dequeue(),
        TimeSpan.FromSeconds(1), TimeSpan.FromMilliseconds(1)));
    Assert(samples.Count == 0);
});
Async("prepared marker, wrong account and unavailable link cannot pass connection verification", async () => {
    var f = new Fixture(); var a = f.Add("Group"); f.Remember(a); var healthy = f.Wifi.State;
    foreach (var state in new[] {
        healthy with { HasAddress = false }, healthy with { AccountId = null },
        healthy with { AccountId = Guid.NewGuid() }, healthy with { ProfileName = "other" },
        healthy with { InterfaceId = Guid.NewGuid() }, healthy with { Ssid = "Other" },
        healthy with { Available = false }, healthy with { PoweredOn = false }, healthy with { Readable = false }
    }) Assert(!await ConnectionVerification.WaitAsync(f.Selection(a), () => state,
        TimeSpan.FromMilliseconds(5), TimeSpan.FromMilliseconds(1)));
    using var cts = new CancellationTokenSource(); cts.Cancel();
    try {
        await ConnectionVerification.WaitAsync(f.Selection(a), () => healthy,
            TimeSpan.FromSeconds(1), TimeSpan.FromMilliseconds(1), cts.Token);
        throw new Exception("Cancellation ignored");
    } catch (OperationCanceledException) { }
});
Test("preserved enterprise profiles switch to auto joining before connecting", () => {
    XNamespace w = ProfileXml.WlanNamespace;
    var n = new Network { Ssid = "Office", Authentication = Authentication.Enterprise, ServerNames = "radius.example.test" };
    var manual = ProfileXml.Build(new() { Username = "user" }, n, new("Office", Authentication.Enterprise, 90, 6, 4), "secret");
    Assert(XDocument.Parse(manual).Root!.Element(w + "connectionMode")!.Value == "manual");
    var auto = ProfileXml.WithAutoJoin(manual);
    Assert(XDocument.Parse(auto).Root!.Element(w + "connectionMode")!.Value == "auto");
    Assert(XDocument.Parse(auto).Descendants().Single(e => e.Name.LocalName == "ServerNames").Value == "radius.example.test");
    Assert(ProfileXml.WithAutoJoin(auto) == auto);
});
Test("explicit credential compatibility changes retain trust settings and joining policy", () => {
    var n = new Network { Ssid = "Office", Authentication = Authentication.Enterprise,
        RootCertificateThumbprint = new string('A', 40), ServerNames = "radius.example.test" };
    var document = XDocument.Parse(ProfileXml.Build(new() { Username = "user" }, n,
        new("Office", Authentication.Enterprise, 90, 6, 4), "secret"));
    document.Descendants().Single(e => e.Name.LocalName == "authMode").Value = "machineOrUser";
    document.Descendants().Single(e => e.Name.LocalName == "FastReconnect").Value = "true";
    document.Descendants().Single(e => e.Name.LocalName == "UseWinLogonCredentials").Value = "true";
    var trustBefore = document.Descendants().Single(e => e.Name.LocalName == "ServerValidation").ToString();
    var updated = XDocument.Parse(ProfileXml.EnterpriseFromTemplate(document.ToString(), "Office", n, true));
    Assert(updated.Descendants().Single(e => e.Name.LocalName == "ServerValidation").ToString() == trustBefore);
    Assert(updated.Descendants().Single(e => e.Name.LocalName == "connectionMode").Value == "manual");
    Assert(updated.Descendants().Single(e => e.Name.LocalName == "authMode").Value == "user");
    Assert(updated.Descendants().Single(e => e.Name.LocalName == "FastReconnect").Value == "false");
    Assert(updated.Descendants().Single(e => e.Name.LocalName == "UseWinLogonCredentials").Value == "false");
    // The second connection must not cause another profile write.
    var xml = updated.ToString();
    Assert(ProfileXml.EnterpriseFromTemplate(xml, "Office", n, true) == xml);
});
Test("existing SSO and unsupported enterprise methods are rejected without rewriting configuration", () => {
    var n = new Network { Ssid = "Office", Authentication = Authentication.Enterprise };
    var doc = XDocument.Parse(ProfileXml.Build(new() { Username = "user" }, n,
        new("Office", Authentication.Enterprise, 90, 6, 4), "secret"));
    XNamespace one = "http://www.microsoft.com/networking/OneX/v1";
    doc.Descendants(one + "OneX").Single().Add(new XElement(one + "singleSignOn"));
    Throws(() => ProfileXml.EnterpriseFromTemplate(doc.ToString(), "Office", n, true));
    doc.Descendants(one + "singleSignOn").Remove();
    doc.Descendants().First(e => e.Name.LocalName == "Type").Value = "13";
    Throws(() => ProfileXml.EnterpriseFromTemplate(doc.ToString(), "Office", n, true));
});
Async("cancelled authentication can confirm disconnection without a disconnected notification", async () => {
    var states = new Queue<uint?>([7, 3, 4, 4]);
    Assert(await DisconnectConfirmation.WaitAsync(() => states.Dequeue(), TimeSpan.FromSeconds(1), TimeSpan.FromMilliseconds(1)));
    Assert(states.Count == 0);
});
Async("disconnection confirmation resets after another connection and rejects unknown or authenticating states", async () => {
    foreach (uint? state in new uint?[] { null, 0, 1, 3, 5, 6, 7 })
        Assert(!await DisconnectConfirmation.WaitAsync(() => state, TimeSpan.FromMilliseconds(5), TimeSpan.FromMilliseconds(1)));
    var states = new Queue<uint?>([4, 1, 4, 4]);
    Assert(await DisconnectConfirmation.WaitAsync(() => states.Dequeue(), TimeSpan.FromSeconds(1), TimeSpan.FromMilliseconds(1)));
    Assert(states.Count == 0);
    using var cts = new CancellationTokenSource(); cts.Cancel();
    try {
        await DisconnectConfirmation.WaitAsync(() => 4, TimeSpan.FromSeconds(1), TimeSpan.FromMilliseconds(1), cts.Token);
        throw new Exception("Cancellation ignored");
    } catch (OperationCanceledException) { }
});
Test("open network does not embed credentials", () => {
    var n = new Network { Ssid = "Guest", Authentication = Authentication.Open };
    var xml = ProfileXml.Build(new() { Username = "should-not-send" }, n, new("Guest", Authentication.Open, 40, 1, 0), "secret");
    Assert(!xml.Contains("secret") && !xml.Contains("should-not-send") && !xml.Contains("sharedKey"));
});
Test("WPA2 personal XML contains escaped password only in memory", () => {
    var n = new Network { Ssid = "Phone", Authentication = Authentication.Personal };
    var xml = XDocument.Parse(ProfileXml.Build(new(), n, new("Phone", Authentication.Personal, 70, 7, 4), "password<&"));
    Assert(xml.Descendants().Single(e => e.Name.LocalName == "keyMaterial").Value == "password<&");
});
Test("real temporary JSON survives reconstruction and malformed data is not erased", () => {
    var directory = Path.Combine(Path.GetTempPath(), "WiFiSwitchTest-" + Guid.NewGuid());
    var path = Path.Combine(directory, "accounts.json");
    try {
        var storage = new JsonStorage(path); var repo = new Repository(storage, new Vault());
        repo.SaveAccount(new() { Label = "Saved" }, "synthetic-secret");
        Assert(new Repository(new JsonStorage(path), new Vault()).Configuration.Accounts.Single().Label == "Saved");
        File.WriteAllText(path, "invalid"); Throws(() => new Repository(new JsonStorage(path), new Vault()));
        Assert(File.ReadAllText(path) == "invalid");
    } finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
});

int failures = 0;
foreach (var test in cases)
{
    try { await test.Test(); Console.WriteLine("PASS " + test.Name); }
    catch (Exception error) { failures++; Console.WriteLine("FAIL " + test.Name + ": " + error); }
}
Console.WriteLine($"{cases.Count - failures}/{cases.Count} passed");
return failures == 0 ? 0 : 1;

sealed class Storage : IConfigurationStorage
{
    public bool Fail;
    private Configuration value = new();
    public Configuration Load() => value;
    public void Save(Configuration next) { if (Fail) throw new IOException("synthetic write failure"); value = next; }
}
sealed class Vault : ICredentialVault
{
    private readonly Dictionary<Guid, string> values = [];
    public int Reads;
    public string? Read(Guid id) { Reads++; return values.GetValueOrDefault(id); }
    public void Write(Guid id, string password) => values[id] = password;
    public void Delete(Guid id) => values.Remove(id);
}
sealed class Clock : TimeProvider
{
    private DateTimeOffset now = DateTimeOffset.Parse("2026-10-20T00:00:00Z");
    public override DateTimeOffset GetUtcNow() => now;
    public void Advance(int seconds) => now = now.AddSeconds(seconds);
}
sealed class Wifi : IWiFiService
{
    public readonly Guid AdapterId = Guid.NewGuid();
    public Snapshot State;
    public Exception? Error;
    public Action? AfterConnect;
    public Action? AfterClaim;
    public Queue<Snapshot>? Snapshots;
    public Task? ConnectWait;
    public int ConnectCalls, ClaimCalls;
    public bool ClaimResult = true;
    public string? LastUsername, LastPassword;
    public Wifi() => State = new(AdapterId, true, true, "Office", "system", true);
    public Task<IReadOnlyList<Adapter>> AdaptersAsync() => Task.FromResult<IReadOnlyList<Adapter>>([new(AdapterId, "Test")]);
    public Task<Snapshot> SnapshotAsync(Guid? adapter, CancellationToken token = default)
        => Task.FromResult(Snapshots is { Count: > 0 } ? Snapshots.Dequeue() : State);
    public Task<IReadOnlyList<NearbyNetwork>> ScanAsync(Guid adapter, CancellationToken token = default)
        => Task.FromResult<IReadOnlyList<NearbyNetwork>>([new("Office", Authentication.Enterprise, 90, 6, 4)]);
    public async Task ConnectAsync(Guid adapter, Account account, Network network, string password, bool automatic,
        Action<string> progress, CancellationToken token = default)
    {
        ConnectCalls++; LastUsername = account.Username; LastPassword = password;
        if (ConnectWait is not null) await ConnectWait.WaitAsync(token);
        if (Error is not null) throw Error;
        State = new(adapter, true, true, network.Ssid, Rules.ProfileName(account.Id, network.Ssid), true, AccountId: account.Id);
        AfterConnect?.Invoke();
    }
    public Task<bool> ClaimConnectionAsync(Guid adapter, string profile, Guid accountId)
    {
        ClaimCalls++;
        if (!ClaimResult) return Task.FromResult(false);
        State = State with { AccountId = accountId };
        AfterClaim?.Invoke();
        return Task.FromResult(true);
    }
    public void Dispose() { }
}
sealed class Fixture
{
    public readonly Storage Storage = new();
    public readonly Vault Vault = new();
    public readonly Wifi Wifi = new();
    public readonly Clock Clock = new();
    public readonly Repository Repo;
    public Fixture() => Repo = new(Storage, Vault);
    public Account Add(string label)
    {
        var account = new Account { Label = label, Username = label, Networks = [new() { Ssid = "Office", Authentication = Authentication.Enterprise }] };
        Repo.SaveAccount(account, "synthetic-secret");
        return Repo.Configuration.Accounts.Single(a => a.Id == account.Id);
    }
    public Selection Selection(Account account) => new(account.Id, "Office", Wifi.AdapterId, Rules.ProfileName(account.Id, "Office"));
    public void Remember(Account account)
    {
        Repo.Remember(Selection(account), true);
        Wifi.State = Wifi.State with { ProfileName = Rules.ProfileName(account.Id, "Office"), AccountId = account.Id };
    }
    public Controller Model() => new(Repo, Wifi, Clock);
}
