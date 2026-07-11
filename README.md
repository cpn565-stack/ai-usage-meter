# AI Usage Meter

[![Build](https://github.com/cpn565-stack/ai-usage-meter/actions/workflows/build.yml/badge.svg)](https://github.com/cpn565-stack/ai-usage-meter/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A lightweight macOS **menu bar** app that shows your official **Claude**, **Codex (ChatGPT)**, **Gemini (Antigravity)**, and **Grok (SuperGrok)** usage — 5‑hour and weekly windows — at a glance, so you never blindly hit a rate limit.

Built with native AppKit (`NSStatusItem` + `NSPopover`). No Dock icon, no background server, no third‑party telemetry. It reads the credentials already stored on your machine by the official desktop apps / CLIs and calls each provider's own usage endpoint.

## Install (prebuilt)

1. Download `UsageMeter-*.dmg` from [Releases](../../releases).
2. Open the DMG and drag **UsageMeter** to Applications.
3. First launch is blocked by Gatekeeper (**self-signed, not notarized**):
   - System Settings → Privacy & Security → **Open Anyway**, or  
   - `xattr -dr com.apple.quarantine /Applications/UsageMeter.app`
4. On first fetch, macOS Keychain will ask for access — choose **Always Allow**.

**Requirements:** macOS 13+ (Apple Silicon / arm64). Sign in to each official app/CLI you want to track (see below).

## Features

- **Four providers** — Claude, Codex, Gemini, Grok side by side.
- **Official numbers** — polls each vendor's real usage API (not a local token estimate).
- **Per-bucket detail** — 5h / weekly windows, Claude scoped limits, Gemini per-model quotas, Grok weekly split (Chat / Build / Imagine / Other).
- **Menu-bar percentage** — show all (max) or a specific provider/bucket.
- **Auto token refresh** — refreshes OAuth tokens and writes them back when needed.
- **Configurable** — poll interval, launch at login, which items to show, UI language (繁體中文 / 日本語 / English).

## Requirements (per provider)

| Provider | Sign in with | Local credential source |
|----------|--------------|-------------------------|
| **Claude** | Claude desktop app | `~/Library/Application Support/Claude/config.json` + Keychain `Claude Safe Storage` |
| **Codex** | Codex CLI | `~/.codex/auth.json` |
| **Gemini** | [Antigravity](https://antigravity.google) / Antigravity IDE | Keychain `gemini` / `antigravity` |
| **Grok** | [Grok Build CLI](https://x.ai) (`grok login`) | `~/.grok/auth.json` |

You only need the apps for the providers you enable in Preferences.

## Build from source

```sh
cp Secrets.example.swift Sources/UsageMeter/Secrets.swift   # first time only
# 編輯 Secrets.swift:填入 Antigravity 桌面 OAuth client id/secret
# (從本機 Antigravity IDE.app 的 oauthClient 模組可見;公開 desktop client,非個人密碼)
./scripts/verify.sh           # build + parser + layout self-tests (required before release)
./package.sh                  # → UsageMeter.app
./make-dmg.sh                 # → UsageMeter-<version>.dmg
VERSION=0.2.3 ./make-dmg.sh

swift run UsageMeter --once        # fetch once to terminal
swift run UsageMeter --diagnose    # read-only credential check
swift run UsageMeter --self-test   # offline tests
```

Release automation: push a tag `v*` (e.g. `v0.2.3`). CI runs `--self-test`, packages the DMG, and publishes a GitHub Release.

**Do not tag a release unless `./scripts/verify.sh` is green.**

### Gemini secrets for CI / public DMG

GitHub **push protection** blocks committing Google OAuth client strings. Keep them out of git:

1. Repo → **Settings → Secrets and variables → Actions**
2. Add repository secrets:
   - `GEMINI_CLIENT_ID` — Antigravity desktop OAuth client id (`….apps.googleusercontent.com`)
   - `GEMINI_CLIENT_SECRET` — matching `GOCSPX-…` secret from the same desktop client
3. Tag release builds inject these into `Secrets.swift` before packaging (see `.github/workflows/build.yml`).

Without those secrets, CI still builds, but **prebuilt Gemini token refresh will not work** until users build from source with a filled `Secrets.swift`. Claude / Codex / Grok do not need these secrets.

## How it works

- **Claude** — decrypts Electron `safeStorage` token cache (`oauth:tokenCacheV2` / legacy), calls `GET /api/oauth/usage`, refreshes via `platform.claude.com`.
- **Codex** — reads `~/.codex/auth.json`, ChatGPT backend usage API, refreshes via `auth.openai.com`.
- **Gemini** — Antigravity Keychain OAuth → Cloud Code `fetchAvailableModels` quotas; refresh uses the public Antigravity desktop OAuth client in `Secrets.example.swift`.
- **Grok** — `~/.grok/auth.json` → `cli-chat-proxy.grok.com/v1/billing?format=credits` (weekly total + product split).

## Security & disclaimer

- **Personal, local, read-mostly dashboard.** Credentials stay on your Mac; traffic only goes to each vendor's own API.
- OAuth `client_id` / `client_secret` for desktop clients are **public app-level identifiers** (native OAuth cannot keep a secret). They are **not** your personal account password.
- Unofficial / undocumented endpoints may change or break without notice. **Use at your own risk.**
- Writing refreshed tokens back to Claude/Codex/Grok local stores can affect the official apps if something goes wrong; backups are kept under `.UsageMeterBackups` next to those files.

## Troubleshooting

| Symptom | What to try |
|---------|-------------|
| Gatekeeper blocks open | Privacy & Security → Open Anyway, or `xattr -dr com.apple.quarantine …` |
| Keychain prompt loops | Choose **Always Allow** for UsageMeter |
| Gemini 401 / empty | Open Antigravity and sign in; wait for token refresh; `swift run UsageMeter --diagnose` |
| Grok missing | Run `grok login` so `~/.grok/auth.json` exists |
| Claude missing | Sign in to Claude desktop; allow Keychain access to `Claude Safe Storage` |

```sh
swift run UsageMeter --diagnose   # credential status only
swift run UsageMeter --once       # live fetch printout
```

## Contributing / public roadmap

Ideas that help others adopt the app:

1. **Apple Developer ID + notarization** — removes Gatekeeper “Open Anyway” friction.
2. Screenshots in this README.
3. Optional Intel / universal binary if you need it.
4. Issues/Discussions for API breakages (vendors change endpoints often).

PRs welcome. Please run `./scripts/verify.sh` before opening a PR.

## License

[MIT](LICENSE)
