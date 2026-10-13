#!/bin/bash
# Ideal Video Encoder for macOS - release build
# https://github.com/alex-mcdermott/Ideal-Video-Encoder
# Copyright (C) 2026 the Ideal Video Encoder contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds "Ideal Video Encoder.app" (Release, Apple Silicon + Intel), signs it ad hoc and zips it into dist/.
# Needs Xcode and XcodeGen (brew install xcodegen). Usage: ./build.sh [--icon] [--test]
#   --icon  regenerate Resources/AppIcon.icns from ../assets/app.ico first
#   --test  run the unit tests before building
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD
DIST="$ROOT/dist"
APP_NAME="Ideal Video Encoder"

for a in "$@"; do
  case "$a" in
    --icon) ICON=1 ;;
    --test) TEST=1 ;;
    *) echo "Unknown option: $a" >&2; exit 64 ;;
  esac
done

command -v xcodegen >/dev/null || { echo "XcodeGen is missing: brew install xcodegen" >&2; exit 1; }
xcodebuild -version >/dev/null 2>&1 || { echo "Full Xcode is needed (xcode-select -p must point into Xcode.app)." >&2; exit 1; }

if [ "${ICON:-0}" = 1 ]; then
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  swift Scripts/make-icon.swift ../assets/app.ico "$T/AppIcon.iconset" macos-grid
  iconutil -c icns "$T/AppIcon.iconset" -o Resources/AppIcon.icns
fi

xcodegen generate --quiet
if [ "${TEST:-0}" = 1 ]; then
  xcodebuild -project IdealVideoEncoder.xcodeproj -scheme IVECore -derivedDataPath build/dd -destination 'platform=macOS' test -quiet
fi

xcodebuild -project IdealVideoEncoder.xcodeproj -scheme IdealVideoEncoder -configuration Release \
  -derivedDataPath build/release -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet

BUILT="build/release/Build/Products/Release/$APP_NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$BUILT/Contents/Info.plist")
rm -rf "$DIST"; mkdir -p "$DIST"
ditto "$BUILT" "$DIST/$APP_NAME.app"

# Ad-hoc signature (no Developer ID): Gatekeeper asks the user to confirm the first launch
codesign --force --deep --sign - --timestamp=none "$DIST/$APP_NAME.app"
codesign --verify --deep --strict "$DIST/$APP_NAME.app"

ZIP="$DIST/Ideal-Video-Encoder-$VERSION-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$DIST/$APP_NAME.app" "$ZIP"

echo "Built $DIST/$APP_NAME.app (version $VERSION, $(lipo -archs "$DIST/$APP_NAME.app/Contents/MacOS/$APP_NAME"))"
echo "Zip:  $ZIP ($(du -h "$ZIP" | cut -f1))"
