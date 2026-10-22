#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="/Applications/macOSHello.app"

pkill -f '/macOSHello.app/Contents/MacOS/macOSHello$' 2>/dev/null || true

if [ -d "$APP_PATH" ]; then
    rm -rf "$APP_PATH"
fi

xcodebuild \
    -project "$PROJECT_DIR/macOSHello.xcodeproj" \
    -scheme macOSHello \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    clean build

BUILT_APP="$(xcodebuild \
    -project "$PROJECT_DIR/macOSHello.xcodeproj" \
    -scheme macOSHello \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -showBuildSettings |
    awk '/TARGET_BUILD_DIR =/{print $3; exit}')/macOSHello.app"

ditto "$BUILT_APP" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
open "$APP_PATH"
