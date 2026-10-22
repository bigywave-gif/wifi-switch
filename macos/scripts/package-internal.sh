#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

python3 scripts/check-release.py
WIFI_SWITCH_SIGNING_MODE=internal WIFI_SWITCH_LOCAL_BUILD=0 bash scripts/build-app.sh
APP_PATH="$PROJECT_ROOT/dist/WiFi Switch.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
ARCH="$(/usr/bin/lipo -archs "$APP_PATH/Contents/MacOS/WiFiSwitch" | tr ' ' '-')"
PACKAGE_NAME="WiFi-Switch-${VERSION}-${ARCH}-internal"
STAGE="$(mktemp -d "$PROJECT_ROOT/.build/package-stage.XXXXXX")"
MOUNT_PATH="$STAGE/mounted"
MOUNTED=0
cleanup() {
    if [ "$MOUNTED" = "1" ]; then
        if ! /usr/bin/hdiutil detach "$MOUNT_PATH"; then
            printf '无法推出校验磁盘，请手动推出：%s\n' "$MOUNT_PATH" >&2
            return
        fi
    fi
    rm -rf "$STAGE"
}
trap cleanup EXIT
mkdir -p "$STAGE/payload/docs" "$MOUNT_PATH"
/usr/bin/ditto "$APP_PATH" "$STAGE/payload/WiFi Switch.app"
cp README.md "$STAGE/payload/README.md"
cp README.md "$STAGE/payload/README.txt"
cp CHANGELOG.md "$STAGE/payload/CHANGELOG.md"
cp CHANGELOG.md "$STAGE/payload/CHANGELOG.txt"
cp docs/signing.md "$STAGE/payload/docs/signing.md"
ln -s /Applications "$STAGE/payload/Applications"
/usr/bin/codesign --verify --deep --strict "$STAGE/payload/WiFi Switch.app"
/usr/bin/hdiutil create -quiet -volname "WiFi Switch $VERSION" \
    -srcfolder "$STAGE/payload" -format UDZO "$STAGE/$PACKAGE_NAME.dmg"
/usr/bin/hdiutil verify "$STAGE/$PACKAGE_NAME.dmg"
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_PATH" "$STAGE/$PACKAGE_NAME.dmg"
MOUNTED=1
/usr/bin/codesign --verify --deep --strict "$MOUNT_PATH/WiFi Switch.app"
cmp README.md "$MOUNT_PATH/README.md"
cmp README.md "$MOUNT_PATH/README.txt"
cmp README.md "$MOUNT_PATH/WiFi Switch.app/Contents/Resources/README.txt"
cmp CHANGELOG.md "$MOUNT_PATH/CHANGELOG.md"
cmp CHANGELOG.md "$MOUNT_PATH/CHANGELOG.txt"
cmp CHANGELOG.md "$MOUNT_PATH/WiFi Switch.app/Contents/Resources/CHANGELOG.txt"
cmp docs/signing.md "$MOUNT_PATH/docs/signing.md"
cmp "$APP_PATH/Contents/MacOS/WiFiSwitch" "$MOUNT_PATH/WiFi Switch.app/Contents/MacOS/WiFiSwitch"
test "$(readlink "$MOUNT_PATH/Applications")" = /Applications
/usr/bin/hdiutil detach "$MOUNT_PATH"
MOUNTED=0
mv "$STAGE/$PACKAGE_NAME.dmg" "$PROJECT_ROOT/dist/$PACKAGE_NAME.dmg"
(cd dist && /usr/bin/shasum -a 256 "$PACKAGE_NAME.dmg" > "$PACKAGE_NAME.dmg.sha256")
python3 scripts/check-release.py --record
printf 'Packaged and verified: %s\n' "$PROJECT_ROOT/dist/$PACKAGE_NAME.dmg"
