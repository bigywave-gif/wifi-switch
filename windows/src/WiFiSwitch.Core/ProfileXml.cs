using System.Text;
using System.Xml.Linq;

namespace WiFiSwitch.Core;

public static class ProfileXml
{
    public const string WlanNamespace = "http://www.microsoft.com/networking/WLAN/profile/v1";
    private static readonly XNamespace W = WlanNamespace;
    private static readonly XNamespace OneX = "http://www.microsoft.com/networking/OneX/v1";
    private static readonly XNamespace Host = "http://www.microsoft.com/provisioning/EapHostConfig";
    private static readonly XNamespace Common = "http://www.microsoft.com/provisioning/EapCommon";
    private static readonly XNamespace Base = "http://www.microsoft.com/provisioning/BaseEapConnectionPropertiesV1";
    private static readonly XNamespace Peap = "http://www.microsoft.com/provisioning/MsPeapConnectionPropertiesV1";
    private static readonly XNamespace Chap = "http://www.microsoft.com/provisioning/MsChapV2ConnectionPropertiesV1";

    public static Authentication Classify(uint auth, bool securityEnabled) => auth switch
    {
        3 or 5 or 6 or 8 or 11 => Authentication.Enterprise,
        4 or 7 or 9 or 2 => Authentication.Personal,
        1 => securityEnabled ? Authentication.Personal : Authentication.Open,
        10 => Authentication.Open,
        _ => Authentication.Unknown
    };

    public static string Build(Account account, Network network, NearbyNetwork detected, string password, string? enterpriseTemplate = null)
    {
        Rules.ValidateSsid(network.Ssid);
        if (detected.Authentication == Authentication.Unknown)
            throw new ConnectionException("无法识别此 Wi-Fi 的认证方式，未断开现有连接。");
        if (detected.Authentication == Authentication.Enterprise && string.IsNullOrWhiteSpace(account.Username))
            throw new ConnectionException("企业 Wi-Fi 需要用户名，请修改账号。", true);
        if (detected.Authentication != Authentication.Open && string.IsNullOrEmpty(password))
            throw new ConnectionException("此 Wi-Fi 需要密码，请修改账号。", true);
        var profileName = Rules.ProfileName(account.Id, network.Ssid);
        if (enterpriseTemplate is not null && detected.Authentication == Authentication.Enterprise)
            return EnterpriseFromTemplate(enterpriseTemplate, profileName, network);
        string authentication = detected.AuthAlgorithm switch
        {
            1 => "open", 2 => "shared", 3 => "WPA", 4 => "WPAPSK", 6 => "WPA2",
            7 => "WPA2PSK", 9 => "WPA3SAE", 10 => "OWE", 11 => "WPA3ENT",
            _ => throw new ConnectionException("此认证方式需要先在 Windows 中配置网络，再从本工具连接。")
        };
        string encryption = detected.CipherAlgorithm switch
        {
            0 => "none", 1 or 5 or 257 => "WEP", 2 => "TKIP", 4 => "AES",
            8 => "GCMP", 9 => "GCMP256", _ => throw new ConnectionException("暂不支持此网络的加密算法。")
        };
        var enterprise = detected.Authentication == Authentication.Enterprise;
        var security = new XElement(W + "security",
            new XElement(W + "authEncryption", new XElement(W + "authentication", authentication),
                new XElement(W + "encryption", encryption), new XElement(W + "useOneX", enterprise)));
        if (detected.Authentication == Authentication.Personal)
        {
            var wep = encryption == "WEP";
            var rawPsk = password.Length == 64 && password.All(Uri.IsHexDigit);
            var key = password;
            if (wep)
            {
                if (password.Length is 5 or 13 && password.All(c => c <= 127))
                    key = Convert.ToHexString(Encoding.ASCII.GetBytes(password));
                else if (password.Length is not (10 or 26) || !password.All(Uri.IsHexDigit))
                    throw new ConnectionException("WEP 密码须为 5/13 位 ASCII 字符或 10/26 位十六进制密钥。", true);
            }
            else if ((!rawPsk && (password.Length < 8 || Encoding.UTF8.GetByteCount(password) > 63)) ||
                (detected.AuthAlgorithm == 9 && rawPsk))
                throw new ConnectionException("Wi-Fi 密码需为 8–63 字节；WPA/WPA2 也可使用 64 位十六进制密钥。", true);
            security.Add(new XElement(W + "sharedKey",
                new XElement(W + "keyType", wep || rawPsk ? "networkKey" : "passPhrase"),
                new XElement(W + "protected", false), new XElement(W + "keyMaterial", key)));
            if (wep) security.Add(new XElement(W + "keyIndex", 0));
        }
        if (enterprise) security.Add(CreatePeap(network));
        var root = new XElement(W + "WLANProfile", new XElement(W + "name", profileName),
            new XElement(W + "SSIDConfig", new XElement(W + "SSID",
                new XElement(W + "hex", Convert.ToHexString(Encoding.UTF8.GetBytes(network.Ssid))),
                new XElement(W + "name", network.Ssid)), new XElement(W + "nonBroadcast", network.Hidden)),
            new XElement(W + "connectionType", "ESS"), new XElement(W + "connectionMode", "manual"),
            new XElement(W + "MSM", security));
        return new XDocument(root).ToString(SaveOptions.DisableFormatting);
    }

