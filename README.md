# AI Usage Meter

[![Build](https://github.com/cpn565-stack/ai-usage-meter/actions/workflows/build.yml/badge.svg)](https://github.com/cpn565-stack/ai-usage-meter/actions/workflows/build.yml)

A lightweight macOS **menu bar** app that shows your official **Claude**, **Codex (ChatGPT)**, **Gemini (Antigravity)**, and **Grok (SuperGrok)** usage — 5‑hour and weekly windows — at a glance, so you never blindly hit a rate limit.

Built with native AppKit (`NSStatusItem` + `NSPopover`). No Dock icon, no background server, no third‑party telemetry. It reads the credentials already stored on your machine by the official desktop apps / CLIs and calls each provider's own usage endpoint.

## Features

- **Four providers in one place** — Claude, Codex, Gemini, and Grok side by side.
- **Official numbers** — polls each vendor's real usage API (not a local token estimate).
- **Per‑bucket detail** — 5h / weekly windows, Claude scoped model/surface limits, every Gemini model quota, and Grok weekly SuperGrok split (Chat / Build / Imagine).
- **Menu‑bar percentage** — pick "all (max)" or a specific provider/window to show in the bar.
- **Auto token refresh** — transparently refreshes expiring OAuth tokens and writes them back so the official apps stay in sync.
- **Configurable** — polling interval (10 min / 30 min / manual), launch at login, which items to show, and UI language (繁體中文 / 日本語 / English).

## Requirements

- macOS 13+ (Apple Silicon / arm64)
- The official desktop app / CLI for each provider you want to track, already signed in:
  - **Claude** desktop app (reads `~/Library/Application Support/Claude/config.json`)
  - **Codex** CLI (`~/.codex/auth.json`)
  - **Antigravity** (Gemini OAuth token in Keychain)
  - **Grok Build CLI** (`~/.grok/auth.json` after `grok login`)

## Build from source

```sh
swift build -c release        # or: ./package.sh  → builds UsageMeter.app
./scripts/verify.sh           # **pre-release gate**: build + parser + layout self-tests
./make-dmg.sh                 # builds + packages a distributable .dmg
VERSION=0.2.1 ./make-dmg.sh   # builds UsageMeter-0.2.1.dmg with matching app version
swift run UsageMeter --once   # headless: fetch once and print to the terminal
swift run UsageMeter --self-test   # parsers + popover layout regression (no network)
```

Release automation: push a tag such as `v0.2.1` to GitHub. CI builds the app, runs `--self-test` (parsers **and** panel layout), packages `UsageMeter-0.2.1.dmg`, uploads it as a workflow artifact, and creates or updates the GitHub Release.

**Do not tag a release unless `./scripts/verify.sh` is green.**

## Install (prebuilt)

Download `UsageMeter.dmg` from the [Releases](../../releases) page, drag the app to Applications. The app is self‑signed (not notarized), so on first launch:

- System Settings → Privacy & Security → scroll down → **Open Anyway**, or
- `xattr -dr com.apple.quarantine /Applications/UsageMeter.app`

On first fetch, the Keychain will ask for access to the stored credentials — choose **Always Allow**.

## How it works

Each provider has its own `*Provider.swift`:

- **Claude** — decrypts the Electron `safeStorage` token cache (`oauth:tokenCacheV2`, falling back to the legacy `oauth:tokenCache`) using the `Claude Safe Storage` Keychain key, then calls `GET /api/oauth/usage`. Refreshes via `https://platform.claude.com/v1/oauth/token` when the access token is about to expire.
- **Codex** — reads `~/.codex/auth.json`, calls the ChatGPT backend usage endpoint, refreshes against `auth.openai.com`.
- **Gemini** — reads the Antigravity OAuth token from Keychain and queries the Cloud Code companion API for per‑model quotas.
- **Grok** — reads `~/.grok/auth.json` (Grok Build CLI OIDC), calls `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` for weekly SuperGrok usage (`creditUsagePercent` + `productUsage` Chat/Build/Imagine), refreshes against `auth.x.ai/oauth2/token`.

## Security & disclaimer

- This is a **personal, read‑only** dashboard. It only reads credentials that the official apps already store locally, on your own machine; nothing is sent anywhere except to each vendor's own API.
- The OAuth `client_id` / `client_secret` values in the source are **public, app‑level desktop‑client identifiers** (a native OAuth client cannot keep a secret), reverse‑engineered by the community — they are **not** personal account credentials.
- Use at your own risk. These are unofficial, undocumented endpoints that vendors may change at any time. (For example, Claude moved its token endpoint from `console.anthropic.com` to `platform.claude.com` in mid‑2026.)
