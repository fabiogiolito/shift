#!/bin/zsh
# Takes the website's screenshots from the promo sample data (SHIFT_PREVIEW=promo), in dark and light.
# Usage: scripts/screenshots.sh <icons folder> <output folder>
# The icons folder's first four .svg files become the projects' icons, in sidebar order.
# Needs Screen Recording permission for the terminal, and a build from scripts/build.sh.
set -euo pipefail
ICONS=${1:?icons folder}; OUT=${2:?output folder}
APP=$PWD/build/Build/Products/Debug/Shift.app
# A stand-in home, so the projects are ~/Sites/<name> with the given icons.
HOME_DIR=$(mktemp -d)
# The selected task is read from Shift Dev's defaults; put the user's back afterwards.
DOMAIN=com.fabiogiolito.shift.dev
selected=$(defaults read $DOMAIN selectedTask 2>/dev/null || true)
frame=$(defaults read $DOMAIN "NSWindow Frame main" 2>/dev/null || true)
restore() {
  rm -rf $HOME_DIR
  [[ -n $selected ]] && defaults write $DOMAIN selectedTask -int $selected
  [[ -n $frame ]] && defaults write $DOMAIN "NSWindow Frame main" "$frame"
}
trap restore EXIT
icons=($ICONS/*.svg)
for i name in 1 storefront 3 checkout-api 2 admin 4 docs; do
  mkdir -p $HOME_DIR/Sites/$name && cp $icons[$i] $HOME_DIR/Sites/$name/icon.svg
done

window() {
  swift - $1 <<'EOF'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
if let w = windows.first(where: { $0[kCGWindowOwnerPID as String] as? Int32 == pid && $0[kCGWindowLayer as String] as? Int == 0 }) {
    print(w[kCGWindowNumber as String]!)
}
EOF
}

mkdir -p $OUT
for theme in dark light; do
  for shot in 01-ready-to-test:101 02-working:103 03-needs-input:107; do
    env=(--env SHIFT_PREVIEW=promo --env SHIFT_WINDOW_SIZE=1280x780 --env CFFIXED_USER_HOME=$HOME_DIR)
    [[ $theme == dark ]] && env+=(--env SHIFT_APPEARANCE=dark)
    defaults write $DOMAIN selectedTask -int ${shot#*:}
    open -n $APP $env
    sleep 4
    pid=$(pgrep -n -f "$APP/Contents/MacOS/Shift")
    screencapture -x -l $(window $pid) $OUT/$theme-${shot%:*}.png
    kill $pid
    cwebp -quiet -q 90 $OUT/$theme-${shot%:*}.png -o $OUT/$theme-${shot%:*}.webp && rm $OUT/$theme-${shot%:*}.png
  done
done
ls $OUT
