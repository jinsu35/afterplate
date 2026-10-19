#!/bin/bash
# Build the Mac app for download outside the App Store: Release, signed with
# Developer ID, and with --notarize also notarized by Apple and stapled.
#
#   ./release.sh              build, sign, verify, zip
#   ./release.sh --notarize   ...then send to Apple, staple, zip again
#
# The Developer ID certificate, its team and the notarytool keychain profile
# are read from release.local (not checked in), or from the environment:
#
#   IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   TEAM=TEAMID
#   PROFILE=name-given-to-xcrun-notarytool-store-credentials
#
# Output goes outside ~/Documents for the reason in run.sh (iCloud's extended
# attributes make codesign refuse the bundle).
set -euo pipefail
cd "$(dirname "$0")"

[[ -f release.local ]] && source release.local
: "${IDENTITY:?set IDENTITY in release.local}" "${TEAM:?set TEAM in release.local}"
PROFILE="${AFTERPLATE_NOTARY_PROFILE:-${PROFILE:-}}"
BUILD_DIR="${AFTERPLATE_BUILD_DIR:-$HOME/Library/Developer/Afterplate}/release"
NOTARIZE=0
[[ "${1:-}" == "--notarize" ]] && NOTARIZE=1

command -v xcodegen >/dev/null && xcodegen generate >/dev/null
rm -rf "$BUILD_DIR"
xcodebuild -project Afterplate.xcodeproj -scheme Afterplate -configuration Release \
  -derivedDataPath "$BUILD_DIR/derived" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

APP="$BUILD_DIR/derived/Build/Products/Release/Afterplate.app"
[[ -d "$APP" ]] || { echo "no app built"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="$BUILD_DIR/Afterplate-$VERSION.zip"

# Notarization refuses a bundle without the hardened runtime, a secure
# timestamp, or with the debug get-task-allow entitlement.
codesign --verify --strict --verbose=2 "$APP"
codesign -d --verbose=4 "$APP" 2>&1 | grep -E "^Authority=Developer ID|^Timestamp=|flags=.*runtime" \
  | sed 's/^/  /'
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "get-task-allow is set: Apple would refuse this build"; exit 1
fi

ditto -c -k --keepParent "$APP" "$ZIP"
if (( NOTARIZE )); then
  [[ -n "$PROFILE" ]] || { echo "set PROFILE in release.local"; exit 1; }
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  # The zip handed out is the one made after stapling.
  rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose=2 "$APP"
fi
echo "$ZIP"
