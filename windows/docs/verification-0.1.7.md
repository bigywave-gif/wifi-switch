# Windows 0.1.7 — trust confirmation and stale connection errors

## Evidence and cause

The reported sequence is: accept Windows' network trust prompt, briefly disconnect
with an application error, accept another prompt, then see both a healthy green
connection and the earlier red error. The supplied screenshot shows the final
verification error from `Controller.ConnectAsync`, alongside a recognized healthy
account. It does not contain the trust dialog or a WLAN event log for this attempt.

Two code paths explain this combination:

1. `NativeWiFi.ConnectAsync` already configured automatic joining before connecting,
   but a new profile's success branch called `EnableAutoJoin` again. That rewrote
   the pre-authentication XML with `WlanSetProfile` and resubmitted EAP credentials
   after consent and three healthy IP samples. This redundant write could reset
   state Windows had just accepted and trigger another authentication. Existing
   profiles also received a late custom account-marker write. The historical
   `verification-0.1.6.md` records cancellations after that live marker write;
   postponing it until IP acquisition still left it on the active session.
2. `Controller.RefreshAsync` cleared `Configuration.Failure` when Windows recovered,
   enabling the green account indicator, but left `Notice` and `NoticeIsError`
   unchanged. This directly reproduces the screenshot's contradictory state.

The Windows trust-dialog/cancellation cause is a code-supported diagnosis pending
current Windows logs and physical retesting, not a locally reproduced WLAN result.
Microsoft documents that `WlanSetProfile` replaces profile contents and clears
custom user data; it does not promise that writing custom data disconnects every
adapter. References:

- [WlanSetProfile](https://learn.microsoft.com/en-us/windows/win32/api/wlanapi/nf-wlanapi-wlansetprofile)
- [WlanSetProfileCustomUserData](https://learn.microsoft.com/en-us/windows/win32/api/wlanapi/nf-wlanapi-wlansetprofilecustomuserdata)
- [WlanSetProfileEapXmlUserData](https://learn.microsoft.com/en-us/windows/win32/api/wlanapi/nf-wlanapi-wlansetprofileeapxmluserdata)

## Repair

- Prepare profile XML, automatic joining, priority, EAP credentials and the account
  marker before `WlanConnect`. Do not repeat an identical marker write.
- Remove the success-time auto-join/profile/credential rewrite. After authentication,
  only read the target connection; legacy cleanup continues to exclude that profile.
- A prepared marker identifies submitted credentials, not success. Require this
  attempt's successful connection notification and three consecutive matching
  adapter/SSID/profile/account/IP observations. Cancellation, unavailable state,
  missing address and another account cannot pass verification.
- Stop on profile or priority setup errors instead of continuing with stale settings.
- On recognized recovery, clear the failed connection's notice, error flag and edit
  suggestion together with its persisted failure. Preserve newer unrelated errors.
- Keep server-certificate validation and the legitimate initial Windows consent.
  No changes to the visual layout, account file format or macOS source.

## Automated verification

- `artifacts/regression-before-0.1.7.log`: the new tests run against the original
  controller produce **63/67 passing**, with four failures exposing stale notices
  and dismissal state. The new polling helper was included only to compile its
  independent tests; this is not a native WLAN simulation.
- `artifacts/core-tests-0.1.7.log`: **67/67 passing** after repair. Covers delayed
  manual success, automatic recovery, restart/persistence, wrong-account and no-IP
  states, preserving unrelated errors, failed storage, and stable verification.
- Release/package results are recorded in `artifacts/release-build-0.1.7.log` and
  `artifacts/package-verification.json`. Packaging independently extracts the
  installer and compares the executable/README byte for byte with the publish output.
- Historical macOS preservation manifest: all **36 existing entries** match. The
  historical `dist/WiFi-Switch-0.1.29-arm64-internal.dmg.sha256` entry is absent;
  the old preservation script therefore cannot report a complete pass. This task
  made no macOS edits and did not recreate or alter that historical file.

## Windows acceptance still required

1. Exit the old application from its tray, install 0.1.7 and start normally.
2. Connect an enterprise network requiring initial server-certificate consent.
   Confirm the expected server identity, accept once, and check that the application
   does not cause a second disconnect/prompt. If it does, export diagnostics with
   the exact Windows dialog text; do not disable certificate validation.
3. Confirm the log has `准备账号识别标记` before `connect requested`, followed by
   `verification stableSamples=3; target profile unchanged after authentication`
   and `END success=True`, without target-profile/credential writes after success.
4. Reconnect the same account and switch accounts on the same SSID. Confirm the
   displayed account only becomes active after verification. Try a wrong password
   and verify it does not become green merely because a marker was prepared.
5. If a pending connection completes after an application timeout, confirm its
   own error clears on the next poll when its account and usable IP are recognized.
   Other-account connections and unrelated errors must remain distinguishable.

No Windows runtime or real enterprise WLAN was available on this macOS host.
Automated tests and cross-compilation do not validate OS prompts, driver behavior,
installation, real credential rejection, or authentication-server policy.
