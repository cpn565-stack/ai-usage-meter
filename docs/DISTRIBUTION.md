# Distribution: Sparkle updates & Apple notarization

This project ships outside the Mac App Store. Two tracks improve install quality:

1. **Sparkle** — in-app “Check for Updates…”
2. **Developer ID + notarization** — Gatekeeper opens without “Open Anyway”

---

## 1. Repo About (done)

- Description and topics are set on GitHub (`macos`, `menubar`, `claude`, `codex`, `gemini`, `grok`, …).

---

## 2. Sparkle auto-update

### What’s in the app

| Piece | Location |
|-------|----------|
| Dependency | `Package.swift` → Sparkle 2.x |
| Runtime | `AppUpdater.swift` (`SPUStandardUpdaterController`) |
| UI | Preferences → **檢查更新…** |
| Start | `AppDelegate.applicationDidFinishLaunching` |
| Embed framework | `package.sh` copies `Sparkle.framework` into `.app/Contents/Frameworks` |
| Feed URL | Info.plist `SUFeedURL` → `appcast/appcast.xml` on `main` |
| Public key | Info.plist `SUPublicEDKey` |

Default feed:

```text
https://raw.githubusercontent.com/cpn565-stack/ai-usage-meter/main/appcast/appcast.xml
```

### One-time: EdDSA keys

On a Mac with the Sparkle tools (after `swift build`):

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys          # creates key in login keychain
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p       # print public key
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x secrets/sparkle_ed_private.key
```

- **Public** key → already wired as default in `package.sh` (`SPARKLE_PUBLIC_ED_KEY`).  
  If you regenerate keys, update `package.sh` / set `SPARKLE_PUBLIC_ED_KEY` in CI.
- **Private** key → `secrets/sparkle_ed_private.key` (**gitignored**).  
  Add to GitHub Actions secret **`SPARKLE_PRIVATE_KEY`** (file contents).

Current public key (for this repo’s generated keychain key):

```text
+M0RGQsB7Ivk8ZCt96TeHj1PMqcFa39r8ShE+l4FXts=
```

### Generate appcast after packaging a DMG

```sh
VERSION=0.2.4 ./make-dmg.sh
VERSION=0.2.4 BUILD_NUMBER=42 ./scripts/generate-appcast.sh UsageMeter-0.2.4.dmg
# → appcast/appcast.xml
git add appcast/appcast.xml && git commit -m "chore: appcast 0.2.4" && git push
```

Release workflow (`.github/workflows/release.yml`) also generates appcast when `SPARKLE_PRIVATE_KEY` is set and tries to push it to `main`.

### User flow

1. Install a build that embeds Sparkle + correct `SUPublicEDKey`.
2. Ship a newer DMG on GitHub Releases + update `appcast/appcast.xml`.
3. Users open Preferences → **檢查更新…**, or wait for the daily automatic check.

---

## 3. Notarization (draft — needs Apple Developer Program)

### Prerequisites

1. [Apple Developer Program](https://developer.apple.com/programs/) membership.
2. Certificate: **Developer ID Application**.
3. Export as `.p12` (for CI) or install in login keychain (local).
4. App Store Connect **API key** (`.p8`) recommended for CI.

### Local notarize

```sh
export APPLE_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export VERSION=0.2.4
./package.sh
./make-dmg.sh

# One-time: store notary credentials
xcrun notarytool store-credentials "usage-meter-notary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"

export NOTARYTOOL_PROFILE=usage-meter-notary
./scripts/notarize.sh UsageMeter-0.2.4.dmg
```

Or API key:

```sh
export APPLE_API_KEY_PATH=/path/to/AuthKey_XXX.p8
export APPLE_API_KEY_ID=XXX
export APPLE_API_ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
./scripts/notarize.sh UsageMeter-0.2.4.dmg
```

### CI secrets (optional block in `release.yml`)

| Secret | Purpose |
|--------|---------|
| `APPLE_CODESIGN_IDENTITY` | Full codesign identity string |
| `BUILD_CERTIFICATE_BASE64` | base64 of Developer ID `.p12` |
| `P12_PASSWORD` | p12 password |
| `KEYCHAIN_PASSWORD` | temp keychain password on runner |
| `APPLE_API_KEY_BASE64` | base64 of `.p8` |
| `APPLE_API_KEY_ID` | Key ID |
| `APPLE_API_ISSUER` | Issuer UUID |

If these are **absent**, release still publishes a **self-signed** DMG (current behavior).

### Hardened Runtime

`package.sh` uses `--options runtime` when `APPLE_CODESIGN_IDENTITY` is set. Sparkle generally works outside the sandbox for menu bar apps; if you later enable App Sandbox, follow [Sparkle sandboxing docs](https://sparkle-project.org/documentation/sandboxing/).

---

## 4. Recommended rollout order

| Step | Action | Blocks public UX? |
|------|--------|-------------------|
| ✅ | Public repo + MIT + Releases | — |
| ✅ | Topics / description | — |
| ✅ | Sparkle code + appcast pipeline (draft) | Needs first signed appcast |
| ⬜ | Set `SPARKLE_PRIVATE_KEY` on Actions | Required for valid Sparkle signatures |
| ⬜ | Apple Developer + Developer ID cert | Required for notarization |
| ⬜ | Set notarization secrets; re-tag release | Removes Gatekeeper friction |
| ⬜ | README screenshots | Marketing |

---

## 5. Security notes

- Never commit `secrets/` or `Sources/UsageMeter/Secrets.swift`.
- Sparkle private key = ability to ship malware as “updates”. Protect like a code-signing cert.
- Gemini OAuth client strings must stay in Actions secrets (GitHub push protection).
