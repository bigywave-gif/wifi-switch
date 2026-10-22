# Windows 0.1.6 — logon-session scope, authentication deadline and dead-end recovery

## Evidence and scope

On the target Windows 11 machine (example wireless adapter, Windows (OS build redacted)), five 0.1.5
connection attempts against the same enterprise SSID failed while a manual
connection from the Windows Wi-Fi menu succeeded seconds later, using the same
credentials. Diagnostics established four contributing defects:

- The normal-session attempts could not see the profile written by an elevated
  session (`profile exists=False` on every attempt across sessions) and rewrote
  it each time. The one attempt that completed authentication was cancelled by
  Windows about 30 ms after the success notification; its per-user profile had
  been written from an elevated (UAC) logon session.
- The successful authentication itself took 34.4 seconds; the other attempts
  were still authenticating when the 45-second deadline expired and the
  application disconnected the pending authentication (`0x38001` afterwards).
- After three recorded failures the failure state survived a subsequent healthy
  system connection, and the account marker was absent, so the UI stayed in
  "当前账号未识别" with no way to recover.
- Every authentication that completed under 0.1.6 died about 0.5 seconds after
  the application wrote the account marker onto the live session
  (`WlanSetProfileCustomUserData`): four for four, always `0x38001`, and the
  profile-name hash introduced for diagnosis proved the torn-down events
  belonged to the application's own profile, not a competitor.

Only the Windows tree was edited. Changes were compiled and unit-tested on the
target Windows machine; no elevated/normal session interaction was reproduced
automatically.

## Changes

- New WLAN profiles default to all-user scope, matching the Windows Wi-Fi menu;
  existing profile scope is still preserved when reusing a compatible profile.
- The application warns at startup when running with an administrator token.
- The authentication deadline is 90 seconds. A timeout no longer interrupts a
  pending 802.1X authentication that Windows reports as in progress; it only
  interrupts association/discovery states or authenticating without ONEX
  progress evidence, and says so in the failure message.
- A healthy connection whose marker matches the saved account now clears the
  stopped failure state (display only; no automatic retry is scheduled).
- New "认领当前连接" action: when the system is connected to the remembered
  network with an address but the marker does not match, the user can adopt the
  connection. The marker is written onto the current profile and verified by
  read-back; failure is reported instead of silently rewriting.
- Before connecting, the target profile is switched to automatic joining and
  promoted to the highest priority, so WLAN AutoConfig cannot race another
  automatic profile into the adapter after the disconnect barrier. Diagnostics
  record a non-reversible hash of profile names per event.
- The account marker is written only after the connection has been verified
  stable (matching interface, SSID, profile name and address); the verification
  itself uses link-state criteria and does not depend on the not-yet-written
  marker.

## Verification

- Portable tests extended for the new behaviour: ONEX-aware interruption gating,
  all-user default scope, healthy-state recovery without reconnecting, claim
  success/failure paths, auto-join template normalization, link-state
  verification. All tests pass on Windows x64 (see artifacts).
- Release self-contained Windows x64 build of `WiFiSwitch.exe` succeeded.

## Windows acceptance still required

- Install 0.1.6, start from the Start menu (not elevated), connect through the
  app and confirm `END success=True`, `verification stableSamples=3` and a
  green status without a manual second connect.
- Run elevated once to confirm the startup warning appears and the claim action
  fails with the session-mismatch explanation.
- Trigger the 90-second deadline on an unreachable RADIUS path and confirm the
  in-progress authentication is preserved rather than disconnected.
