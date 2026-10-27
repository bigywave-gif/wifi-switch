#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
BUILD_ROOT="${WIFI_SWITCH_BUILD_ROOT:-$PROJECT_ROOT/.build}"
mkdir -p .build/module-cache .build/clang-cache dist
mkdir -p "$BUILD_ROOT/module-cache" "$BUILD_ROOT/clang-cache"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/module-cache"
swift build --disable-sandbox --scratch-path "$BUILD_ROOT" --cache-path "$BUILD_ROOT/cache" \
    --config-path "$BUILD_ROOT/config" --security-path "$BUILD_ROOT/security" \
    -c "$BUILD_CONFIGURATION"
FINAL_APP_PATH="$PROJECT_ROOT/dist/WiFi Switch.app"
if [ "${WIFI_SWITCH_LOCAL_BUILD:-0}" = "1" ]; then
    mkdir -p "$PROJECT_ROOT/dist/local"
    FINAL_APP_PATH="$PROJECT_ROOT/dist/local/WiFi Switch.app"
fi
APP_STAGE="$(mktemp -d "$PROJECT_ROOT/.build/app-stage.XXXXXX")"
APP_PATH="$APP_STAGE/WiFi Switch.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BUILD_ROOT/$BUILD_CONFIGURATION/WiFiSwitch" "$APP_PATH/Contents/MacOS/WiFiSwitch"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
if [ "${WIFI_SWITCH_SIGNING_MODE:-internal}" = "developer-id" ]; then
    /usr/libexec/PlistBuddy -c 'Set :WiFiSwitchDistribution Developer ID 签名版' "$APP_PATH/Contents/Info.plist"
fi
cp Resources/UserGuide.txt "$APP_PATH/Contents/Resources/UserGuide.txt"
cp CHANGELOG.md "$APP_PATH/Contents/Resources/CHANGELOG.txt"
if [ ! -f "$PROJECT_ROOT/.build/AppIcon.icns" ] || [ scripts/make-icon.swift -nt "$PROJECT_ROOT/.build/AppIcon.icns" ] || [ scripts/package-icon.py -nt "$PROJECT_ROOT/.build/AppIcon.icns" ]; then
    swift -module-cache-path "$PROJECT_ROOT/.build/module-cache" scripts/make-icon.swift "$PROJECT_ROOT/.build/icon.png"
    ICONSET="$PROJECT_ROOT/.build/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" .build/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" .build/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    python3 scripts/package-icon.py "$ICONSET" "$PROJECT_ROOT/.build/AppIcon.icns"
fi
cp .build/AppIcon.icns "$APP_PATH/Contents/Resources/AppIcon.icns"
bash scripts/sign-app.sh "$APP_PATH" "$FINAL_APP_PATH"
# Preserve the previous bundle intact so rebuilding cannot overwrite a running executable.
if [ -d "$FINAL_APP_PATH" ]; then
    mv "$FINAL_APP_PATH" "$APP_STAGE/Previous WiFi Switch.app"
fi
mv "$APP_PATH" "$FINAL_APP_PATH"
printf 'Built: %s\n' "$FINAL_APP_PATH"
