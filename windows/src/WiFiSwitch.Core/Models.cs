using System.Text;
using System.Text.Json.Serialization;
using System.Security.Cryptography;

namespace WiFiSwitch.Core;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum Authentication { Unknown, Open, Personal, Enterprise }

public sealed record Network
{
    public string Ssid { get; init; } = "";
    public Authentication Authentication { get; init; }
    public bool Hidden { get; init; }
    // Optional explicit PEAP trust configuration. Existing Windows profile takes precedence.
    public string ServerNames { get; init; } = "";
    public string RootCertificateThumbprint { get; init; } = "";
}

public sealed record Account
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Label { get; init; } = "";
    public string Username { get; init; } = "";
    public bool HasPassword { get; init; }
    public List<Network> Networks { get; init; } = [];
    public DateTimeOffset? LastConnectedAt { get; init; }
    [JsonIgnore] public string DisplayName => string.IsNullOrWhiteSpace(Label) ? "未命名账号" : Label;
}

public sealed record Selection(Guid AccountId, string Ssid, Guid InterfaceId, string ProfileName);
public sealed record RetryFailure(Selection Selection, int Count, string Message, bool CredentialsRejected);
public sealed record Configuration
{
    public int Version { get; init; } = 1;
    public List<Account> Accounts { get; init; } = [];
    public Selection? Current { get; init; }
    public RetryFailure? Failure { get; init; }
    public Guid? PreferredInterface { get; init; }
}

public sealed record Adapter(Guid Id, string Name);
public sealed record NearbyNetwork(string Ssid, Authentication Authentication, uint Signal, uint AuthAlgorithm, uint CipherAlgorithm);
public sealed record Snapshot(Guid InterfaceId, bool Available, bool PoweredOn, string? Ssid, string? ProfileName, bool HasAddress,
    bool Readable = true, string? Problem = null, Guid? AccountId = null);

public sealed class ConnectionException(string message, bool credentialsRejected = false, uint? reason = null,
    string? diagnosticCode = null, Selection? recoverySelection = null)
    : Exception(message)
{
    public bool CredentialsRejected { get; } = credentialsRejected;
    public uint? Reason { get; } = reason;
    public string? DiagnosticCode { get; } = diagnosticCode;
    // Only status-verification failures may disappear when this exact link recovers.
    public Selection? RecoverySelection { get; } = recoverySelection;
}

public interface ICredentialVault
{
    string? Read(Guid accountId);
    void Write(Guid accountId, string password);
    void Delete(Guid accountId);
}

public interface IConfigurationStorage
{
    Configuration Load();
    void Save(Configuration configuration);
}

public interface IWiFiService : IDisposable
{
    string? ConnectionWarning => null;
    Task<string?> CleanupLegacyProfilesAsync() => Task.FromResult<string?>(null);
    // Adopt a connection Windows established outside this app by writing the
    // account marker onto the active profile. Returns false when the profile is
    // not writable from this session (for example it belongs to another logon session).
    Task<bool> ClaimConnectionAsync(Guid adapter, string profile, Guid accountId) => Task.FromResult(false);
    Task<IReadOnlyList<Adapter>> AdaptersAsync();
    Task<Snapshot> SnapshotAsync(Guid? adapter, CancellationToken token = default);
    Task<IReadOnlyList<NearbyNetwork>> ScanAsync(Guid adapter, CancellationToken token = default);
    Task ConnectAsync(Guid adapter, Account account, Network network, string password, bool automatic,
        Action<string> progress, CancellationToken token = default);
}

public static class Rules
{
    public static string ProfileName(Guid accountId, string ssid)
        => ssid;

    // Read-only compatibility with releases before 0.1.2. Never create this name again.
    public static string LegacyProfileName(Guid accountId, string ssid)
        => $"WiFiSwitch-{accountId:N}-{Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(ssid)))[..16]}";

    public static bool IsLegacyProfile(string name, string ssid)
        => name.Length == 60 && name.StartsWith("WiFiSwitch-", StringComparison.Ordinal) &&
            Guid.TryParseExact(name.Substring(11, 32), "N", out var id) &&
            name == LegacyProfileName(id, ssid);

    public static void ValidateSsid(string ssid)
    {
        if (string.IsNullOrWhiteSpace(ssid) || ssid.Contains('\0') || Encoding.UTF8.GetByteCount(ssid) > 32)
            throw new ArgumentException("Wi-Fi 名称不能为空，且最多为 32 个 UTF-8 字节。");
    }

    public static bool RequiresUsername(IEnumerable<Network> networks)
        => networks.Any(n => n.Authentication == Authentication.Enterprise);
    public static bool RequiresPassword(IEnumerable<Network> networks)
    {
        var list = networks.ToList();
        return list.Count == 0 || list.Any(n => n.Authentication != Authentication.Open);
    }

    public static void Validate(Configuration config)
    {
        if (config.Version != 1 || config.Accounts.Select(a => a.Id).Distinct().Count() != config.Accounts.Count)
            throw new InvalidDataException("账号文件版本或格式不正确，已停止写入。");
        foreach (var account in config.Accounts)
        {
            if (account.Networks.Select(n => n.Ssid).Distinct(StringComparer.Ordinal).Count() != account.Networks.Count)
                throw new InvalidDataException("同一账号不能重复关联相同的 Wi-Fi。");
            foreach (var network in account.Networks) ValidateSsid(network.Ssid);
        }
        if (config.Current is { } current && !ValidSelection(config, current))
            throw new InvalidDataException("连接记录指向不存在的账号或 Wi-Fi。");
        if (config.Failure is { } failure &&
            (failure.Selection != config.Current || failure.Count is < 1 or > 3))
            throw new InvalidDataException("自动重连记录格式不正确。");
    }

    public static bool ValidSelection(Configuration config, Selection selection)
        => config.Accounts.Any(a => a.Id == selection.AccountId && a.Networks.Any(n => n.Ssid == selection.Ssid))
            && (selection.ProfileName == ProfileName(selection.AccountId, selection.Ssid) ||
                selection.ProfileName == LegacyProfileName(selection.AccountId, selection.Ssid));

    // Shared visible profile; the account is tracked in opaque per-user profile data,
    // never in a network display name. Legacy selections remain readable until reconnect.
    public static bool Matches(Selection selection, Snapshot state)
        => SameConnection(selection, state) &&
            (selection.ProfileName == LegacyProfileName(selection.AccountId, selection.Ssid) ||
                state.AccountId == selection.AccountId);

    // Link identity alone does not prove which account's credentials were submitted.
    public static bool SameConnection(Selection selection, Snapshot state)
        => state.Available && state.PoweredOn && state.Readable && state.InterfaceId == selection.InterfaceId
            && state.Ssid == selection.Ssid && state.ProfileName == selection.ProfileName;
}
