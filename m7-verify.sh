#!/bin/bash
#
# m7-verify.sh — One-shot on-device loop: build -> install to iPhonePeter -> run unit/UI tests.
# Usage: run from this directory with  bash m7-verify.sh
# Prereqs: iPhonePeter paired, unlocked and screen on; harness server reachable on 0.0.0.0:8897.
#
set -euo pipefail

DEVICE_ID="00008120-001428820AB8201E"
TEAM="P5W752L332"
SCHEME="VoxSign"
DD="/tmp/vhs-m7-dd"

cd "$(dirname "$0")"

echo "== [1/3] Build (generic iOS) =="
xcodebuild -project ${SCHEME}.xcodeproj -scheme ${SCHEME} \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath "${DD}" \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=${TEAM} build

APP="${DD}/Build/Products/Debug-iphoneos/${SCHEME}.app"
echo "== [2/3] Install to ${DEVICE_ID} =="
xcrun devicectl device install app --device ${DEVICE_ID} "${APP}"

echo "== [3/3] Run on-device tests (unit + UI) =="
xcodebuild test -project ${SCHEME}.xcodeproj -scheme ${SCHEME} \
  -destination "id=${DEVICE_ID}" -derivedDataPath "${DD}" \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=${TEAM}

echo "== Done: TEST SUCCEEDED means the loop passed =="
