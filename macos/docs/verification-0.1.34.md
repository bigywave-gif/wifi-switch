# macOS 0.1.34 verification

Date: 2026-10-21. Scope: macos/ only; Windows source, configuration and artifacts are unchanged.

## Root cause and repair

- The old helper exited when CoreWLAN returned a nil SSID in its child process. The main application could already read the connected SSID. Direct CoreWLAN EAP username queries also returned errSecItemNotFound (-25300) for both domains on this Mac.
- A read-only Security attributes query found an existing legacy system EAP entry for Example-Enterprise. Its account attribute uniquely matched the existing account labelled 办公账号. No password data was requested or printed.
- The new helper accepts the main application's observed SSID when its own SSID is unavailable, rejects a readable conflicting SSID, and checks power, IP and security. The parent checks its current connection again after the query and rejects stale revisions.
- Username lookup requests attributes only from default, data-protection and explicit system keychains. Exact label and system EAP service/SSID checks exclude unrelated entries. Conflicting, inaccessible, missing or empty usernames fail closed. Helper interaction is disabled and each query explicitly uses kSecUseAuthenticationUIFail; the parent retains the four-second timeout.
- Automatic add-configuration prompts require successful identity retrieval and evidence that no corresponding configuration exists. Failed reads and ambiguous identity no longer imply a new account. Matching an existing account closes an earlier automatic proposal; a manually opened import remains under user control.

## Verification

- Swift Testing: 154 tests across 11 suites passed. Log: `.build/identity-fix/tests.log`.
- Regression tests cover exact metadata filtering, conflicting usernames, no secret-data requests, failed retrieval with and without saved accounts, later successful retrieval, matching an existing account, stale automatic proposals, manual import preservation, missing usernames, wrong SSID and conflicting authentication types. Existing connection/credential-preservation tests also pass.
- The compiled debug executable's real `--system-identity Example-Enterprise` path returned exit 0, enterprise authentication and one match: 办公账号. The validation wrapper captured the username in memory and printed only network, authentication type and matching account labels/count. No network switch, credential write or password read was performed.
- The signed release executable (0.1.34 build 35) returned the same real match and exit 0. Sanitized report: `.build/identity-fix/release-identity-result.json`.
- `scripts/package-internal.sh` completed successfully using the original local signing identity. It verified the signature, verified and mounted the DMG read-only, compared its executable and README.md/README.txt to the release files, checked the Applications link and ejected the disk. Log: `.build/identity-fix/package-0.1.34.log`.
- Package: `dist/WiFi-Switch-0.1.34-arm64-internal.dmg`, with adjacent SHA-256 file. README includes the updated recognition and automatic-prompt behavior.

## Boundaries

- The returned username is a system-saved identity, not proof of which EAP identity the authentication server accepted for the live session.
- This fix does not change password import, synchronization consent, Auto-Join or preferred-network ordering. Real password import and full company-network reconnection were not exercised.
- Other macOS versions and managed/iCloud keychain layouts remain unverified. The legacy keychain APIs used here are public but deprecated. Unsupported layouts return unknown and do not trigger an automatic add prompt.
- Release target: macOS 13+ Apple Silicon (arm64), version 0.1.34 build 35. This task does not replace or restart the installed /Applications app.
