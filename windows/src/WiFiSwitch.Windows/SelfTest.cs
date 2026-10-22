using System.Text.Json;
using WiFiSwitch.Core;

namespace WiFiSwitch.Windows;

// Opt-in acceptance helper for a future Windows machine. It never calls Wi-Fi APIs.
internal static class SelfTest
{
    public static int Run(string reportPath)
    {
        var id = Guid.NewGuid();
        var vault = new CredentialVault("WiFiSwitch/SelfTest/" + id.ToString("N") + "/");
        var directory = Path.Combine(Path.GetTempPath(), "WiFiSwitchSelfTest-" + id.ToString("N"));
        var results = new List<string>();
        var success = false;
        try
        {
            if (File.Exists(reportPath)) throw new IOException("Report already exists; choose a new path.");
            var password = Guid.NewGuid().ToString("N");
            vault.Write(id, password);
            if (vault.Read(id) != password) throw new IOException("Credential read-back failed");
            results.Add("Credential Manager write/read");
            vault.Write(id, password + "-updated");
            if (new CredentialVault("WiFiSwitch/SelfTest/" + id.ToString("N") + "/").Read(id) != password + "-updated")
                throw new IOException("Credential update/read-back failed");
            results.Add("Credential Manager update/reopen");
            var path = Path.Combine(directory, "accounts.json");
            var repo = new Repository(new JsonStorage(path), vault);
            repo.SaveAccount(new Account { Id = id, Label = "Temporary acceptance account" }, password);
            var reopened = new Repository(new JsonStorage(path), vault);
            if (reopened.Configuration.Accounts.Single().Id != id || reopened.Password(reopened.Configuration.Accounts.Single()) != password)
                throw new IOException("Persistent configuration reopen failed");
            if (File.ReadAllText(path).Contains(password, StringComparison.Ordinal)) throw new IOException("Secret leaked into metadata");
            results.Add("JSON reopen and secret isolation");
            reopened.DeleteAccount(id);
            if (vault.Read(id) is not null) throw new IOException("Credential delete failed");
            results.Add("Credential Manager delete");
            success = true;
        }
        catch (Exception error) { results.Add("FAIL: " + error.GetType().Name + ": " + error.Message); }
        finally
        {
            try { vault.Delete(id); if (Directory.Exists(directory)) Directory.Delete(directory, true); }
            catch (Exception error) { success = false; results.Add("Cleanup failed: " + error.GetType().Name); }
        }
        try
        {
            var report = new { success, results, realWiFiTouched = false, at = DateTimeOffset.UtcNow };
            using var stream = new FileStream(reportPath, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            JsonSerializer.Serialize(stream, report, new JsonSerializerOptions { WriteIndented = true });
        }
        catch { return 2; }
        return success ? 0 : 1;
    }
}
