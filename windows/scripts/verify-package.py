"""Inspect built PE artifacts and payload isolation; this is not Windows runtime acceptance."""
from pathlib import Path
import hashlib
import json
import struct
import subprocess
import sys
import tempfile
import shutil

root = Path(__file__).resolve().parents[1]
installer = Path(sys.argv[1]).resolve()
app = root / "artifacts/publish/WiFiSwitch.exe"

def machine(path):
    data = path.read_bytes()
    assert data[:2] == b"MZ", f"{path} is not a PE file"
    offset, = struct.unpack_from("<I", data, 0x3c)
    assert data[offset:offset+4] == b"PE\0\0"
    return struct.unpack_from("<H", data, offset+4)[0]

assert machine(app) == 0x8664, "Application must be native x64"
assert machine(installer) == 0x14c, "Expected standard NSIS x86 installer bootstrap"
assert installer.stat().st_size > 1_000_000
assert (root/"README.md").read_bytes() == (root/"artifacts/publish/README.txt").read_bytes()
payload = sorted(p.name for p in (root/"artifacts/publish").iterdir() if p.is_file())
assert payload == ["README.txt", "WiFiSwitch.exe"], f"Unexpected deployable files: {payload}"
extractor = shutil.which("7zz") or shutil.which("7z")
if not extractor:
    raise SystemExit("Install 7-Zip to independently verify the compressed installer payload")
with tempfile.TemporaryDirectory(prefix="installer-inspection-") as temporary:
    subprocess.run([extractor, "x", "-y", "-o"+temporary, str(installer)],
                   check=True, stdout=subprocess.DEVNULL)
    extracted = Path(temporary)
    paths = {p.relative_to(extracted).as_posix() for p in extracted.rglob("*") if p.is_file()}
    assert paths == {"WiFiSwitch.exe", "README.txt", "Uninstall.exe",
                     "$PLUGINSDIR/modern-wizard.bmp", "$PLUGINSDIR/nsDialogs.dll", "$PLUGINSDIR/System.dll"}, paths
    assert (extracted/"WiFiSwitch.exe").read_bytes() == app.read_bytes()
    assert (extracted/"README.txt").read_bytes() == (root/"README.md").read_bytes()
    assert machine(extracted/"Uninstall.exe") == 0x14c
digest = hashlib.sha256(installer.read_bytes()).hexdigest()
installer.with_suffix(installer.suffix+".sha256").write_text(f"{digest}  {installer.name}\n")
report = {"installer": installer.name, "installerSha256": digest, "applicationMachine": "AMD64",
          "installerBootstrap": "NSIS x86, x64 OS required", "payload": payload,
          "independentArchiveExtraction": "passed",
          "windowsRuntimeVerified": False, "realWiFiVerified": False}
(root/"artifacts/package-verification.json").write_text(json.dumps(report, indent=2)+"\n")
print(json.dumps(report, indent=2))
