#!/bin/sh
# Builds Shift.app, and the iOS app when it matters. Usage: scripts/build.sh [--release] [--ios] [derived-data-dir]
# --release builds the Release configuration (the one that checks for updates), Mac only.
# --ios also builds the iOS app when nothing under iOS/ or Core/ changed against main. In a Debug build it's installed
# and launched in the booted simulator, pointed at this build's own Mac app. Prints the Mac .app path, last.
set -e
cd "$(dirname "$0")/.."
CONFIG=Debug
IOS=
while :; do
  case "$1" in
    --release) CONFIG=Release; shift ;;
    --ios) IOS=1; shift ;;
    *) break ;;
  esac
done
DERIVED="${1:-build}"
xcodegen generate --quiet
# xcodegen doesn't know Icon Composer files; without their type Xcode copies the folder instead of compiling it.
sed -i '' 's|path = AppIcon.icon;|lastKnownFileType = folder.iconcomposer.icon; path = AppIcon.icon;|' Shift.xcodeproj/project.pbxproj
# SHIFT_FEED_URL (testing only) points the build at another update feed.
xcodebuild -project Shift.xcodeproj -scheme Shift -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -quiet build ${SHIFT_FEED_URL:+SHIFT_FEED_URL=$SHIFT_FEED_URL} >&2

if [ "$CONFIG" = Debug ] && [ -z "$IOS" ]; then
  BASE=$(git merge-base HEAD main 2>/dev/null || true)
  if [ -n "$BASE" ] && { git diff --name-only "$BASE"; git ls-files --others --exclude-standard; } | grep -qE '^(iOS|Core)/'; then IOS=1; fi
fi
if [ -n "$IOS" ]; then
  SIMULATOR=$(xcrun simctl list devices booted | grep -m1 -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' || true)
  DESTINATION="generic/platform=iOS Simulator"
  [ -n "$SIMULATOR" ] && DESTINATION="id=$SIMULATOR"
  xcodebuild -project Shift.xcodeproj -scheme ShiftMobile -configuration "$CONFIG" -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED" -quiet build >&2
  if [ "$CONFIG" != Debug ]; then
    :
  elif [ -z "$SIMULATOR" ]; then
    echo "No simulator is booted, so the iOS app was built but not launched." >&2
  else
    # The folder this Mac build keeps its data in: the one Shift gives a task's build, else Shift Dev's.
    if [ -n "$SHIFT_TASK" ] && [ -n "$SHIFT_WORKTREE" ]; then HOME_DIR="${SHIFT_WORKTREE%/worktrees/*}/builds/$SHIFT_TASK"
    else HOME_DIR="$HOME/.shift-dev"; fi
    mkdir -p "$HOME_DIR"
    # The Mac build isn't running yet: choose its port for it, unless it has one. It takes this one if free, and
    # the iOS app keeps retrying until it's up.
    [ -s "$HOME_DIR/remote-port" ] || echo $((20000 + ${SHIFT_TASK:-0} % 20000)) > "$HOME_DIR/remote-port"
    # What lets this simulator in with no pairing. Only good straight over loopback.
    [ -s "$HOME_DIR/remote-dev-token" ] || (umask 077; openssl rand -hex 32 > "$HOME_DIR/remote-dev-token")
    xcrun simctl install "$SIMULATOR" "$DERIVED/Build/Products/Debug-iphonesimulator/ShiftMobile.app" >&2
    SIMCTL_CHILD_SHIFT_SERVER="http://127.0.0.1:$(cat "$HOME_DIR/remote-port")?token=$(cat "$HOME_DIR/remote-dev-token")" \
      xcrun simctl launch --terminate-running-process "$SIMULATOR" com.fabiogiolito.shift.mobile.dev >&2
  fi
fi
echo "$PWD/$DERIVED/Build/Products/$CONFIG/Shift.app"
