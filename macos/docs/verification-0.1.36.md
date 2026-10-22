# macOS 0.1.36 verification

Date: 2026-10-22. Scope: macOS application information and local documentation.

- Uses AppKit's standard About panel with the app icon, bundle name, version and build. Additional information shows the app purpose, compiled architecture, minimum macOS version and distribution type. Version/build/system requirement are read from the running bundle, not hardcoded in the view.
- Added About in the standard application menu and the menu-bar gear menu. Added local user guide in the Help menu and gear menu. README.txt is copied into Contents/Resources before signing; package validation compares this file with the README source.
- Added the utilities application category and Chinese development region to the bundle metadata. Developer ID builds label their distribution accordingly. No unconfirmed developer name, copyright ownership, website or license is invented.
- Swift Testing: 154 tests in 11 suites passed; `.build/app-information/tests.log`.
- An isolated preview compiled the production AppInformation source using the release metadata and icon, without creating the application model or accessing credentials. CUA inspected the real native panel: icon/name, 版本0.1.36 (37), Apple Silicon · arm64, macOS 13.0 and 内部使用版 were visible. A live screenshot confirmed complete readable layout. Full application menu navigation and launching an external text viewer were not exercised.
- Packaged 0.1.36 build 37 for arm64. Signature and DMG verification passed; mounted payload, README copies, executable and Applications link were checked by package-internal.sh. Log: `.build/app-information/package-0.1.36.log`.
- Independently checked packaged metadata, icon presence and byte equality of bundled guide with macos/README.md. Package SHA-256: a791f1c2faaaacad949c4b1cdaf67e746ed3f8982b783f1ffbcb15eae3bc82b2.
- No Windows files, installed app, saved accounts, keychain permissions or network preferences changed.

Reference: https://developer.apple.com/documentation/appkit/nsapplication/orderfrontstandardaboutpanel(options:)
