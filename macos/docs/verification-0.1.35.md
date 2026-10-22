# macOS 0.1.35 verification

Date: 2026-10-22. Scope: macOS connection confirmation presentation only.

- Replaced the long inline explanation with a compact title, SSID and account name.
- Added a blue question-mark button labelled 设置说明. It opens a transient popover explaining both choices and the unchanged network-priority/Auto-Join behavior.
- Buttons are 同步账号, 仅本次连接 and 取消; their true/false/nil results and existing connection logic are unchanged. No Windows, credential-storage or system-network changes.
- Swift Testing: 154 tests in 11 suites passed (`.build/sync-choice/tests.log`).
- An independent preview compiled the production dialog source with a temporary observation/action harness and synthetic network/account values. Each of the three runs opened the actual popover (`help_visible=true`) and returned true, false and cancelled respectively. No actual Wi-Fi connection or keychain access occurred.
- AppKit view captures verified the blue question mark and complete help copy. These captures lack some window compositing; they are not full-desktop screenshot proof. CUA could not attach to the temporary preview (timeout), so manual pointer/keyboard interaction remains unverified.
- Package target: 0.1.35 build 36, macOS 13+, Apple Silicon/arm64. Installed application is not replaced by this task.
- Package script passed signature verification, DMG verification, read-only mount, bundled README/executable comparisons and Applications-link check. Output: `dist/WiFi-Switch-0.1.35-arm64-internal.dmg`; log: `.build/sync-choice/package-0.1.35.log`. The temporary preview process was closed after verification.
