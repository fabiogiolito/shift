#!/bin/sh
# Builds Shift.app. Usage: scripts/build.sh [--release] [derived-data-dir]
# --release builds the Release configuration (the one that checks for updates). Prints the .app path.
set -e
cd "$(dirname "$0")/.."
CONFIG=Debug
if [ "$1" = "--release" ]; then CONFIG=Release; shift; fi
DERIVED="${1:-build}"
xcodegen generate --quiet
# xcodegen doesn't know Icon Composer files; without their type Xcode copies the folder instead of compiling it.
sed -i '' 's|path = AppIcon.icon;|lastKnownFileType = folder.iconcomposer.icon; path = AppIcon.icon;|' Shift.xcodeproj/project.pbxproj
# SHIFT_FEED_URL (testing only) points the build at another update feed.
xcodebuild -project Shift.xcodeproj -scheme Shift -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -quiet build ${SHIFT_FEED_URL:+SHIFT_FEED_URL=$SHIFT_FEED_URL} >&2
echo "$PWD/$DERIVED/Build/Products/$CONFIG/Shift.app"
