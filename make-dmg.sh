#!/bin/bash
# 把 UsageMeter.app 包成可分享的 DMG(未公證;對方需手動放行 Gatekeeper)。
set -e
cd "$(dirname "$0")"

APP="UsageMeter.app"
if [ -z "${VERSION:-}" ]; then
  if git describe --tags --abbrev=0 >/dev/null 2>&1; then
    VERSION="$(git describe --tags --abbrev=0 | sed 's/^v//')"
  else
    VERSION="0.1"
  fi
fi
export VERSION
DMG="${DMG_NAME:-UsageMeter-$VERSION.dmg}"
LATEST_DMG="UsageMeter.dmg"
VOL="UsageMeter $VERSION"

# 先建置並組裝 .app(arm64、ad-hoc 簽章)
./package.sh

echo "▶ 製作 DMG…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"      # 讓使用者拖曳安裝
rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
if [ "$DMG" != "$LATEST_DMG" ]; then
  cp "$DMG" "$LATEST_DMG"
fi

echo "✓ 完成:$(pwd)/$DMG  ($(du -h "$DMG" | cut -f1))"
if [ "$DMG" != "$LATEST_DMG" ]; then
  echo "  也已更新:$(pwd)/$LATEST_DMG"
fi
echo
echo "── 給對方的安裝說明 ──"
echo "1. 打開 UsageMeter.dmg,把 UsageMeter 拖到 Applications。"
echo "2. 第一次開啟被 Gatekeeper 擋時(未公證 app):"
echo "   macOS 15:系統設定 → 隱私權與安全性 → 捲到底「仍要打開」。"
echo "   或終端機執行:xattr -dr com.apple.quarantine /Applications/UsageMeter.app"
echo "3. 首次讀取各家用量時,Keychain 會詢問存取權限,按「一律允許」。"
echo "※ 此 app 為 arm64(Apple Silicon)。Intel Mac 需另做 universal binary。"
