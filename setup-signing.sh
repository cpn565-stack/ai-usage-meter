#!/bin/bash
# 建立一個穩定的自簽「程式碼簽章」身分,讓 keychain 的「永遠允許」能跨版本記住。
# 只需執行一次。之後 package.sh 會自動用這個身分簽章。
set -e
CN="UsageMeter Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/opt/homebrew/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL=openssl

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"; then
  echo "✓ 簽章身分已存在,跳過:$CN"
  exit 0
fi

TMP="$(mktemp -d)"
echo "▶ 產生自簽憑證(code signing)…"
"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$CN" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
# -legacy:用舊演算法,macOS 的 security 才認得(OpenSSL 3 預設的新 MAC 會匯入失敗)。
"$OPENSSL" pkcs12 -export -legacy -macalg sha1 -out "$TMP/id.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout pass:usagemeter -name "$CN"

echo "▶ 匯入登入鑰匙圈(允許 codesign 使用)…"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P usagemeter -T /usr/bin/codesign
rm -rf "$TMP"

echo "✓ 已建立:$CN"
security find-identity -v -p codesigning | grep "$CN" || true
