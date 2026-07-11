#!/bin/bash
# 建置並打包成 menu bar .app(無 Dock 圖示),嵌入 Sparkle.framework。
# 因專案在 Google Drive,建置產物導到本機磁碟避免 sqlite I/O error。
set -euo pipefail
cd "$(dirname "$0")"

SCRATCH="${SCRATCH:-$HOME/Library/Caches/usagemeter-build}"
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

# Sparkle appcast + EdDSA 公鑰(generate_keys -p 產出;私鑰在 secrets/ 或 Actions secret)
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-+M0RGQsB7Ivk8ZCt96TeHj1PMqcFa39r8ShE+l4FXts=}"
SU_FEED_URL="${SU_FEED_URL:-https://raw.githubusercontent.com/cpn565-stack/ai-usage-meter/main/appcast/appcast.xml}"

echo "▶ 建置 (release, version $VERSION build $BUILD_NUMBER)…"
swift build -c release --scratch-path "$SCRATCH"
BIN="$SCRATCH/release/UsageMeter"

# 找 Sparkle.framework(SwiftPM binary artifact)
FRAMEWORK=""
for cand in \
  "$SCRATCH/arm64-apple-macosx/release/Sparkle.framework" \
  ".build/arm64-apple-macosx/release/Sparkle.framework" \
  ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
do
  if [ -d "$cand" ]; then FRAMEWORK="$cand"; break; fi
done
if [ -z "$FRAMEWORK" ]; then
  FRAMEWORK="$(find .build "$SCRATCH" -path '*/Sparkle.framework' -type d 2>/dev/null | head -1 || true)"
fi
if [ -z "$FRAMEWORK" ] || [ ! -d "$FRAMEWORK" ]; then
  echo "✗ 找不到 Sparkle.framework — 請先 swift build" >&2
  exit 1
fi
echo "  Sparkle: $FRAMEWORK"

echo "▶ 組裝 $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/UsageMeter"
if [ -f "Assets/AppIcon.icns" ]; then
  cp "Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# 嵌入 Sparkle(必須在 codesign 前)
cp -R "$FRAMEWORK" "$APP/Contents/Frameworks/"
# 執行時從 Frameworks 載入
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/UsageMeter" 2>/dev/null || true

# strip 符號(在簽章前做;簽章會封存二進位,事後改動會失效)。
strip -rSTx "$APP/Contents/MacOS/UsageMeter" || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>UsageMeter</string>
  <key>CFBundleIdentifier</key><string>com.mike.usagemeter</string>
  <key>CFBundleName</key><string>UsageMeter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>SUFeedURL</key><string>${SU_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_ED_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>SUAllowsAutomaticUpdates</key><true/>
</dict>
</plist>
PLIST

# 簽章策略:
# 1) APPLE_CODESIGN_IDENTITY (Developer ID Application: …) — 正式 / 可公證
# 2) UsageMeter Self-Signed — 本機穩定自簽
# 3) ad-hoc (-)
if [ -n "${APPLE_CODESIGN_IDENTITY:-}" ]; then
  echo "▶ Developer ID 簽章:$APPLE_CODESIGN_IDENTITY"
  ENTITLEMENTS="${ENTITLEMENTS_FILE:-}"
  CODESIGN_ARGS=(--force --deep --options runtime --timestamp --sign "$APPLE_CODESIGN_IDENTITY")
  if [ -n "$ENTITLEMENTS" ] && [ -f "$ENTITLEMENTS" ]; then
    CODESIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
  fi
  # 先簽 framework 再簽 app
  codesign "${CODESIGN_ARGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework" || \
    codesign --force --deep --sign "$APPLE_CODESIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
  codesign "${CODESIGN_ARGS[@]}" "$APP"
elif security find-identity -p codesigning 2>/dev/null | grep -q "UsageMeter Self-Signed"; then
  echo "▶ 用穩定身分簽章:UsageMeter Self-Signed"
  codesign --force --deep --timestamp=none --sign "UsageMeter Self-Signed" "$APP"
else
  echo "▶ ad-hoc 簽章(執行 ./setup-signing.sh 或設 APPLE_CODESIGN_IDENTITY 可改善)…"
  codesign --force --deep --sign - "$APP"
fi

echo "✓ 完成:$(pwd)/$APP"
echo "  啟動:open \"$APP\"   (或拖到 /Applications)"
echo "  Sparkle feed: $SU_FEED_URL"
