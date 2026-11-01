#!/bin/zsh
# Build, install, and relaunch AlecsNook from this repository.
#
# The install step re-signs with a stable designated requirement so
# TCC grants (Accessibility, automation, audio) survive rebuilds -
# ad-hoc signing alone would key permissions to a per-build cdhash.

set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild \
  -project AlecsNook.xcodeproj \
  -scheme AlecsNook \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"

osascript -e 'tell application "AlecsNook" to quit' 2>/dev/null || true
sleep 1
pkill -x AlecsNook 2>/dev/null || true

ditto build/Build/Products/Release/AlecsNook.app /Applications/AlecsNook.app

codesign --force --sign - \
  --options runtime \
  --entitlements AlecsNook/AlecsNook.entitlements \
  --identifier io.github.0202alcc.AlecsNook \
  -r='designated => identifier "io.github.0202alcc.AlecsNook"' \
  /Applications/AlecsNook.app

open /Applications/AlecsNook.app
sleep 4
if pgrep -x AlecsNook > /dev/null; then
  echo "--- deployed, running as pid $(pgrep -x AlecsNook) ---"
else
  echo "--- WARNING: AlecsNook did not start ---"
  exit 1
fi
