#!/bin/bash
# 從 Release DMG 產生 Sparkle appcast.xml
#
# 用法:
#   VERSION=0.2.3 ./scripts/generate-appcast.sh UsageMeter-0.2.3.dmg
#
# 環境變數:
#   SPARKLE_PRIVATE_KEY_FILE  私鑰檔(預設 secrets/sparkle_ed_private.key)
#   APPCAST_OUT               輸出路徑(預設 appcast/appcast.xml)
#   DOWNLOAD_BASE_URL         enclosure 下載前綴
#                             預設 https://github.com/cpn565-stack/ai-usage-meter/releases/download/v$VERSION
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:-}"
if [ -z "$DMG" ] || [ ! -f "$DMG" ]; then
  echo "用法: $0 <UsageMeter-x.y.z.dmg>" >&2
  exit 1
fi

VERSION="${VERSION:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(basename "$DMG" | sed -E 's/UsageMeter-//;s/\.dmg$//')"
fi
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-secrets/sparkle_ed_private.key}"
OUT="${APPCAST_OUT:-appcast/appcast.xml}"
DOWNLOAD_BASE="${DOWNLOAD_BASE_URL:-https://github.com/cpn565-stack/ai-usage-meter/releases/download/v${VERSION}}"
TITLE="${APPCAST_TITLE:-UsageMeter $VERSION}"
NOTES_HTML="${APPCAST_NOTES_HTML:-<p>See <a href=\"https://github.com/cpn565-stack/ai-usage-meter/releases/tag/v${VERSION}\">release notes</a>.</p>}"

GEN_APPCAST=""
for cand in \
  .build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  "$HOME/Library/Caches/usagemeter-build/artifacts/sparkle/Sparkle/bin/generate_appcast"
do
  if [ -x "$cand" ]; then GEN_APPCAST="$cand"; break; fi
done

mkdir -p "$(dirname "$OUT")" appcast/_staging
STAGE="appcast/_staging"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$DMG" "$STAGE/"

if [ -n "$GEN_APPCAST" ] && [ -f "$KEY_FILE" ]; then
  echo "▶ generate_appcast (Sparkle)…"
  # generate_appcast 掃描目錄內 dmg/zip 並寫 appcast
  "$GEN_APPCAST" -f "$KEY_FILE" "$STAGE" 2>&1 || true
  if [ -f "$STAGE/appcast.xml" ]; then
    # 修正 enclosure URL 為 GitHub Releases 永久連結
    sed -E "s#url=\"[^\"]+$(basename "$DMG")\"#url=\"${DOWNLOAD_BASE}/$(basename "$DMG")\"#g" \
      "$STAGE/appcast.xml" > "$OUT"
    echo "✓ 寫入 $OUT"
    cat "$OUT"
    exit 0
  fi
  echo "  generate_appcast 未產出 xml,改用手寫 appcast…"
fi

# 手寫 fallback(仍建議用 generate_appcast + 私鑰簽 enclosure)
LENGTH="$(wc -c < "$DMG" | tr -d ' ')"
PUB_DATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
ED_SIG=""
if [ -f "$KEY_FILE" ] && [ -x .build/artifacts/sparkle/Sparkle/bin/sign_update ]; then
  ED_SIG="$(.build/artifacts/sparkle/Sparkle/bin/sign_update -f "$KEY_FILE" "$DMG" 2>/dev/null | tail -1 || true)"
fi

cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>UsageMeter</title>
    <link>https://github.com/cpn565-stack/ai-usage-meter</link>
    <description>UsageMeter updates</description>
    <language>en</language>
    <item>
      <title>${TITLE}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <description><![CDATA[${NOTES_HTML}]]></description>
      <enclosure
        url="${DOWNLOAD_BASE}/$(basename "$DMG")"
        length="${LENGTH}"
        type="application/octet-stream"
        sparkle:version="${BUILD_NUMBER}"
        sparkle:shortVersionString="${VERSION}"
        $([ -n "$ED_SIG" ] && echo "sparkle:edSignature=\"${ED_SIG}\"")
      />
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
XML

echo "✓ 寫入 $OUT (hand-written appcast)"
if [ -z "$ED_SIG" ]; then
  echo "⚠ 缺少 EdDSA 簽章 — 請放置 secrets/sparkle_ed_private.key 並安裝 Sparkle tools 後重跑"
fi
cat "$OUT"
