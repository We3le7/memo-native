#!/bin/bash
# 运行单元测试（纯逻辑层，不起 GUI）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
BUILD="${ROOT}/build"

mkdir -p "${BUILD}"

echo "==> 编译测试"
xcrun swiftc \
  -module-cache-path "${BUILD}/modulecache" \
  -sdk "${SDK}" \
  -target arm64-apple-macos13.0 \
  -swift-version 5 \
  "${ROOT}/Tests/main.swift" \
  "${ROOT}/Tests/ModelTests.swift" \
  "${ROOT}/Sources/MemoNative/Models.swift" \
  "${ROOT}/Sources/MemoNative/Digest.swift" \
  "${ROOT}/Sources/MemoNative/UILogic.swift" \
  "${ROOT}/Sources/MemoNative/OrbMetrics.swift" \
  "${ROOT}/Sources/MemoNative/GlassAppearance.swift" \
  "${ROOT}/Sources/MemoNative/OrbMotion.swift" \
  "${ROOT}/Sources/MemoNative/MotionCurve.swift" \
  -o "${BUILD}/modeltests"

echo "==> 运行"
"${BUILD}/modeltests"
