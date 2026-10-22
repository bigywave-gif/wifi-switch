namespace WiFiSwitch.Core;

public static class DisconnectConfirmation
{
    // Cancellation of an unfinished authentication may complete without ACM's
    // disconnected notification. Confirm the actual interface state instead.
    public static async Task<bool> WaitAsync(Func<uint?> readState, TimeSpan timeout,
        TimeSpan pollInterval, CancellationToken token = default)
    {
        var started = System.Diagnostics.Stopwatch.StartNew();
        var stable = 0;
        do
        {
            token.ThrowIfCancellationRequested();
            stable = readState() == 4 ? stable + 1 : 0; // wlan_interface_state_disconnected
            if (stable >= 2) return true;
            var remaining = timeout - started.Elapsed;
            if (remaining <= TimeSpan.Zero) break;
            await Task.Delay(remaining < pollInterval ? remaining : pollInterval, token);
        } while (true);
        return false;
    }
}
