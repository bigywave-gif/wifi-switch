namespace WiFiSwitch.Core;

// Native notifications have no request ID. Ignore completions from an older operation
// until Windows announces the start of this profile's new connection.
public sealed class ConnectionAttempt(Guid adapter, string profile)
{
    private bool started;
    private bool superseded;
    public uint? LastFailure { get; private set; }
    public string? LastPhase { get; private set; }
    public uint? LastOneXStatus { get; private set; }
    public void NotifyPhase(Guid sourceAdapter, string sourceProfile, string phase, uint reason)
    {
        if (!started || superseded || sourceAdapter != adapter || sourceProfile != profile) return;
        LastPhase = phase;
        if (reason != 0) LastFailure = reason;
        // Never keep retrying explicitly rejected credentials. Other MSM events
        // are diagnostic only and cannot establish connection success.
        if (ProfileXml.IsCredentialFailure(reason)) Completion.TrySetResult(reason);
    }
    public void NotifyOneX(uint status)
    {
        // ONEX updates carry no profile name; only trust them once this attempt
        // has started, so an earlier operation's status cannot mask a stuck one.
        if (started && !superseded) LastOneXStatus = status;
    }
    public bool CanStop(uint state, string? currentProfile)
        => started && !superseded && currentProfile == profile && state is 5 or 6 or 7;
    // A timeout alone must not interrupt an 802.1X authentication that Windows
    // still reports as in progress: slow RADIUS paths can legitimately exceed it.
    public bool ShouldInterrupt(uint state, string? currentProfile)
        => CanStop(state, currentProfile) && !(state == 7 && LastOneXStatus == 1);
    public TaskCompletionSource<uint> Completion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public void Notify(Guid sourceAdapter, string sourceProfile, uint code, uint reason)
    {
        if (sourceAdapter != adapter) return;
        // A user/system request for another profile takes ownership of the adapter.
        if (started && sourceProfile != profile && code == 9) superseded = true;
        if (sourceProfile != profile || superseded) return;
        if (code == 9) started = true; // ACM connection_start
        if (!started) return;
        if (code is 10 or 11 && reason != 0) LastFailure = reason;
        if (code == 10 || (code == 11 && ProfileXml.IsCredentialFailure(reason)))
            Completion.TrySetResult(reason);
    }
}

public static class ConnectionRecovery
{
    public static bool CanRestore(Snapshot previous, Snapshot current, string attemptedProfile,
        bool automatic, bool connectionStarted)
        => !automatic && connectionStarted && previous.HasAddress && previous.Ssid is not null &&
            previous.ProfileName is { Length: > 0 } && previous.ProfileName != attemptedProfile &&
            current.InterfaceId == previous.InterfaceId && current.Available && current.PoweredOn &&
            current.Readable && current.Ssid is null;
}
