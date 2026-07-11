#!/bin/bash
# 發版前本機驗證。失敗則非 0 exit,不要 push / tag。
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f Sources/UsageMeter/Secrets.swift ]; then
  cp Secrets.example.swift Sources/UsageMeter/Secrets.swift
fi

echo "▶ swift build (debug)"
swift build

echo "▶ self-test (debug)"
swift run UsageMeter --self-test

echo "▶ swift build (release)"
swift build -c release

echo "▶ self-test (release)"
swift run -c release UsageMeter --self-test

echo "▶ diagnose (credentials; non-fatal)"
swift run -c release UsageMeter --diagnose || true

echo "✓ verify passed — safe to package / tag"
