# Windows 0.1.5 — enterprise profile preservation and cancellation confirmation

## Evidence and scope

The two 0.1.4 attempts submitted EAP credentials successfully, entered authentication,
and were cancelled by the application after 45 seconds. A subsequent independent
Windows system login, with credentials typed by the user, authenticated in about five seconds.
The supplied Device Guard results do not include Credential Guard.

This does not prove which EAP component stalled. Do not label the issue a bad password,
missing elevation, or a confirmed Credential Guard incompatibility.

Only the Windows tree was edited. No real Wi-Fi operations or credential reads were
performed on the development Mac.

## Changes

- Reuse an existing compatible enterprise XML profile without calling WlanSetProfile.
  Preserve joining mode, certificate constraints, server validation and opaque extensions.
  Where required for the selected account, adjust explicit-user authentication options.
  Reject existing SSO before disconnecting instead of removing it.
- Do not rewrite an existing enterprise profile after authentication to force auto-join.
  Its original system joining policy remains in effect.
- Submit the account marker after the successful connection notification, then require
  the existing stable IP/profile verification before persisting success.
- Confirm disconnection through two consecutive actual disconnected interface states,
  not solely an ACM disconnected notification. Unknown, authenticating, connected and
  unavailable states do not count as confirmation.
- Retain the current 45-second connection deadline, certificate validation, credential
  storage, profile names, installer scope and macOS isolation.

## Verification

- 53/53 portable tests passed, including profile preservation, explicit credential
  compatibility, SSO rejection, missing-notification disconnection, state changes and cancellation.
- Release self-contained Windows x64 compilation and NSIS build succeeded.
- Independent archive extraction passed: AMD64 application and matching README payload.
- Installer: `dist/WiFi-Switch-0.1.5-windows-x64-setup.exe` (45,125,498 bytes).
- SHA-256: `590bf5891113c6c4e44ae6d21757ccbea1887e4735a10c584946a58a1284763d`.
- All 3,589 macOS tree files retained their paths, sizes and modification times.
  All 36 existing files from the historical content baseline matched their hashes;
  the old 0.1.29 checksum file was already absent before this work.
- Build output: `windows/.tools/release-build-0.1.5.log`;
  tests: `windows/artifacts/core-tests.log`;
  package check: `windows/artifacts/package-verification.json`.

## Windows acceptance still required

Install 0.1.5 over the existing version. Retain the Windows profile that worked with
manual credentials. During an appropriate network interruption window, connect the
same account through WiFi Switch.

For an already compatible profile, diagnostics should show:

    profile plan existingEnterprise=True writeRequired=False
    profile preserved without WlanSetProfile

A successful acceptance requires the authentication completion, stable IP verification,
and `END success=True`, plus working network access and the correct account indication.
For a failed attempt that has actually disconnected, `disconnect confirmation=True`
should replace the old secondary notification timeout.

There is no local Windows WLAN runtime. Portable tests, cross-compilation and installer
inspection cannot establish that the user's enterprise authentication problem is resolved.
