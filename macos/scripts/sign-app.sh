#!/bin/bash
set -euo pipefail

# Internal distribution uses a persistent local certificate without Apple membership.
# This preserves identity, but cannot guarantee Keychain consent across app updates.
APP_PATH="${1:?Usage: sign-app.sh staged-app [previous-app]}"
PREVIOUS_APP_PATH="${2:-}"
SIGNING_MODE="${WIFI_SWITCH_SIGNING_MODE:-internal}"
SIGNING_IDENTITY="${WIFI_SWITCH_SIGNING_IDENTITY:-}"
case "$SIGNING_MODE" in
    internal)
        SIGNING_IDENTITY="${SIGNING_IDENTITY:-WiFi Switch Local Signing}"
        printf '%s\n' '内部使用构建：无需开发者会员；未公证，更新后钥匙串可能需要重新授权。' >&2
        ;;
    developer-id)
        if [ -z "$SIGNING_IDENTITY" ]; then
            printf '%s\n' 'Developer ID 模式需设置 WIFI_SWITCH_SIGNING_IDENTITY。内部打包无需设置此模式。' >&2
            exit 1
        fi
        ;;
    *) printf '%s\n' '未知 WIFI_SWITCH_SIGNING_MODE；可用 internal 或 developer-id。' >&2; exit 1 ;;
esac
if [ "$SIGNING_IDENTITY" = "-" ]; then
    printf '%s\n' '拒绝临时签名：它会使更新后的钥匙串授权失效。请使用固定的代码签名证书，详见 docs/signing.md。' >&2
    exit 1
fi

PREVIOUS_REQUIREMENT=""
if [ -n "$PREVIOUS_APP_PATH" ] && [ -d "$PREVIOUS_APP_PATH" ]; then
    PREVIOUS_SIGNATURE="$(codesign -dv "$PREVIOUS_APP_PATH" 2>&1)"
    codesign --verify --deep --strict "$PREVIOUS_APP_PATH"
    if [[ "$PREVIOUS_SIGNATURE" == *"Signature=adhoc"* ]]; then
        printf '%s\n' '旧版使用临时签名；改为固定证书后，已有密码可能需要重新授权。'
    else
        PREVIOUS_REQUIREMENT="$(codesign -d -r- "$PREVIOUS_APP_PATH" 2>/dev/null | sed -n 's/^#* *designated => //p')"
        if [ -z "$PREVIOUS_REQUIREMENT" ]; then
            printf '%s\n' '无法确认旧版应用的签名身份，已停止替换。' >&2
            exit 1
        fi
    fi
fi

SIGN_ARGUMENTS=(--force --sign "$SIGNING_IDENTITY" --identifier org.wifiswitch.WiFiSwitch)
if [ "$SIGNING_MODE" = "developer-id" ]; then
    SIGN_ARGUMENTS+=(--options runtime --timestamp)
fi
if [ -n "${WIFI_SWITCH_SIGNING_KEYCHAIN:-}" ]; then
    SIGN_ARGUMENTS+=(--keychain "$WIFI_SWITCH_SIGNING_KEYCHAIN")
fi
if ! codesign "${SIGN_ARGUMENTS[@]}" "$APP_PATH"; then
    printf '%s\n' '固定证书签名失败，旧版应用未替换。请先配置代码签名证书，详见 docs/signing.md；不会回退到临时签名。' >&2
    exit 1
fi
codesign --verify --deep --strict "$APP_PATH"
CURRENT_SIGNATURE="$(codesign -dv "$APP_PATH" 2>&1)"
if [[ "$CURRENT_SIGNATURE" == *"Signature=adhoc"* ]]; then
    printf '%s\n' '产物仍是临时签名，已停止替换。' >&2
    exit 1
fi
if [ "$SIGNING_MODE" = "developer-id" ]; then
    DEVELOPER_ID_REQUIREMENT='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]'
    if ! codesign --verify --strict "-R=$DEVELOPER_ID_REQUIREMENT" "$APP_PATH"; then
        printf '%s\n' '签名不是 Apple 签发的 Developer ID Application，已停止发行替换。个人开发者账号即可申请；本地自签名不满足跨版本免授权要求。' >&2
        exit 1
    fi
fi
if [ -n "$PREVIOUS_REQUIREMENT" ]; then
    # The public namespace is neutral. Keep every certificate constraint when
    # checking an older product identity; only normalize its bundle identifier.
    PREVIOUS_REQUIREMENT="$(python3 - "$PREVIOUS_REQUIREMENT" <<'PY'
import re, sys
print(re.sub(r'\bidentifier "[^"]+\.WiFiSwitch"',
             'identifier "org.wifiswitch.WiFiSwitch"', sys.argv[1], count=1))
PY
)"
    if ! codesign --verify --strict "-R=$PREVIOUS_REQUIREMENT" "$APP_PATH"; then
        printf '%s\n' '新版本不符合旧版本的签名身份，已停止替换。请使用原来的证书，不要为每次构建重新创建证书。' >&2
        exit 1
    fi
fi
