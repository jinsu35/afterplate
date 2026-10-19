#!/bin/bash
# Build and launch the Mac app.
#
# Build products go outside ~/Documents on purpose: that folder is synced by
# iCloud Drive, which stamps every file with a fileprovider extended attribute,
# and codesign refuses to sign a bundle carrying one ("resource fork, Finder
# information, or similar detritus not allowed").
set -euo pipefail
cd "$(dirname "$0")"
BUILD_DIR="${AFTERPLATE_BUILD_DIR:-$HOME/Library/Developer/Afterplate}"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
xcodebuild -project Afterplate.xcodeproj -scheme Afterplate -configuration Debug \
  -derivedDataPath "$BUILD_DIR" build "$@" | grep -E "error:|BUILD" || true
# `open` only brings a running copy to the front, so the new build never
# showed until the app was quit by hand; quit it first.
pkill -x Afterplate 2>/dev/null && sleep 1
open "$BUILD_DIR/Build/Products/Debug/Afterplate.app"
