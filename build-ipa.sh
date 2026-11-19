#!/bin/bash
#
# Builds an unsigned .ipa for Sideloadly, AltStore or SideStore.
#
# Signing is left off entirely and the archive is repackaged by hand: those
# tools re-sign with your Apple ID anyway, and asking xcodebuild to sign first
# would only fail on the App Groups entitlement a personal team cannot grant.
#
#   ./build-ipa.sh
#
# The result lands in build/Bidyut.ipa. Drag that into Sideloadly.

set -euo pipefail

SCHEME="Bidyut"
PROJECT="Bidyut.xcodeproj"
BUILD_DIR="build"
ARCHIVE="${BUILD_DIR}/Bidyut.xcarchive"
IPA="${BUILD_DIR}/Bidyut.ipa"

cd "$(dirname "$0")"

if ! command -v xcodebuild >/dev/null; then
  echo "xcodebuild not found. Install Xcode, then run: xcode-select --install"
  exit 1
fi

# Sideloadly remaps the App Group to a team-unique name, so the full project
# is what to build here — project-free.yml drops the widget that depends on it.
if [ ! -d "$PROJECT" ]; then
  if command -v xcodegen >/dev/null; then
    echo "==> Generating $PROJECT"
    xcodegen generate
  else
    echo "$PROJECT not found and xcodegen is not installed."
    echo "Run: brew install xcodegen"
    exit 1
  fi
fi

echo "==> Archiving without code signing"
rm -rf "$ARCHIVE" "$IPA"
mkdir -p "$BUILD_DIR"

xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_BITCODE=NO \
  | grep -E 'error:|\*\* ' || true

APP_PATH="${ARCHIVE}/Products/Applications/${SCHEME}.app"
if [ ! -d "$APP_PATH" ]; then
  echo
  echo "Archive produced no app bundle. Scroll up for the first 'error:' line."
  exit 1
fi

# An .ipa is just a zip with the app inside a folder called Payload.
echo "==> Packaging $IPA"
rm -rf "${BUILD_DIR}/Payload"
mkdir -p "${BUILD_DIR}/Payload"
cp -R "$APP_PATH" "${BUILD_DIR}/Payload/"

( cd "$BUILD_DIR" && zip -qry "$(basename "$IPA")" Payload )
rm -rf "${BUILD_DIR}/Payload"

SIZE=$(du -h "$IPA" | cut -f1)
echo
echo "Built $IPA ($SIZE)"
echo
echo "Next: open Sideloadly, drag in the .ipa, enter your Apple ID, press Start."
echo "Turn on auto-refresh so it re-signs itself every seven days."
