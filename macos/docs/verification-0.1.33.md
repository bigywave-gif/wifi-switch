# macOS 0.1.33 verification

Date: 2026-10-21. Scope: macos/ only; no Windows source, settings or artifacts changed.

## Implemented

- Background identity helper requests only the saved EAP username using public CoreWLAN. Keychain interaction is disabled in the isolated helper, with a four-second parent timeout. The parent retains interactive authorization. No password is requested or printed by this helper.
- Current SSID/security/username uniquely resolves an existing account and updates its marker/order. Personal/open matching requires a single associated account. Unknown/ambiguous identity stays unknown. Tooltips distinguish saved configuration from authenticated-session evidence.
- Independent import window for unresolved healthy connections: required label, consent before secret access, persistent per-SSID dismissal, manual retry. Both credential domains must agree. No reconnect. Identical existing configurations are reused without overwriting. Cancellation/network changes discard results; storage failure rolls back the new secret.
- Explicit connection/reconnection asks Yes/No/Cancel before reading its password or clearing its record. Yes syncs this SSID's credentials after verification. No captures/preserves prior credentials, restores native association writes and verifies restoration. Permission/conflict failures are reported. Automatic retries preserve credentials without another choice dialog. No preferred-network or Auto-Join writes.
- Live app connection evidence takes precedence until observed system connection changes. Saved usernames are not described as proof of live EAP identity.

## Verification

- Swift Testing: 146 tests across 10 suites passed; `.build/system-import/tests.log`.
- Added consent/empty-label/cancel/re-prompt, duplicate import, enterprise/personal/open, denied/missing/ambiguous data, network changes/cancellation during a read, double confirmation, storage rollback, account identity change, Yes/No/Cancel propagation, credential restoration on success/failure, and concurrent external write protection tests.
- All new credential/network tests use synthetic values and fake services. No real Wi-Fi switch or password import was performed.
- CUA inspected a separate temporary preview app launched with `--demo --demo-import`. Import window showed the synthetic SSID, required label, consent text, Cancel, and disabled Confirm with an empty label. Fixture uses only memory storage/vault and synthetic network/credential services.
- Package script checks signature, mounts DMG read-only, compares executable and README.md/README.txt, checks Applications link and ejects. Original signing identity retained.

## Boundaries / target Mac checks remaining

- Public CoreWLAN returns saved credentials, not the authenticated EAP session's username. After choosing No, quitting/reopening without reconnecting can leave system saved identity different from the active session. Tooltips and README state this limit.
- Background helper uses deprecated public SecKeychain interaction control because CoreWLAN lacks a per-call no-UI option. Target OS, managed/iCloud keychain compatibility and username availability need real-device validation; unavailable results fail closed.
- Real company-network checks remain: system auto-join for both accounts, Yes syncing after success, No preserving prior account after disconnect/rejoin, denied authorization, system ACL prompts, user-confirmed import.
- Previous first-system-reconnect Keychain authorization prompt is not claimed fixed. Permission failures are not credential rejection.
- macOS 13+ arm64 build; not proof of macOS 13 runtime or Intel compatibility.
- Release artifacts updated in macos/dist; /Applications app was not replaced or restarted.
