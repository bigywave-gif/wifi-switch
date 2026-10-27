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
cp Resources/UserGuide.txt "$STAGE/payload/使用说明.txt"
cp CHANGELOG.md "$STAGE/payload/CHANGELOG.md"
cp CHANGELOG.md "$STAGE/payload/CHANGELOG.txt"
cp docs/signing.md "$STAGE/payload/docs/signing.md"
ln -s /Applications "$STAGE/payload/Applications"
/usr/bin/codesign --verify --deep --strict "$STAGE/payload/WiFi Switch.app"
# Build the HFS+ filesystem from file contents, omitting host extended attributes.
# The final download remains a compressed DMG with the Applications shortcut.
/usr/bin/hdiutil makehybrid -quiet -hfs -hfs-volume-name "WiFi Switch $VERSION" \
    -o "$STAGE/payload.dmg" "$STAGE/payload"
# makehybrid adds FinderInfo; clear it on the staging image before compression
# so code signing stays valid. Never follow the /Applications symlink.
/usr/bin/hdiutil attach -readwrite -nobrowse -mountpoint "$MOUNT_PATH" "$STAGE/payload.dmg"
MOUNTED=1
python3 - "$MOUNT_PATH" <<'PY'
from pathlib import Path
import subprocess, sys
root = Path(sys.argv[1])
for path in [root, *root.rglob("*")]:
    if not path.is_symlink():
        subprocess.run(["xattr", "-c", str(path)], check=True)
PY
/usr/bin/codesign --verify --deep --strict "$MOUNT_PATH/WiFi Switch.app"
python3 scripts/check-bundle-privacy.py "$MOUNT_PATH" --filesystem-metadata
/usr/bin/hdiutil detach "$MOUNT_PATH"
MOUNTED=0
/usr/bin/hdiutil convert -quiet "$STAGE/payload.dmg" -format UDZO -o "$STAGE/$PACKAGE_NAME.dmg"
/usr/bin/hdiutil verify "$STAGE/$PACKAGE_NAME.dmg"
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_PATH" "$STAGE/$PACKAGE_NAME.dmg"
MOUNTED=1
/usr/bin/codesign --verify --deep --strict "$MOUNT_PATH/WiFi Switch.app"
python3 scripts/check-bundle-privacy.py "$MOUNT_PATH" --filesystem-metadata
cmp Resources/UserGuide.txt "$MOUNT_PATH/使用说明.txt"
cmp Resources/UserGuide.txt "$MOUNT_PATH/WiFi Switch.app/Contents/Resources/UserGuide.txt"
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
