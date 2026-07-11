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
  echo "▶ generate_appcast --ed-key-file（勿用 -f，那是舊 DSA）…"
  # -f = DSA only；EdDSA 必須 --ed-key-file，否則會讀 Keychain 並連彈密碼框
  "$GEN_APPCAST" --ed-key-file "$KEY_FILE" "$STAGE" 2>&1 || true
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

# 手寫 fallback:用 sign_update 對 dmg 簽 enclosure
LENGTH="$(wc -c < "$DMG" | tr -d ' ')"
PUB_DATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
ED_SIG=""
SIGN_UPDATE=""
for cand in \
  .build/artifacts/sparkle/Sparkle/bin/sign_update \
  "$HOME/Library/Caches/usagemeter-build/artifacts/sparkle/Sparkle/bin/sign_update"
do
  if [ -x "$cand" ]; then SIGN_UPDATE="$cand"; break; fi
done
if [ -n "$SIGN_UPDATE" ]; then
  # 只用檔案私鑰，永遠不走 Keychain。
  # 原因：Keychain item 的 ACL 只授權 generate_keys，不授權 sign_update；
  # adhoc 簽名的工具按「永遠允許」也常不生效，每次 release 會連彈多次密碼框。
  if [ ! -f "$KEY_FILE" ]; then
    echo "✗ 缺少 $KEY_FILE — 請用 generate_keys -x 匯出，或從安全備份放回 secrets/" >&2
    echo "  （刻意不讀 Keychain，避免彈出「sign_update 想存取…」）" >&2
  else
    echo "▶ sign_update --ed-key-file $KEY_FILE（跳過 Keychain）"
    LINE="$("$SIGN_UPDATE" --ed-key-file "$KEY_FILE" "$DMG" 2>/dev/null | tail -1 || true)"
    # 期望: sparkle:edSignature="..." length="..."
    if [[ "$LINE" == sparkle:edSignature=* ]]; then
      ED_SIG="$(printf '%s' "$LINE" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
    fi
  fi
fi

SIG_ATTR=""
if [ -n "$ED_SIG" ]; then
  SIG_ATTR="sparkle:edSignature=\"${ED_SIG}\""
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
        sparkle:version="${BUILD_NUMBER}"
        sparkle:shortVersionString="${VERSION}"
        length="${LENGTH}"
        type="application/octet-stream"
        ${SIG_ATTR}
      />
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
XML

echo "✓ 寫入 $OUT"
if [ -z "$ED_SIG" ]; then
  echo "⚠ 缺少 EdDSA 簽章 — 確認 Keychain 有 Sparkle key 或 secrets/sparkle_ed_private.key"
else
  echo "  edSignature: ${ED_SIG:0:16}…"
fi
cat "$OUT"
