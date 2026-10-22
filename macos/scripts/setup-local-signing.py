#!/usr/bin/env python3
"""One-time setup on the packaging Mac; never runs in an installed application."""
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
NAME = "WiFi Switch Local Signing"
SECURITY = "/usr/bin/security"
OPENSSL = "/usr/bin/openssl"


def run(args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        # These tools write private material only to explicit files, never stderr.
        # Do not include stdout or full command arguments in diagnostics.
        detail = result.stderr.strip()[-2000:]
        operation = " " + args[1] if args[0] in (SECURITY, OPENSSL) else ""
        raise SystemExit(f"{Path(args[0]).name}{operation} failed (exit {result.returncode}); no application was replaced.\n{detail}")
    return result.stdout


def main():
    os.umask(0o077)
    print("Local development identity only: self-signing does not preserve Keychain access across different builds.", flush=True)
    keychain = shlex.split(run([SECURITY, "default-keychain", "-d", "user"]))
    if len(keychain) != 1:
        raise SystemExit("Cannot determine the user's default keychain.")
    keychain = keychain[0]
    listing = run([SECURITY, "find-identity", "-p", "codesigning", keychain])
    identities = set(re.findall(r'\d+\)\s+([0-9A-Fa-f]{40})\s+"' + re.escape(NAME) + r'"', listing))
    if len(identities) == 1:
        print("Reusing existing local signing identity: " + next(iter(identities)))
        return
    if identities:
        raise SystemExit("Multiple local identities found; select an existing fingerprint explicitly.")
    certificate = subprocess.run([SECURITY, "find-certificate", "-c", NAME, keychain],
                                 capture_output=True, text=True)
    if certificate.returncode == 0:
        raise SystemExit("A certificate already exists without a usable identity; restore its private key instead of creating another.")
    if certificate.returncode != 44:  # errSecItemNotFound
        raise SystemExit("Could not check existing certificates; refusing to create a duplicate.")

    with tempfile.TemporaryDirectory(prefix="wifi-switch-signing-") as temporary:
        folder = Path(temporary)
        passfile = folder / "passphrase"
        passfile.write_text(secrets.token_hex(32) + "\n")
        key_passfile = folder / "key-passphrase"
        key_passfile.write_text(secrets.token_hex(32) + "\n")
        config = folder / "certificate.cnf"
        config.write_text("""[req]
prompt = no
distinguished_name = subject
x509_extensions = codesign
[subject]
CN = WiFi Switch Local Signing
[codesign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
        private_key = folder / "encrypted-private-key.pem"
        certificate_path = folder / "certificate.pem"
        container = folder / "identity.p12"
        run([OPENSSL, "req", "-new", "-x509", "-newkey", "rsa:3072", "-sha256", "-days", "3650",
             "-config", str(config), "-keyout", str(private_key), "-out", str(certificate_path),
             "-passout", "file:" + str(key_passfile)])
        run([OPENSSL, "pkcs12", "-export", "-inkey", str(private_key), "-in", str(certificate_path),
             "-out", str(container), "-name", NAME, "-passin", "file:" + str(key_passfile),
             "-passout", "file:" + str(passfile)])
        module_cache = ROOT / ".build/module-cache"
        module_cache.mkdir(parents=True, exist_ok=True)
        importer = folder / "import-signing-identity"
        run(["/usr/bin/swiftc", "-module-cache-path", str(module_cache),
             str(ROOT / "scripts/import-signing-identity.swift"), "-o", str(importer)])
        run([str(importer), str(container), str(passfile), keychain])
        fingerprint = run([OPENSSL, "x509", "-in", str(certificate_path), "-noout", "-fingerprint", "-sha1"])
        fingerprint = fingerprint.strip().split("=", 1)[1].replace(":", "")
        listing = run([SECURITY, "find-identity", "-p", "codesigning", keychain])
        if fingerprint not in listing:
            raise SystemExit("Certificate imported but identity verification failed; do not create a replacement automatically.")
        print("Created local signing identity: " + fingerprint)
        print("Kept in the packaging user's keychain. Temporary private-key files removed on exit.")
        print("No certificate trust settings, Wi-Fi passwords, or network settings were changed.")


if __name__ == "__main__":
    main()
