# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Codex 多帳號**：自動發現 `~/.codex` 與 `~/.codex-*`（`CODEX_HOME`，例如 `codex-work`），依 ChatGPT `account_id` 去重後並排顯示（`Codex · 預設` / `Codex · work`）。同一帳號的複本只認一份 canonical home（`~/.codex` 優先），refresh token 只寫回那份 `auth.json`。偏好設定可單獨開關帳號；選單列可鎖定其中一個或取 Codex 最高。

### Changed
- **面板拋光**：header 上緣改為明確 16pt（之前貼邊太擠；注意 NSStackView 橫向排列時上下 edgeInsets 會被取成 `min(top, bottom)` 兩邊通用，所以上下留白改用外層 constraint 常數）、標題/狀態列間距、provider 段落與列間距放寬、進度條 7→8pt 藥丸形、底部動作列留白增加。

### Fixed
- **Gemini 數字與官方不符**：改打 `daily-cloudcode-pa.googleapis.com`（官方 UI 與 `agy` CLI 用的 channel）。舊的 stable host 回的 Gemini 池與官方不一致（週 62% vs 86%、5h 100% vs 78%，reset 也不同窗），3p 池兩邊則一致。用 proxy 追 `agy` 的連線目標確認。
- **Gemini 週額度消失**：API 其實正常回傳 4 個桶，是 `enabledBuckets` 存著 fallback 時代的舊子集（只有兩個 5h），0.2.8 新增週額度後因部分重疊仍沿用舊子集，週額度被過濾掉。Prefs 現在記住各家「看過的桶」，沒看過的新桶走 `defaultOn` 自動顯示，親手關掉的維持關閉；fallback（桶不全）時開關也不再丟掉沒看到的桶的選擇。升級後下次刷新自動恢復顯示，無需手動重勾。
- **Gemini 標籤被截斷**：用量列標籤欄從 74pt 放寬到 110pt（`Claude/GPT · 5 小時` 需約 106pt），並加上 tooltip。

## [0.2.8] - 2026-07-25

### Changed
- **Gemini / Antigravity**：改打官方 `retrieveUserQuotaSummary`，與 Model Quota UI 一致——**Gemini Models** / **Claude and GPT models**，各有 **Weekly** + **Five Hour**（顯示為 `Gemini · 週/5 小時`、`Claude/GPT · 週/5 小時`）。summary 失敗才退回 `fetchAvailableModels` 歸兩池。
- 偏好設定：若已存的 bucket key 與目前 API 桶完全不重疊（schema 變更），回退 `defaultOn`，避免仍列出舊的 per-model 細項。

## [0.2.7] - 2026-07-15

### Fixed
- **Grok billing**: tolerate null `creditUsagePercent` / `productUsage`, products missing `usagePercent` (treat as 0), and fall back to money-format billing so the row does not stay in API-changed error state

## [0.2.6] - 2026-07-13

### Added
- **Codex manual reset credits** next to plan badge (count + soonest expiry via `/wham/rate-limit-reset-credits`)

### Changed
- Codex plan `team` displays as **Business**
- Gemini / Claude credentials cache prefers Application Support files so routine refresh no longer hits Keychain (fewer password prompts)

## [0.2.5] - 2026-07-13

### Fixed
- **Codex window labels** — no longer hardcode primary as「5 小時」/ secondary as「週」. Labels follow API `limit_window_seconds` (e.g. when OpenAI drops the 5h window and only a weekly limit remains). Null windows skipped; int `used_percent` supported.
- **Release CI: Sparkle build number** — `release.yml` used `github.run_number` (would have produced build ~4, lower than the shipped build 21, so Sparkle would never offer the update). Now uses `git rev-list --count HEAD` with `fetch-depth: 0`, matching local `package.sh`.
- **Release CI: unsigned appcast guard** — tagging without `SPARKLE_PRIVATE_KEY` used to silently publish (and commit to `main`) an appcast without `edSignature`, which existing installs would reject. CI now hard-fails instead (`REQUIRE_ED_SIGNATURE=1` in `generate-appcast.sh`).

### Added
- README screenshots (menu bar popover + Preferences).

### Changed
- README screenshots refreshed from 0.2.4 (21) UI (was 0.2.3 in Preferences).
- `release.yml` supports `workflow_dispatch` dry runs: builds DMG + signed appcast and uploads them as an artifact without publishing a Release or touching `main`.
- Moved root-level `spike_*.py` dev scripts into `scripts/`.

## [0.2.4] - 2026-07-11

### Added
- **Sparkle 2** auto-update (`AppUpdater`, Preferences → Check for Updates)
- First **appcast** entry for in-app updates
- `docs/DISTRIBUTION.md` + `release.yml` draft for notarization / signed appcasts

### Notes
- Update feed: `appcast/appcast.xml` on `main`
- Notarization still optional (self-signed until Developer ID secrets are set)

## [0.2.3] - 2026-07-11

### Added
- Grok product category **Other** (`Other` / `GrokOther` → bucket `other`, default hidden)
- MIT `LICENSE`
- CI injection of `GEMINI_CLIENT_ID` / `GEMINI_CLIENT_SECRET` for release DMGs (values stay in Actions secrets)
- Diagnostic scripts: `scripts/probe_gemini_auth.py`, `scripts/probe_grok_billing.py`

### Fixed
- Localization build break (missing `}` in `AppLanguage.nativeName`)
- Gemini: fall back to non-expired Antigravity access token when OAuth refresh fails
- Grok/Other parser self-tests

## [0.2.2] - 2026-07-11

### Added
- Grok SuperGrok weekly usage (Chat / Build / Imagine)
- Popover layout self-tests in CI (`--self-test`)

### Fixed
- Popover header clipping and height when hiding buckets

## [0.2.1] - 2026-07-11

### Fixed
- Early layout regressions around popover content size

## [0.2.0] - 2026-07-02

### Added
- Claude scoped weekly limits
- Release DMG automation on version tags
