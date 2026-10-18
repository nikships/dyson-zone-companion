#!/bin/sh
# Builds a release binary, wraps it in DysonZone.app, ad-hoc signs it, and installs to ~/Applications.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/DysonZone.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/DysonZone" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign -s - --force "$APP"
if [ "$1" = "--install" ]; then
    pkill -x DysonZone 2>/dev/null || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/DysonZone.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/DysonZone.app
fi
echo "Built $APP"
