"""Read-only verification that the macOS project relocation did not change its contents."""
import hashlib
import json
from pathlib import Path

windows = Path(__file__).resolve().parents[1]
baseline = json.loads((windows/"docs/macos-preservation.json").read_text())
macos = windows.parent/"macos"
for relative, expected in baseline["sha256"].items():
    actual = hashlib.sha256((macos/relative).read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f"Mac project content changed: {relative}")
print(f'PASS: {len(baseline["sha256"])} macOS files unchanged after relocation')
