#!/usr/bin/env python3
"""Real Keychain checks using synthetic entries and the production vault source.

Requires an existing fixed signing identity and built WiFiSwitchCore objects.
Never uses the production credential service, changes Wi-Fi, or permits a
Keychain authorization dialog in a probe process.
"""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
IDENTIFIER = "org.wifiswitch.WiFiSwitch.KeychainContinuityCheck"
IDENTITY = os.environ.get("WIFI_SWITCH_SIGNING_IDENTITY", "WiFi Switch Local Signing")


def run(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError(f"{Path(args[0]).name} failed ({result.returncode}): {result.stderr.strip()[-1500:]}")
    return result.stdout, result.stderr


def sign(app, identifier):
    arguments = ["/usr/bin/codesign", "--force", "--sign", IDENTITY, "--identifier", identifier]
    if os.environ.get("WIFI_SWITCH_SIGNING_KEYCHAIN"):
        arguments += ["--keychain", os.environ["WIFI_SWITCH_SIGNING_KEYCHAIN"]]
    run(arguments + [str(app)])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])


def build(folder, revision):
    app = folder / f"v{revision}" / "WiFi Switch Keychain Check.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": IDENTIFIER, "CFBundleExecutable": "Probe",
        "CFBundleName": "WiFi Switch Keychain Check", "CFBundlePackageType": "APPL",
        "CFBundleVersion": str(revision), "CFBundleShortVersionString": f"1.{revision}"
    }))
    revision_source = folder / f"Revision{revision}.swift"
    revision_source.write_text(f'let probeRevision = "{revision}"\n')
    objects = sorted((ROOT / ".build/release/WiFiSwitchCore.build").glob("*.o"))
    if not objects:
        raise RuntimeError("Build the release target first.")
    run(["/usr/bin/swiftc", "-module-cache-path", str(ROOT / ".build/module-cache"),
         "-I", str(ROOT / ".build/release/Modules"),
         str(ROOT / "Sources/WiFiSwitch/KeychainVault.swift"),
         str(ROOT / "scripts/keychain-continuity-probe.swift"), str(revision_source),
         *map(str, objects), "-o", str(app / "Contents/MacOS/Probe")])
    sign(app, IDENTIFIER)
    return app


def describe(app):
    stdout, stderr = run(["/usr/bin/codesign", "-d", "-r-", "--verbose=4", str(app)])
    combined = stdout + "\n" + stderr
    requirement = re.search(r"designated => (.+)", combined).group(1)
    cdhash = re.search(r"CDHash=(\w+)", combined).group(1)
    if "Signature=adhoc" in combined or "certificate" not in requirement:
        raise RuntimeError("The probe does not have a certificate-bound identity.")
    return requirement, cdhash


def main():
    if IDENTITY == "-":
        raise SystemExit("A fixed certificate is required.")
    report = ROOT / ".build/keychain-continuity-report.json"
    report.unlink(missing_ok=True)
    nonce = str(uuid.uuid4())
    with tempfile.TemporaryDirectory(prefix="wifi-keychain-continuity-") as temporary:
        folder = Path(temporary)
        first = build(folder, 1)
        second = build(folder, 2)
        requirement, first_hash = describe(first)
        second_requirement, second_hash = describe(second)
        if requirement != second_requirement or first_hash == second_hash:
            raise RuntimeError("Expected distinct builds with an identical signing identity.")
        run(["/usr/bin/codesign", "--verify", "--strict", "-R=" + requirement, str(second)])
        outsider = folder / "other" / first.name
        shutil.copytree(second, outsider)
        sign(outsider, IDENTIFIER + ".Other")
        installed = folder / "installed" / first.name
        shutil.copytree(first, installed)
        created = False
        steps = []
        failures = []
        try:
            for operation in ["seed", "check", "check"]:
                if operation == "seed":
                    created = True  # Clean up even if seed only partially succeeds.
                stdout, _ = run([str(installed / "Contents/MacOS/Probe"), operation, nonce])
                steps.append(stdout.strip())
                print(stdout.strip(), flush=True)
            # A normal update replaces the app at its installation path, after
            # all previous processes have exited. Never overwrite a live binary.
            shutil.move(installed, folder / "previous-installed.app")
            shutil.copytree(second, installed)
            for app, operation in [(installed, "check"), (outsider, "expect-denied")]:
                try:
                    stdout, _ = run([str(app / "Contents/MacOS/Probe"), operation, nonce])
                    steps.append(stdout.strip())
                    print(stdout.strip(), flush=True)
                except RuntimeError as error:
                    failures.append(str(error))
                    print("FAIL: " + operation + ": " + str(error), flush=True)
        finally:
            if created:
                shutil.rmtree(installed)
                shutil.copytree(first, installed)
                stdout, _ = run([str(installed / "Contents/MacOS/Probe"), "cleanup", nonce])
                print(stdout.strip(), flush=True)
                steps.append(stdout.strip())
        report.write_text(json.dumps({"result": "failed" if failures else "passed", "steps": steps,
                                      "failures": failures,
                                      "buildHashes": [first_hash, second_hash],
                                      "sameDesignatedRequirement": True,
                                      "updateAtSameInstallPath": True,
                                      "usesProductionVault": True,
                                      "credentialService": "isolated synthetic entries",
                                      "authorizationDialogsAllowed": False,
                                      "existingAccountMigrationTested": False}, indent=2) + "\n")
        print("Report: " + str(report))
        if failures:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
