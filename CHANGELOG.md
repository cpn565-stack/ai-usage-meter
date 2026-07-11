# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **Release CI: Sparkle build number** — `release.yml` used `github.run_number` (would have produced build ~4, lower than the shipped build 21, so Sparkle would never offer the update). Now uses `git rev-list --count HEAD` with `fetch-depth: 0`, matching local `package.sh`.
- **Release CI: unsigned appcast guard** — tagging without `SPARKLE_PRIVATE_KEY` used to silently publish (and commit to `main`) an appcast without `edSignature`, which existing installs would reject. CI now hard-fails instead (`REQUIRE_ED_SIGNATURE=1` in `generate-appcast.sh`).

### Changed
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
