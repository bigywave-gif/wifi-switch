# macOS release requirements

Every newly packaged version must update application information. This is a standing user requirement.

- Before packaging, increment both CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist. Default to the next patch version and next integer build unless a different release version is explicitly requested.
- Update README.md's current-release version and installation filename at the same time. Keep historical verification documents unchanged.
- The native About panel must read the running bundle metadata, never a hardcoded release number. Verify name, icon, version/build, architecture, minimum OS and distribution type against the artifact.
- Run scripts/package-internal.sh. It rejects stale versions/builds and inconsistent README text, verifies the signed DMG and bundled guide, then records the successful release in release.json. Do not bypass this guard or overwrite an existing release.
- Do not update release.json in advance to make a build pass. A failed build is not a published release.
- Verify the package and report its actual version, architecture and path. Distinguish a packaged release from an installed update.
- macOS release changes must not modify Windows code, configuration or artifacts.

## Release notes

- Every new release must have a topmost version entry in CHANGELOG.md, after Unreleased, with the exact version/build, an ISO date in Asia/Shanghai, categorized concrete changes (Added/Changed/Fixed/Removed/Deprecated/Security as applicable), and a nonempty 验证与限制 section.
- Describe the trigger and before/after behavior for BUG fixes, user entry points for new features, and relevant upgrade/data effects. Do not substitute vague optimization claims, commit dumps, or copied old entries.
- Read docs/release-policy.md and use docs/release-notes-template.md. Document actual evidence and unavailable verification separately; do not invent historical dates, builds, success or releases.
- package-internal.sh enforces the current changelog entry and bundles/verifies it. Never bypass this check or modify already published packages to add notes. The next package includes the updated history.
