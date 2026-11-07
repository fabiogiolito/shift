#!/bin/sh
# Releases the Mac app (GitHub release + appcast.xml), the iPhone app (TestFlight), or both, with one version and
# build number. See docs/RELEASING.md.
# Usage: scripts/release.sh [--mac | --ios] [version] [release-notes.md|.html] [--publish]
#   (neither) both apps.
#   --mac     only the Mac app: no iPhone archive, nothing goes to TestFlight.
#   --ios     only the iPhone app: no Mac build, tag, GitHub release or appcast item. Keeps the current version
#             unless one is given; the build number goes up as always.
# Without a version, the Mac app gets the patch number after the last release tag (0.1.1 -> 0.1.2).
# Without notes, scripts/release-notes.sh writes the Mac notes from the commits since the last release.
# Without --publish nothing touches the network (except notarization, and Xcode fetching signing profiles for the
# iPhone archive); the publish commands are printed instead.
# Apple auth: the App Store Connect API key in ~/.appstoreconnect/shift.env (ASC_KEY_ID, ASC_ISSUER_ID,
# ASC_KEY_PATH) signs and uploads the iPhone app and notarizes the Mac app, with no Xcode login or keychain
# password. Without it, the Apple ID signed in to Xcode and the NOTARY_PROFILE keychain profile.
# Env: DEVELOPER_ID   "Developer ID Application: …" signs with it (hardened runtime); ad-hoc otherwise.
#                     Defaults to the Developer ID Application certificate in the keychain, if there is one.
#      NOTARY_PROFILE notarytool keychain profile, used when there's no API key. Defaults to
#                     "shift-notary" when that profile exists.
#      ASC_ENV        the API key file to read instead of ~/.appstoreconnect/shift.env.
#      SHIFT_FEED_URL testing only: builds against this feed and puts the archive's URL next to it.
set -e
cd "$(dirname "$0")/.."
die() { echo "release: $*" >&2; exit 1; }

ASC_ENV=${ASC_ENV:-$HOME/.appstoreconnect/shift.env}
[ ! -f "$ASC_ENV" ] || . "$ASC_ENV"
ASC_AUTH=
if [ -n "$ASC_KEY_ID" ]; then
  [ -f "$ASC_KEY_PATH" ] || die "no API key at $ASC_KEY_PATH (from $ASC_ENV)"
  ASC_AUTH="-authenticationKeyPath $ASC_KEY_PATH -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"
fi

PUBLISH=0 VERSION= NOTES= MAC= IOS=
for a do
  case $a in
    --publish) PUBLISH=1 ;;
    --mac) MAC=1 ;;
    --ios) IOS=1 ;;
    -*) die "unknown option $a" ;;
    *) if [ -z "$VERSION" ]; then VERSION=$a; else NOTES=$a; fi ;;
  esac
done
# Neither flag: both apps.
[ -n "$MAC$IOS" ] || MAC=1 IOS=1

if [ -n "$MAC" ]; then
  # Sign and notarize whenever this Mac can, so a release is never unsigned by accident.
  : "${DEVELOPER_ID:=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
  if [ -n "$ASC_KEY_ID" ]; then
    NOTARY_AUTH="--key $ASC_KEY_PATH --key-id $ASC_KEY_ID --issuer $ASC_ISSUER_ID"
  else
    : "${NOTARY_PROFILE:=$(xcrun notarytool history --keychain-profile shift-notary >/dev/null 2>&1 && echo shift-notary)}"
    NOTARY_AUTH=${NOTARY_PROFILE:+--keychain-profile $NOTARY_PROFILE}
  fi
  # Apple only notarizes apps signed with a Developer ID.
  [ -n "$DEVELOPER_ID" ] || NOTARY_AUTH=
  echo "release: signing with ${DEVELOPER_ID:-ad-hoc}; notarizing ${NOTARY_AUTH:+with }${NOTARY_AUTH:-nothing}" >&2
fi

