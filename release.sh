#!/bin/sh
# Builds a universal, Developer ID signed, notarized and stapled DMG in build/.
#
# Required environment:
#   SIGN_IDENTITY   e.g. "Developer ID Application: Your Name (TEAMID)"
#   APPLE_ID        Apple ID used for notarization
#   APPLE_PASSWORD  app-specific password for that Apple ID
#   APPLE_TEAM_ID   developer team ID
set -e
cd "$(dirname "$0")"

for v in SIGN_IDENTITY APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID; do
    eval "[ -n \"\${$v}\" ]" || { echo "Missing $v" >&2; exit 1; }
done

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
APP=build/DysonZone.app
DMG="build/DysonZone-$VERSION.dmg"
NOTARY="--apple-id $APPLE_ID --password $APPLE_PASSWORD --team-id $APPLE_TEAM_ID"

swift build -c release --arch arm64 --arch x86_64
rm -rf "$APP" "$DMG" build/notarize.zip build/dmg
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/DysonZone" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --options runtime --timestamp \
    --entitlements Resources/DysonZone.entitlements --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" build/notarize.zip
xcrun notarytool submit build/notarize.zip $NOTARY --wait
xcrun stapler staple "$APP"

mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Dyson Zone" -srcfolder build/dmg -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" $NOTARY --wait
xcrun stapler staple "$DMG"

spctl --assess -vv --type execute "$APP"
spctl --assess -vv --type open --context context:primary-signature "$DMG"
echo "Built $DMG"
