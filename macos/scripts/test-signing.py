#!/usr/bin/env python3
"""Exercise the packaging gate without signing keys, secrets, or network access."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
REQUIREMENT = 'identifier "org.wifiswitch.WiFiSwitch" and anchor H"' + 'a' * 40 + '"'

MOCK_CODESIGN = r'''
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ["WIFI_TEST_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
app = pathlib.Path(args[-1])
previous = (app / "Contents/MacOS/WiFiSwitch").read_text() == "previous-binary"
if "--sign" in args:
    if os.environ.get("WIFI_TEST_MISSING_IDENTITY") == "1":
        sys.exit(1)
    (app / "signed-identity").write_text(args[args.index("--sign") + 1])
elif "-r-" in args:
    print("Executable=" + str(app), file=sys.stderr)
    print("# designated => " + os.environ["WIFI_TEST_REQUIREMENT"])
elif "-dv" in args:
    adhoc = (previous and os.environ.get("WIFI_TEST_OLD_ADHOC") == "1") or (
        not previous and os.environ.get("WIFI_TEST_NEW_ADHOC") == "1")
    print("Signature=adhoc" if adhoc else "Authority=WiFi Switch Local Signing", file=sys.stderr)
elif "--verify" in args:
    if not previous and os.environ.get("WIFI_TEST_INVALID_SIGNATURE") == "1":
        sys.exit(1)
    if any(arg.startswith("-R=") for arg in args):
        if any(arg.startswith("-R=anchor apple generic") for arg in args):
            sys.exit(1 if os.environ.get("WIFI_TEST_SELF_SIGNED") == "1" else 0)
        expected = os.environ.get("WIFI_TEST_OLD_IDENTITY", "WiFi Switch Local Signing")
        sys.exit(0 if (app / "signed-identity").read_text() == expected else 1)
else:
    sys.exit(2)
'''


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wifi-signing-check-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        for name in ("build-app.sh", "sign-app.sh"):
            shutil.copyfile(ROOT / "scripts" / name, self.root / "scripts" / name)
        (self.root / ".build/release").mkdir(parents=True)
        (self.root / ".build/release/WiFiSwitch").write_text("new-binary")
        (self.root / ".build/AppIcon.icns").write_text("synthetic icon")
        (self.root / "Resources").mkdir()
        (self.root / "Resources/Info.plist").write_text("synthetic plist")
        self.previous = self.root / "dist/WiFi Switch.app"
        (self.previous / "Contents/MacOS").mkdir(parents=True)
        (self.previous / "Contents/MacOS/WiFiSwitch").write_text("previous-binary")
        self.bin = self.root / "mock-bin"
        self.bin.mkdir()
        (self.bin / "codesign").write_text(f"#!{sys.executable}\n" + MOCK_CODESIGN)
        (self.bin / "swift").write_text("#!/bin/sh\nexit 0\n")
        for executable in self.bin.iterdir():
            executable.chmod(0o700)
        self.log = self.root / "codesign.jsonl"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("WIFI_SWITCH_", "WIFI_TEST_"))}
        self.env.update(PATH=f"{self.bin}:/usr/bin:/bin", BUILD_CONFIGURATION="release",
                        WIFI_TEST_LOG=str(self.log), WIFI_TEST_REQUIREMENT=REQUIREMENT,
                        WIFI_SWITCH_SIGNING_IDENTITY="WiFi Switch Local Signing")

    def build(self, **settings):
        return subprocess.run(["/bin/bash", "scripts/build-app.sh"], cwd=self.root,
                              env={**self.env, **settings}, capture_output=True, text=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def assert_preserved(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.previous / "Contents/MacOS/WiFiSwitch").read_text(), "previous-binary")
        self.assertFalse(list((self.root / ".build").glob("app-stage.*/Previous WiFi Switch.app")))

    def test_adhoc_migration_keeps_previous_bundle(self):
        result = self.build(WIFI_TEST_OLD_ADHOC="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.previous / "signed-identity").read_text(), "WiFi Switch Local Signing")
        archived = list((self.root / ".build").glob("app-stage.*/Previous WiFi Switch.app"))
        self.assertEqual(len(archived), 1)
        self.assertEqual((archived[0] / "Contents/MacOS/WiFiSwitch").read_text(), "previous-binary")

    def test_updates_must_satisfy_previous_designated_requirement(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any("-R=" + REQUIREMENT in call for call in self.calls()))

    def test_explicit_identity_and_keychain_are_single_arguments(self):
        fingerprint = "b" * 40
        keychain = "/example path/Signing.keychain-db"
        result = self.build(WIFI_SWITCH_SIGNING_IDENTITY=fingerprint,
                            WIFI_SWITCH_SIGNING_KEYCHAIN=keychain, WIFI_TEST_OLD_IDENTITY=fingerprint)
        self.assertEqual(result.returncode, 0, result.stderr)
        signing = next(call for call in self.calls() if "--sign" in call)
        self.assertEqual(signing[signing.index("--sign") + 1], fingerprint)
        self.assertEqual(signing[signing.index("--keychain") + 1], keychain)

    def test_missing_identity_does_not_fall_back_or_replace(self):
        self.assert_preserved(self.build(WIFI_TEST_MISSING_IDENTITY="1"))
        signing = [call for call in self.calls() if "--sign" in call]
        self.assertEqual(len(signing), 1)
        self.assertNotEqual(signing[0][signing[0].index("--sign") + 1], "-")

    def test_changed_identity_does_not_replace(self):
        self.assert_preserved(self.build(WIFI_SWITCH_SIGNING_IDENTITY="Different certificate"))

    def test_explicit_adhoc_is_rejected(self):
        self.assert_preserved(self.build(WIFI_SWITCH_SIGNING_IDENTITY="-"))
        self.assertEqual(self.calls(), [])

    def test_invalid_signature_does_not_replace(self):
        self.assert_preserved(self.build(WIFI_TEST_INVALID_SIGNATURE="1"))

    def test_unexpected_adhoc_result_does_not_replace(self):
        self.assert_preserved(self.build(WIFI_TEST_NEW_ADHOC="1"))

    def test_first_install_uses_certificate(self):
        shutil.rmtree(self.previous)
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.previous / "signed-identity").read_text(), "WiFi Switch Local Signing")

    def test_shipping_rejects_self_signed_certificate(self):
        self.assert_preserved(self.build(WIFI_SWITCH_SIGNING_MODE="developer-id", WIFI_TEST_SELF_SIGNED="1"))

    def test_shipping_requires_configured_identity(self):
        self.assert_preserved(self.build(WIFI_SWITCH_SIGNING_MODE="developer-id", WIFI_SWITCH_SIGNING_IDENTITY=""))
        self.assertEqual(self.calls(), [])

    def test_shipping_uses_hardened_runtime_and_timestamp(self):
        result = self.build(WIFI_SWITCH_SIGNING_MODE="developer-id")
        self.assertEqual(result.returncode, 0, result.stderr)
        signing = next(call for call in self.calls() if "--sign" in call)
        self.assertEqual(signing[signing.index("--options") + 1], "runtime")
        self.assertIn("--timestamp", signing)

    def test_internal_defaults_to_local_identity_without_membership(self):
        result = self.build(WIFI_SWITCH_SIGNING_IDENTITY="", WIFI_TEST_SELF_SIGNED="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        signing = next(call for call in self.calls() if "--sign" in call)
        self.assertEqual(signing[signing.index("--sign") + 1], "WiFi Switch Local Signing")
        self.assertNotIn("--timestamp", signing)

    def test_unknown_mode_preserves_previous(self):
        self.assert_preserved(self.build(WIFI_SWITCH_SIGNING_MODE="typo"))
        self.assertEqual(self.calls(), [])

    def test_local_build_cannot_replace_shipping_app(self):
        result = self.build(WIFI_SWITCH_LOCAL_BUILD="1", WIFI_TEST_SELF_SIGNED="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.previous / "Contents/MacOS/WiFiSwitch").read_text(), "previous-binary")
        local = self.root / "dist/local/WiFi Switch.app"
        self.assertEqual((local / "Contents/MacOS/WiFiSwitch").read_text(), "new-binary")


if __name__ == "__main__":
    unittest.main()
