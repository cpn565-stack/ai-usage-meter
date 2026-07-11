#!/bin/bash
# 本機 / CI 公證草稿。
# 需要:
#   APPLE_CODESIGN_IDENTITY  e.g. "Developer ID Application: Your Name (TEAMID)"
#   APPLE_ID                 Apple ID email
#   APPLE_TEAM_ID            10-char Team ID
#   APPLE_APP_SPECIFIC_PASSWORD  or  keychain profile via notarytool store-credentials
#   APP=UsageMeter.app  DMG=UsageMeter-x.y.z.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP:-UsageMeter.app}"
DMG="${1:-}"
if [ -z "$DMG" ]; then
  DMG="$(ls -t UsageMeter-*.dmg 2>/dev/null | head -1 || true)"
fi
if [ -z "$DMG" ] || [ ! -f "$DMG" ]; then
  echo "用法: $0 <UsageMeter-x.y.z.dmg>" >&2
  exit 1
fi

if [ -z "${APPLE_CODESIGN_IDENTITY:-}" ]; then
  echo "✗ 請設定 APPLE_CODESIGN_IDENTITY (Developer ID Application: …)" >&2
  echo "  目前僅能 ad-hoc / self-signed,無法公證。" >&2
  exit 2
fi

echo "▶ 以 Developer ID 重新簽章 $APP …"
export APPLE_CODESIGN_IDENTITY
./package.sh

# 重新打包 dmg(已簽好的 app)
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
export VERSION
./make-dmg.sh
DMG="UsageMeter-${VERSION}.dmg"

echo "▶ 提交公證 $DMG …"
if [ -n "${APPLE_API_KEY_PATH:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ] && [ -n "${APPLE_API_ISSUER:-}" ]; then
  xcrun notarytool submit "$DMG" \
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER" \
    --wait
elif [ -n "${NOTARYTOOL_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
else
  cat >&2 <<EOF
✗ 未設定 notarytool 認證。任選一種:

  A) App Store Connect API key (推薦 CI):
     APPLE_API_KEY_PATH / APPLE_API_KEY_ID / APPLE_API_ISSUER

  B) 本機 keychain profile:
     xcrun notarytool store-credentials "usage-meter-notary" ...
     NOTARYTOOL_PROFILE=usage-meter-notary

  C) Apple ID + app-specific password:
     APPLE_ID / APPLE_APP_SPECIFIC_PASSWORD / APPLE_TEAM_ID

詳見 docs/DISTRIBUTION.md
EOF
  exit 3
fi

echo "▶ staple …"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "✓ 公證完成:$DMG"