    private static XElement CreatePeap(Network network)
    {
        var validation = new XElement(Peap + "ServerValidation",
            new XElement(Peap + "DisableUserPromptForServerValidation", false),
            new XElement(Peap + "ServerNames", network.ServerNames));
        if (!string.IsNullOrWhiteSpace(network.RootCertificateThumbprint))
        {
            var thumbprint = network.RootCertificateThumbprint.Replace(" ", "", StringComparison.Ordinal);
            if (thumbprint.Length != 40 || !thumbprint.All(Uri.IsHexDigit))
                throw new ArgumentException("根证书指纹应为 40 位 SHA-1 十六进制值。");
            validation.Add(new XElement(Peap + "TrustedRootCA", thumbprint));
        }
        return new XElement(OneX + "OneX", new XElement(OneX + "cacheUserData", true),
            new XElement(OneX + "authMode", "user"),
            new XElement(OneX + "EAPConfig", new XElement(Host + "EapHostConfig",
                new XElement(Host + "EapMethod", new XElement(Common + "Type", 25), new XElement(Common + "AuthorId", 0)),
                new XElement(Host + "Config", new XElement(Base + "Eap", new XElement(Base + "Type", 25),
                    new XElement(Peap + "EapType", validation, new XElement(Peap + "FastReconnect", false),
                        new XElement(Peap + "InnerEapOptional", false),
                        new XElement(Base + "Eap", new XElement(Base + "Type", 26),
                            new XElement(Chap + "EapType", new XElement(Chap + "UseWinLogonCredentials", false))),
                        new XElement(Peap + "EnableQuarantineChecks", false),
                        new XElement(Peap + "RequireCryptoBinding", false),
                        new XElement(Peap + "PeapExtensions",
                            new XElement(XName.Get("PerformServerValidation", "http://www.microsoft.com/provisioning/MsPeapConnectionPropertiesV2"), true),
                            new XElement(XName.Get("AcceptServerName", "http://www.microsoft.com/provisioning/MsPeapConnectionPropertiesV2"), true))))))));
    }

