#!/bin/sh
# Builds, signs and packages a Shift release and adds it to appcast.xml. See docs/RELEASING.md.
# Usage: scripts/release.sh [version] [release-notes.md|.html] [--publish]
# Without a version, the patch number after the last release tag (0.1.1 -> 0.1.2).
# Without notes, scripts/release-notes.sh writes them from the commits since the last release.
# Without --publish nothing touches the network (except notarization when NOTARY_PROFILE is set);
# the publish commands are printed instead.
# Env: DEVELOPER_ID   "Developer ID Application: …" signs with it (hardened runtime); ad-hoc otherwise.
#                     Defaults to the Developer ID Application certificate in the keychain, if there is one.
#      NOTARY_PROFILE notarytool keychain profile; notarizes and staples when set. Defaults to
#                     "shift-notary" when that profile exists.
#      SHIFT_FEED_URL testing only: builds against this feed and puts the archive's URL next to it.
set -e
cd "$(dirname "$0")/.."
die() { echo "release: $*" >&2; exit 1; }

# Sign and notarize whenever this Mac can, so a release is never unsigned by accident.
: "${DEVELOPER_ID:=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
: "${NOTARY_PROFILE:=$(xcrun notarytool history --keychain-profile shift-notary >/dev/null 2>&1 && echo shift-notary)}"
# Apple only notarizes apps signed with a Developer ID.
[ -n "$DEVELOPER_ID" ] || NOTARY_PROFILE=
echo "release: signing with ${DEVELOPER_ID:-ad-hoc}; notarizing with ${NOTARY_PROFILE:-nothing}" >&2

PUBLISH=0 VERSION= NOTES=
for a do
  case $a in
    --publish) PUBLISH=1 ;;
    *) if [ -z "$VERSION" ]; then VERSION=$a; else NOTES=$a; fi ;;
  esac
done
[ -z "$NOTES" ] || [ -f "$NOTES" ] || die "no such file: $NOTES"
[ -z "$(git status --porcelain)" ] || die "uncommitted changes; commit or stash them first"
[ "$(git branch --show-current)" = main ] || die "not on main"
if [ -z "$VERSION" ]; then
  LAST=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null) || die "no release tag yet; give a version"
  VERSION=$(echo "${LAST#v}" | awk -F. '{ printf "%d.%d.%d", $1, $2, $3 + 1 }')
fi
if [ -z "$NOTES" ]; then
  mkdir -p dist
  NOTES=dist/notes-$VERSION.md
  scripts/release-notes.sh > "$NOTES" || die "couldn't write release notes"
  printf 'release: %s notes:\n%s\n' "$VERSION" "$(cat "$NOTES")" >&2
fi
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "tag v$VERSION already exists"
! grep -qs "<sparkle:shortVersionString>$VERSION<" appcast.xml || die "appcast.xml already has $VERSION"

# Sparkle compares CFBundleVersion, so every release gets the next build number.
BUILD=$(( $(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)"/\1/p' project.yml) + 1 ))
sed -i '' -e "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" \
  -e "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
trap '[ -n "$DONE" ] || git checkout -q project.yml' EXIT

APP=$(scripts/build.sh --release build-release)
BIN=build-release/SourcePackages/artifacts/sparkle/Sparkle/bin
mkdir -p dist
rm -rf dist/Shift.app
ditto "$APP" dist/Shift.app

# Inside out: Sparkle's helpers, the framework, then the app (Sparkle's documented order).
sign() {
  if [ -n "$DEVELOPER_ID" ]; then codesign -f -s "$DEVELOPER_ID" -o runtime --timestamp "$@"
  else codesign -f -s - "$@"; fi
}
S=dist/Shift.app/Contents/Frameworks/Sparkle.framework
sign "$S/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$S/Versions/B/XPCServices/Downloader.xpc"
sign "$S/Versions/B/Autoupdate"
sign "$S/Versions/B/Updater.app"
sign "$S"
sign dist/Shift.app
codesign --verify --deep --strict dist/Shift.app

if [ -n "$NOTARY_PROFILE" ]; then
  ditto -c -k --keepParent dist/Shift.app dist/notarize.zip
  xcrun notarytool submit dist/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
  rm dist/notarize.zip
  xcrun stapler staple dist/Shift.app
fi

ZIP=dist/Shift-$VERSION.zip
rm -f "$ZIP"
ditto -c -k --keepParent dist/Shift.app "$ZIP"

git commit -qm "Release $VERSION" project.yml
DONE=1

# Appcast item. Sparkle reads markdown release notes when marked as such, HTML otherwise.
if [ -n "$SHIFT_FEED_URL" ]; then URL=${SHIFT_FEED_URL%/*}/Shift-$VERSION.zip
else URL=https://github.com/fabiogiolito/shift/releases/download/v$VERSION/Shift-$VERSION.zip; fi
DESC=
if [ -n "$NOTES" ]; then
  case $NOTES in *.md|*.markdown) FORMAT=' sparkle:format="markdown"' ;; *) FORMAT= ;; esac
  DESC="      <description$FORMAT><![CDATA[$(cat "$NOTES")]]></description>"
fi
[ -f appcast.xml ] || cat > appcast.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Shift</title>
  </channel>
</rss>
EOF
ITEM=$(mktemp)
cat > "$ITEM" <<EOF
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
$DESC
      <enclosure url="$URL" $("$BIN/sign_update" "$ZIP") type="application/octet-stream"/>
    </item>
EOF
awk -v item="$ITEM" '/<\/channel>/ { while ((getline l < item) > 0) print l } { print }' appcast.xml > appcast.xml.new
mv appcast.xml.new appcast.xml
rm "$ITEM"

if [ -n "$NOTES" ]; then NOTES_ARG="--notes-file '$NOTES'"; else NOTES_ARG="--notes ''"; fi
CMDS="git tag v$VERSION
git push origin main v$VERSION
gh release create v$VERSION $ZIP --title 'Shift $VERSION' $NOTES_ARG
git add appcast.xml && git commit -m 'Appcast: $VERSION'
git push origin main"

echo "Built $ZIP (build $BUILD, signed ${DEVELOPER_ID:-ad-hoc}${NOTARY_PROFILE:+, notarized}); appcast.xml updated."
if [ "$PUBLISH" = 1 ]; then
  echo "$CMDS" | sh -ex
else
  echo "To publish, run:"
  echo "$CMDS" | sed 's/^/  /'
fi
