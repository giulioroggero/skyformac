#!/usr/bin/env bash
set -euo pipefail

# Builds, signs, and notarizes a distributable Skyformac.dmg — Developer ID direct
# distribution (GitHub Releases + Homebrew Cask), *not* a Mac App Store submission;
# see docs/distribution.md for the one-time setup this script assumes is already
# done: a "Developer ID Application" certificate in your keychain, and notarytool
# credentials stored under a keychain profile (`xcrun notarytool store-credentials`).
#
# Required environment:
#   SKYFORMAC_TEAM_ID          Your Apple Developer Team ID (e.g. "ABCDE12345").
# Optional:
#   SKYFORMAC_NOTARY_PROFILE   notarytool keychain profile name (default: skyformac-notarize)

cd "$(dirname "$0")/.."

PROJECT="skyformac.xcodeproj"
SCHEME="skyformac"
BUILD_DIR="build/release"
ARCHIVE_PATH="$BUILD_DIR/skyformac.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
NOTARY_PROFILE="${SKYFORMAC_NOTARY_PROFILE:-skyformac-notarize}"

if [ -z "${SKYFORMAC_TEAM_ID:-}" ]; then
  echo "error: SKYFORMAC_TEAM_ID is not set — export your Apple Developer Team ID first:" >&2
  echo "  export SKYFORMAC_TEAM_ID=ABCDE12345" >&2
  echo "(Find it at https://developer.apple.com/account under Membership Details.)" >&2
  exit 1
fi

VERSION=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings -configuration Release 2>/dev/null \
  | awk -F' = ' '/MARKETING_VERSION/ { print $2; exit }')
if [ -z "$VERSION" ]; then
  echo "error: couldn't read MARKETING_VERSION from the project." >&2
  exit 1
fi

DMG_PATH="$BUILD_DIR/Skyformac-$VERSION.dmg"

echo "==> Archiving Skyformac $VERSION (Developer ID, team $SKYFORMAC_TEAM_ID)"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'generic/platform=macOS' \
  DEVELOPMENT_TEAM="$SKYFORMAC_TEAM_ID" \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  CODE_SIGN_STYLE=Manual

# Generated on the fly (not committed) so the real Team ID never has to live in a
# tracked file — exportOptionsPlist needs it to pick which Developer ID identity's
# certificate to export with.
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$SKYFORMAC_TEAM_ID</string>
	<key>signingStyle</key>
	<string>manual</string>
</dict>
</plist>
PLIST

echo "==> Exporting signed .app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

APP_PATH="$EXPORT_PATH/skyformac.app"
if [ ! -d "$APP_PATH" ]; then
  echo "error: expected $APP_PATH after export, but it doesn't exist." >&2
  exit 1
fi

echo "==> Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute -v "$APP_PATH"

echo "==> Building $DMG_PATH"
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "Skyformac $VERSION" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"

echo "==> Notarizing (this can take a few minutes)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"

echo "==> Final Gatekeeper check"
spctl -a -t open --context context:primary-signature -v "$DMG_PATH"

echo ""
echo "==> Done: $DMG_PATH"
echo "Next: upload this file to the GitHub Release for v$VERSION, then update"
echo "Casks/skyformac.rb with the new version and 'shasum -a 256 $DMG_PATH'."
