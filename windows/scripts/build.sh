#!/bin/bash
set -euo pipefail
WINDOWS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WINDOWS_ROOT"
DOTNET="${DOTNET:-$WINDOWS_ROOT/.tools/dotnet/dotnet}"
if [ ! -x "$DOTNET" ]; then DOTNET="$(command -v dotnet)"; fi
MAKENSIS="${MAKENSIS:-$(command -v makensis)}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_CLI_HOME="$WINDOWS_ROOT/.tools/home"
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
export DOTNET_GENERATE_ASPNET_CERTIFICATE=false
mkdir -p artifacts dist
"$DOTNET" run --project tests/WiFiSwitch.Tests -c Release > artifacts/core-tests.log
"$DOTNET" publish src/WiFiSwitch.Windows -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:EnableCompressionInSingleFile=true -p:DebugType=None -p:DebugSymbols=false \
  -o artifacts/publish
cp README.md artifacts/publish/README.txt
"$MAKENSIS" -DVERSION=0.1.9 "-DPAYLOAD=$WINDOWS_ROOT/artifacts/publish" \
  "-DOUTPUT=$WINDOWS_ROOT/dist/WiFi-Switch-0.1.9-windows-x64-setup.exe" installer/WiFiSwitch.nsi
python3 scripts/verify-package.py dist/WiFi-Switch-0.1.9-windows-x64-setup.exe
