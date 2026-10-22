# Windows 0.1.9 — stale claim-verification notice

## Reproduced path

The screenshot's exact text, “标记已写入但系统尚未生效，请稍后重试。”, came from
`Controller.ClaimCurrentAsync`, not `ConnectAsync`. Claim wrote the account marker
then checked a single snapshot. A transient mismatch threw an exception; the claim
button passed only its message into `SetProblem`, losing its association with the
claimed account. Subsequent healthy polls cleared persisted connection failures
but preserved this generic notice. When there was no persisted failure, the old
notice-clearing block was not entered at all. This explains the green account and
red claim-verification notice appearing together.

## Changes

- Claim waits up to five seconds for three consecutive samples matching the account,
  interface, SSID, profile and usable IP. It writes the marker only once.
- Claim has its own busy state, preventing overlapping claims, connections and
  stale refresh results without marking all connection buttons as connecting.
- If verification still times out, the exception carries the exact selection it
  belongs to. The real claim-button error handler preserves that information.
- Healthy polling clears a status notice only when its selection matches, including
  when no `Configuration.Failure` exists. Unrelated errors and status notices for
  other accounts remain. No error-message string matching is used.
- Successful claims and connections explicitly reset the notice's error styling.
  Cancellation and suspension release the claim busy state without saving success.
- No changes to WLAN profile writes, credential submission, certificate validation,
  account storage format or macOS source.

## Verification

- `artifacts/core-tests-0.1.9.log`: **74/74 passing**. New coverage includes delayed
  marker/IP snapshots, claim timeout followed by late recovery without a stored
  failure, wrong account/interface/profile/SSID and missing IP, newer unrelated
  errors, write/save failures, overlapping operations, cancellation and suspension.
- `artifacts/publish-0.1.9.log`: Windows x64 self-contained publish. Dependencies
  are unchanged; the command reuses the successful 0.1.8 restore with `--no-restore`.
- `artifacts/installer-build-0.1.9.log` and `artifacts/package-verification.json`
  record installer packaging and independent executable/README payload comparison.

This macOS host cannot exercise the real Windows Forms UI or driver timing. Windows
acceptance should claim a connected network whose account marker is missing, verify
that a brief update delay does not immediately produce an error, and confirm a late
recognized recovery clears its own notice within the normal five-second poll.
Permission and save errors must remain visible. Dismissing the old banner with ×
is sufficient for an already healthy connection; it does not disconnect Wi-Fi.
