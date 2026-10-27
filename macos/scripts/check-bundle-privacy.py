#!/usr/bin/env python3
"""Reject local user paths and private data files before a bundle is signed."""
from pathlib import Path
import re
import subprocess
import sys


def findings(root, check_metadata=False):
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        if check_metadata:
            attributes = subprocess.check_output(["xattr", str(path)], text=True).splitlines()
            if any(name in attributes for name in
                    ("com.apple.provenance", "com.apple.quarantine", "com.apple.metadata:kMDItemWhereFroms")):
                yield relative, "host provenance metadata"
        name = path.name.lower()
        if (name.startswith(("accounts.json", "accounts-pre-v", ".env"))
                or path.suffix.lower() in {".log", ".db", ".sqlite", ".sqlite3", ".p12", ".pfx", ".key", ".pem", ".keychain-db"}):
            yield relative, "private data filename"
        data = path.read_bytes()
        # Match ASCII/UTF-8 and UTF-16LE strings without printing private values.
        for encoding in ("utf-8", "utf-16le"):
            text = data.decode(encoding, errors="ignore")
            if re.search(r"/Users/[^/\s]+/|/home/[^/\s]+/|[A-Za-z]:\\Users\\[^\\\s]+\\", text):
                yield relative, "local user path"
                break
        if re.search(rb"-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----", data):
            yield relative, "private key"


if __name__ == "__main__":
    root = Path(sys.argv[1])
    if not root.is_dir():
        raise SystemExit("Bundle directory does not exist")
    errors = list(findings(root, "--filesystem-metadata" in sys.argv[2:]))
    for path, reason in errors:
        print(f"Privacy check failed: {path}: {reason}", file=sys.stderr)
    if errors:
        raise SystemExit(1)
    print("Bundle privacy check passed: no local user paths or private data files")
