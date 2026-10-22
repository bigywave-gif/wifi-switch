using System.Text;
using System.Xml.Linq;

namespace WiFiSwitch.Core;

public static class ProfilePolicy
{
    private const string MarkerPrefix = "WiFiSwitch.Account.v1:";
    public static byte[] AccountMarker(Guid id) => Encoding.UTF8.GetBytes(MarkerPrefix + id.ToString("D"));
    public static Guid? ReadAccountMarker(byte[] data)
    {
        var value = Encoding.UTF8.GetString(data);
        return value.StartsWith(MarkerPrefix, StringComparison.Ordinal) &&
            Guid.TryParseExact(value[MarkerPrefix.Length..], "D", out var id) ? id : null;
    }

    public static string Ssid(string xml)
    {
        XNamespace w = ProfileXml.WlanNamespace;
        var ssid = XDocument.Parse(xml).Root?.Element(w + "SSIDConfig")?.Element(w + "SSID")
            ?? throw new InvalidDataException("Windows 网络配置缺少 SSID。");
        var hex = ssid.Element(w + "hex")?.Value;
        return hex is not null ? new UTF8Encoding(false, true).GetString(Convert.FromHexString(hex))
            : ssid.Element(w + "name")?.Value ?? throw new InvalidDataException("Windows 网络配置缺少 SSID。");
    }

    // Per-user profiles (0x2) live only in the creating logon session: an elevated
    // process of the same user cannot see them, rewrites them blindly, and a
    // connection established from them is cancelled by Windows. New profiles are
    // therefore created all-user, matching what the Windows Wi-Fi menu itself does.
    public const uint DefaultFlags = 0;
    public static uint WriteFlags(string? existingXml, uint existingFlags, uint access, string targetSsid)
        => existingXml is null ? DefaultFlags : ReuseFlags(existingXml, targetSsid, existingFlags, access);

    public static uint ReuseFlags(string xml, string targetSsid, uint flags, uint access)
    {
        if (Ssid(xml) != targetSsid)
            throw new ConnectionException("同名系统配置指向其他 Wi-Fi，已停止连接，未覆盖该配置。", diagnosticCode: "profile_ssid_conflict");
        if ((flags & 1) != 0)
            throw new ConnectionException("此 Wi-Fi 配置由公司策略管理，无法直接替换账号凭据。请联系管理员。", diagnosticCode: "profile_group_policy");
        const uint writeAccess = 0x00070023; // WLAN_WRITE_ACCESS from the Windows SDK
        if ((access & writeAccess) != writeAccess)
            throw new ConnectionException("当前用户不能修改此 Wi-Fi 配置，已在断网前停止。请让管理员授予该配置的修改权限。", diagnosticCode: "profile_write_access_denied");
        return flags & 2; // Preserve all-user/per-user scope instead of creating a shadow copy.
    }

    public static bool CanDeleteLegacy(string name, string xml, uint flags, Snapshot state, bool interfaceIdle)
        => (flags & 2) != 0 && (flags & 1) == 0 && state.Available && state.Readable && interfaceIdle &&
            state.ProfileName != name && Rules.IsLegacyProfile(name, Ssid(xml));
}
