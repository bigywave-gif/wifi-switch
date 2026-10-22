namespace WiFiSwitch.Core;

public static class ConnectionVerification
{
    // A prepared account marker alone is never success. Confirm the selected
    // adapter, SSID, profile, account and usable address in consecutive samples.
    public static Task<bool> WaitAsync(Selection selection, Func<Snapshot> readState,
        TimeSpan timeout, TimeSpan pollInterval, CancellationToken token = default)
        => WaitAsync(selection, () => Task.FromResult(readState()), timeout, pollInterval, token);

    public static async Task<bool> WaitAsync(Selection selection, Func<Task<Snapshot>> readState,
        TimeSpan timeout, TimeSpan pollInterval, CancellationToken token = default)
    {
        var started = System.Diagnostics.Stopwatch.StartNew();
        var stable = 0;
        do
        {
            token.ThrowIfCancellationRequested();
            var state = await readState();
            token.ThrowIfCancellationRequested();
            stable = Rules.Matches(selection, state) && state.HasAddress ? stable + 1 : 0;
            if (stable >= 3) return true;
            var remaining = timeout - started.Elapsed;
            if (remaining <= TimeSpan.Zero) return false;
            await Task.Delay(remaining < pollInterval ? remaining : pollInterval, token);
        } while (true);
    }
}
