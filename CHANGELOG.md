# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Grok product category **Other**
  - Maps `productUsage` product id `Other` (and alias `GrokOther`) → bucket key `other`
  - Localized label: 繁中「其他」/ 日文「その他」/ English「Other」
  - `defaultOn = false` — hidden until enabled in Preferences → Shown items
  - Parser self-test covers both `Other` and `GrokOther`

### Fixed
- Restore missing `}` in `Localization.swift` (`AppLanguage.nativeName` switch) that broke the build after the Other feature commits

## [0.2.2] - 2026-07-11

### Added
- Grok SuperGrok weekly usage (Chat / Build / Imagine)
- Popover layout self-tests in CI

### Fixed
- Popover header clipping and height when hiding buckets
