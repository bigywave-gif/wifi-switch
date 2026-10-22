# Windows 0.1.8 — connection progress belongs to one network row

The shared `NetworkRow` renderer used the global `Busy` flag for every button's
label. Clicking one connection therefore changed all ordinary connection buttons
to “连接中…”, including another account associated with the same SSID.

The controller now keeps the in-progress `Selection` separately from the saved
current connection. `Busy` is derived from that selection, preserving the existing
single-request guard. Each row matches both account ID and SSID before displaying
“连接中…”. Other connection buttons retain “连接” and remain temporarily disabled
to prevent concurrent WLAN requests. An in-progress row takes precedence over its
previous error indicator. The main window and tray share this renderer, and both
render signatures include the in-progress selection. Success, failure and
cancellation clear it before the final refresh.

Verification:

- `artifacts/core-tests-0.1.8.log`: **69/69 passing**. Async tests hold a connection
  pending, verify isolation across accounts sharing an SSID and networks sharing
  an account, reject competing requests, and verify cleanup after success, failure
  and cancellation followed by another connection.
- `artifacts/publish-0.1.8.log`: self-contained Windows x64 publish succeeded.
  The initial build's NuGet request failed (`NU1900`); retry with network access
  completed restore and publish without disabling dependency auditing.
- `artifacts/installer-build-0.1.8.log` and `artifacts/package-verification.json`
  record installer packaging and independent payload comparison.

This macOS host cannot run the Windows Forms UI. On Windows, confirm only the
clicked row changes text in both the main window and expanded tray panel; include
two accounts on the same SSID, an account with multiple Wi-Fi networks, and a
failed reconnection. No WLAN authentication or certificate configuration changes
are included in this release.