[ -z "$NOTES" ] || [ -f "$NOTES" ] || die "no such file: $NOTES"
[ -z "$(git status --porcelain)" ] || die "uncommitted changes; commit or stash them first"
[ "$(git branch --show-current)" = main ] || die "not on main"
if [ -z "$VERSION" ] && [ -n "$MAC" ]; then
  LAST=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null) || die "no release tag yet; give a version"
  VERSION=$(echo "${LAST#v}" | awk -F. '{ printf "%d.%d.%d", $1, $2, $3 + 1 }')
fi
# The iPhone app alone keeps the version the Mac app last shipped as.
[ -n "$VERSION" ] || VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
if [ -n "$MAC" ]; then
  if [ -z "$NOTES" ]; then
    mkdir -p dist
    NOTES=dist/notes-$VERSION.md
    scripts/release-notes.sh > "$NOTES" || die "couldn't write release notes"
    printf 'release: %s notes:\n%s\n' "$VERSION" "$(cat "$NOTES")" >&2
  fi
  ! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "tag v$VERSION already exists"
  ! grep -qs "<sparkle:shortVersionString>$VERSION<" appcast.xml || die "appcast.xml already has $VERSION"
fi

# Sparkle and TestFlight both compare the build number, so every release of either app gets the next one.
BUILD=$(( $(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)"/\1/p' project.yml) + 1 ))
sed -i '' -e "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" \
  -e "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
trap '[ -n "$DONE" ] || git checkout -q project.yml' EXIT

if [ -n "$MAC" ]; then
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

  if [ -n "$NOTARY_AUTH" ]; then
    ditto -c -k --keepParent dist/Shift.app dist/notarize.zip
    xcrun notarytool submit dist/notarize.zip $NOTARY_AUTH --wait
    rm dist/notarize.zip
    xcrun stapler staple dist/Shift.app
  fi
fi

if [ -n "$IOS" ]; then
  # Archived now so a signing failure stops the release before anything is committed. The Mac build generated the
  # project already; alone, this does what scripts/build.sh does first.
  if [ -z "$MAC" ]; then
    xcodegen generate --quiet
    sed -i '' 's|path = AppIcon.icon;|lastKnownFileType = folder.iconcomposer.icon; path = AppIcon.icon;|' Shift.xcodeproj/project.pbxproj
  fi
  mkdir -p dist
  rm -rf dist/ShiftMobile.xcarchive
  xcodebuild -project Shift.xcodeproj -scheme ShiftMobile -configuration Release -destination generic/platform=iOS \
    -archivePath dist/ShiftMobile.xcarchive -allowProvisioningUpdates $ASC_AUTH -quiet archive >&2
  cat > dist/ExportOptions.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF
fi

if [ -n "$MAC" ]; then
  ZIP=dist/Shift-$VERSION.zip
  rm -f "$ZIP"
  ditto -c -k --keepParent dist/Shift.app "$ZIP"
  git commit -qm "Release $VERSION" project.yml
else
  git commit -qm "Release iOS $VERSION ($BUILD)" project.yml
fi
DONE=1

CMDS=
if [ -n "$MAC" ]; then
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
else
  CMDS="git push origin main"
fi
if [ -n "$IOS" ]; then
  CMDS="$CMDS
xcodebuild -exportArchive -archivePath dist/ShiftMobile.xcarchive -exportOptionsPlist dist/ExportOptions.plist -exportPath dist/testflight -allowProvisioningUpdates $ASC_AUTH"
fi

[ -z "$MAC" ] || echo "Built $ZIP (build $BUILD, signed ${DEVELOPER_ID:-ad-hoc}${NOTARY_AUTH:+, notarized}); appcast.xml updated."
[ -z "$IOS" ] || echo "Archived dist/ShiftMobile.xcarchive ($VERSION, build $BUILD) for TestFlight."
if [ "$PUBLISH" = 1 ]; then
  echo "$CMDS" | sh -ex
else
  echo "To publish, run:"
  echo "$CMDS" | sed 's/^/  /'
fi
