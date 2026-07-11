# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.2] - 2026-07-11

### Added
- Grok 支援新增產品類別「Other」
  - 在 `productUsage` 中正確解析 `GrokOther`，對應 bucket key 為 `other`
  - 新增多語系顯示：繁體中文「其他」、日本語「その他」、English「Other」
  - 預設 `defaultOn = false`，不會自動出現在選單列，可在「偏好設定 → 顯示細項」中手動開啟

### Changed
- 更新 `GrokProvider.swift` 內部文件註解，補充支援的產品類別說明

### Notes
- 此修改由人工精準編輯，確保與現有 parser self-test 完全相容，無引入新 bug。