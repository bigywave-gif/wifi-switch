using System.Text.Json;

namespace WiFiSwitch.Core;

public sealed class JsonStorage(string path) : IConfigurationStorage
{
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };
    public Configuration Load()
    {
        if (!File.Exists(path)) return new();
        var config = JsonSerializer.Deserialize<Configuration>(File.ReadAllText(path), Options)
            ?? throw new InvalidDataException("账号文件为空。");
        Rules.Validate(config);
        return config;
    }

    public void Save(Configuration configuration)
    {
        Rules.Validate(configuration);
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, configuration, Options);
                stream.Flush(true);
            }
            // Replace atomically on the same volume. Keep a recoverable last version.
            if (File.Exists(path)) File.Replace(temporary, path, path + ".backup");
            else File.Move(temporary, path);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}

public sealed class Repository
{
    private readonly IConfigurationStorage storage;
    private readonly ICredentialVault vault;
    public Configuration Configuration { get; private set; }
    public Repository(IConfigurationStorage storage, ICredentialVault vault)
    {
        this.storage = storage; this.vault = vault;
        Configuration = storage.Load();
        Rules.Validate(Configuration);
    }

    public void Commit(Configuration next)
    {
        Rules.Validate(next);
        storage.Save(next);
        Configuration = next;
    }

    public string Password(Account account)
        => !account.HasPassword ? "" : vault.Read(account.Id)
            ?? throw new ConnectionException("找不到此账号保存的密码，请修改账号。", true, diagnosticCode: "credential_missing");

    // Returns true only for a credential change to an existing account.
    public bool SaveAccount(Account input, string? newPassword)
    {
        foreach (var network in input.Networks) Rules.ValidateSsid(network.Ssid);
        if (Rules.RequiresUsername(input.Networks) && string.IsNullOrWhiteSpace(input.Username))
            throw new ArgumentException("企业 Wi-Fi 必须填写用户名。");
        var previous = Configuration.Accounts.FirstOrDefault(a => a.Id == input.Id);
        var hasPassword = !string.IsNullOrEmpty(newPassword) || previous?.HasPassword == true;
        if (Rules.RequiresPassword(input.Networks) && !hasPassword)
            throw new ArgumentException("请填写密码。");
        // Reading the old secret is needed only when replacing it, for transactional rollback.
        var oldPassword = newPassword is not null && previous?.HasPassword == true ? vault.Read(previous.Id) : null;
        var secretChanged = newPassword is not null && newPassword != oldPassword;
        var credentialChanged = previous is not null && (input.Username != previous.Username || secretChanged);
        var saved = input with { HasPassword = hasPassword };
        var accounts = Configuration.Accounts.Select(a => a.Id == saved.Id ? saved : a).ToList();
        if (previous is null) accounts.Add(saved);
        var current = Configuration.Current;
        if (current?.AccountId == saved.Id &&
            (credentialChanged || !saved.Networks.Any(n => n.Ssid == current.Ssid))) current = null;
        var next = Configuration with { Accounts = accounts, Current = current,
            Failure = current == Configuration.Current ? Configuration.Failure : null };
        Rules.Validate(next);
        if (secretChanged) vault.Write(saved.Id, newPassword!);
        try { Commit(next); }
        catch
        {
            if (secretChanged)
            {
                try { if (oldPassword is null) vault.Delete(saved.Id); else vault.Write(saved.Id, oldPassword); }
                catch { throw new IOException("保存失败且密码回滚失败，请重新编辑此账号。"); }
            }
            throw;
        }
        return credentialChanged;
    }

    public void RemoveNetwork(Guid accountId, string ssid)
    {
        var accounts = Configuration.Accounts.Select(a => a.Id == accountId
            ? a with { Networks = a.Networks.Where(n => n.Ssid != ssid).ToList() } : a).ToList();
        var current = Configuration.Current;
        if (current?.AccountId == accountId && current.Ssid == ssid) current = null;
        Commit(Configuration with { Accounts = accounts, Current = current,
            Failure = current == Configuration.Current ? Configuration.Failure : null });
    }

    public void DeleteAccount(Guid accountId)
    {
        var account = Configuration.Accounts.Single(a => a.Id == accountId);
        var password = account.HasPassword ? vault.Read(account.Id) : null;
        vault.Delete(accountId);
        var current = Configuration.Current?.AccountId == accountId ? null : Configuration.Current;
        try { Commit(Configuration with { Accounts = Configuration.Accounts.Where(a => a.Id != accountId).ToList(),
            Current = current, Failure = current == Configuration.Current ? Configuration.Failure : null }); }
        catch
        {
            if (password is not null) vault.Write(accountId, password);
            throw;
        }
    }

    public void Remember(Selection selection, bool userInitiated)
        => Commit(Configuration with { Current = selection, Failure = null,
            Accounts = Configuration.Accounts.Select(a => userInitiated && a.Id == selection.AccountId
                ? a with { LastConnectedAt = DateTimeOffset.UtcNow } : a).ToList() });

    public void ClearCurrent() => Commit(Configuration with { Current = null, Failure = null });
}