    public static string EnterpriseFromTemplate(string xml, string profileName, Network network,
        bool preserveConnectionSettings = false)
    {
        var doc = XDocument.Parse(xml);
        var root = doc.Root ?? throw new InvalidDataException("Windows Wi-Fi 配置为空。");
        var method = root.Descendants(Host + "EapMethod").SingleOrDefault();
        if (method?.Element(Common + "Type")?.Value != "25" ||
            !root.Descendants(Base + "Type").Any(e => e.Value == "26"))
            throw new ConnectionException("此企业网络不是 PEAP/MSCHAPv2 用户名密码认证；请使用 Windows 网络设置或联系管理员。",
                diagnosticCode: "unsupported_eap_method");
        // Preserve all certificate trust and server identity constraints from Windows.
        root.SetElementValue(W + "name", profileName);
        if (!preserveConnectionSettings)
        {
            root.SetElementValue(W + "connectionMode", "manual");
            root.Element(W + "autoSwitch")?.Remove();
            root.Descendants(OneX + "singleSignOn").Remove();
        }
        else if (root.Descendants(OneX + "singleSignOn").Any())
            throw new ConnectionException("此系统配置启用了单点登录，不能直接替换为所选账号。请先由管理员配置独立的用户认证方式。",
                diagnosticCode: "profile_single_sign_on");
        var one = root.Descendants(OneX + "OneX").Single();
        one.Element(OneX + "authMode")?.Remove();
        one.Element(OneX + "cacheUserData")?.Remove();
        var eap = one.Element(OneX + "EAPConfig")!;
        eap.AddBeforeSelf(new XElement(OneX + "cacheUserData", true), new XElement(OneX + "authMode", "user"));
        foreach (var logon in root.Descendants(Chap + "UseWinLogonCredentials")) logon.Value = "false";
        foreach (var reconnect in root.Descendants(Peap + "FastReconnect")) reconnect.Value = "false";
        // Retain actual SSID and reject accidentally cloning another network.
        var ssidHex = root.Element(W + "SSIDConfig")?.Element(W + "SSID")?.Element(W + "hex")?.Value;
        var ssidName = root.Element(W + "SSIDConfig")?.Element(W + "SSID")?.Element(W + "name")?.Value;
        if (ssidHex is not null ? !ssidHex.Equals(Convert.ToHexString(Encoding.UTF8.GetBytes(network.Ssid)), StringComparison.OrdinalIgnoreCase)
            : ssidName != network.Ssid) throw new InvalidDataException("企业网络配置的 SSID 不匹配。");
        // Avoid WlanSetProfile entirely when the existing configuration already
        // accepts explicit credentials. Even a logically identical write can reset
        // Windows' per-profile state. Preserve the original bytes in that case.
        return preserveConnectionSettings && XNode.DeepEquals(XDocument.Parse(xml), doc)
            ? xml : doc.ToString(SaveOptions.DisableFormatting);
    }

    // A profile that joins manually cannot win WLAN AutoConfig's post-disconnect
    // auto-connect: another automatic profile in range grabs the adapter and tears
    // down the fresh session. Flip the template to auto joining in place.
    public static string WithAutoJoin(string xml)
    {
        var doc = XDocument.Parse(xml);
        var root = doc.Root ?? throw new InvalidDataException("Windows Wi-Fi 配置为空。");
        var mode = root.Element(W + "connectionMode");
        if (mode is null) return xml;
        if (mode.Value == "auto") return xml;
        mode.Value = "auto";
        return doc.ToString(SaveOptions.DisableFormatting);
    }

    public static string PeapCredentials(string username, string password)
    {
        XNamespace host = "http://www.microsoft.com/provisioning/EapHostUserCredentials";
        XNamespace baseUser = "http://www.microsoft.com/provisioning/BaseEapUserPropertiesV1";
        XNamespace peapUser = "http://www.microsoft.com/provisioning/MsPeapUserPropertiesV1";
        XNamespace chapUser = "http://www.microsoft.com/provisioning/MsChapV2UserPropertiesV1";
        var split = username.IndexOf('\\');
        var domain = split > 0 ? username[..split] : "";
        var user = split > 0 ? username[(split + 1)..] : username;
        return new XElement(host + "EapHostUserCredentials",
            new XElement(host + "EapMethod", new XElement(Common + "Type", 25), new XElement(Common + "AuthorId", 0)),
            new XElement(host + "Credentials", new XElement(baseUser + "Eap", new XElement(baseUser + "Type", 25),
                new XElement(peapUser + "EapType", new XElement(peapUser + "RoutingIdentity", username),
                    new XElement(baseUser + "Eap", new XElement(baseUser + "Type", 26),
                        new XElement(chapUser + "EapType", new XElement(chapUser + "Username", user),
                            new XElement(chapUser + "Password", password), new XElement(chapUser + "LogonDomain", domain)))))))
            .ToString(SaveOptions.DisableFormatting);
    }

    public static bool IsCredentialFailure(uint reason) => reason is
        0x2800D /* key mismatch */ or 0x48014 /* suspected PSK mismatch */ or
        0x50001 or 0x50002 /* no identity */ or 0x50005 /* EAP rejection */ or
        0x50012 or 0x50013 /* invalid/expired explicit credentials */;
}
