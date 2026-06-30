#!/bin/bash
# 建置並打包成 menu bar .app(無 Dock 圖示)。
# 因專案在 Google Drive,建置產物導到本機磁碟避免 sqlite I/O error。
set -e
cd "$(dirname "$0")"

SCRATCH="$HOME/Library/Caches/usagemeter-build"
APP="UsageMeter.app"
if [ -z "${VERSION:-}" ]; then
  if git describe --tags --abbrev=0 >/dev/null 2>&1; then
    VERSION="$(git describe --tags --abbrev=0 | sed 's/^v//')"
  else
    VERSION="0.1"
  fi
fi
if [ -z "${BUILD_NUMBER:-}" ]; then
  BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
fi

echo "▶ 建置 (release, version $VERSION build $BUILD_NUMBER)…"
swift build -c release --scratch-path "$SCRATCH"
BIN="$SCRATCH/release/UsageMeter"

echo "▶ 組裝 $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/UsageMeter"
if [ -f "Assets/AppIcon.icns" ]; then
  mkdir -p "$APP/Contents/Resources"
  cp "Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# strip 符號(在簽章前做;簽章會封存二進位,事後改動會失效)。約砍一半體積。
strip -rSTx "$APP/Contents/MacOS/UsageMeter"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>UsageMeter</string>
  <key>CFBundleIdentifier</key><string>com.mike.usagemeter</string>
  <key>CFBundleName</key><string>UsageMeter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>__VERSION__</string>
  <key>CFBundleVersion</key><string>__BUILD_NUMBER__</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# 優先用穩定自簽身分(讓 keychain「永遠允許」跨版本記住);沒有就退回 ad-hoc。
SIGN_ID="UsageMeter Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "▶ 用穩定身分簽章:$SIGN_ID"
  codesign --force --deep --timestamp=none --sign "$SIGN_ID" "$APP"
else
  echo "▶ ad-hoc 簽章(未設定穩定身分,執行 ./setup-signing.sh 可改善)…"
  codesign --force --deep --sign - "$APP"
fi

echo "✓ 完成:$(pwd)/$APP"
echo "  啟動:open \"$APP\"   (或拖到 /Applications)"
