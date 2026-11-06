#!/bin/zsh
# Builds "Screen Recorder.app" and installs it on the Desktop.
#
# Signing: by default the app is signed ad-hoc (fine for running on your own Mac).
# To sign with a Developer ID and notarize, set these (e.g. in an untracked
# build.local.env next to this script):
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE="your-notarytool-keychain-profile"
#
# Flags: --no-notarize  skip notarization
#        --no-install   build + sign only; leave the running app alone
set -euo pipefail
cd "$(dirname "$0")"
[[ -f build.local.env ]] && source build.local.env

IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
DEST="$HOME/Desktop/Screen Recorder.app"
BUILD="build"
APP="$BUILD/Screen Recorder.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" Info.plist)
NOTARIZE=1; INSTALL=1
for arg in "$@"; do
  [[ "$arg" == "--no-notarize" ]] && NOTARIZE=0
  [[ "$arg" == "--no-install" ]] && INSTALL=0
done
[[ "$IDENTITY" == "-" || -z "$NOTARY_PROFILE" ]] && NOTARIZE=0

rm -rf "$BUILD"; mkdir -p "$BUILD"

echo "→ Icon"
xcrun swiftc -O tools/make_icon.swift -o "$BUILD/make_icon"
"$BUILD/make_icon" "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"

echo "→ Compile"
xcrun swiftc -O -parse-as-library -swift-version 5 \
  -target arm64-apple-macos15.0 \
  Sources/*.swift -o "$BUILD/ScreenRecorder"

echo "→ Bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/ScreenRecorder" "$APP/Contents/MacOS/ScreenRecorder"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp Info.plist "$APP/Contents/Info.plist"

if [[ "$IDENTITY" == "-" ]]; then
  echo "→ Sign (ad-hoc)"
  codesign --force --sign - --entitlements ScreenRecorder.entitlements "$APP"
else
  echo "→ Sign (Developer ID)"
  codesign --force --timestamp --options runtime \
    --entitlements ScreenRecorder.entitlements --sign "$IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"

if (( NOTARIZE )); then
  echo "→ Notarize"
  ditto -c -k --keepParent "$APP" "$BUILD/ScreenRecorder.zip"
  xcrun notarytool submit "$BUILD/ScreenRecorder.zip" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute -vv "$APP"
fi

if (( ! INSTALL )); then echo "✓ Built (not installed): $APP"; exit 0; fi

echo "→ Install"
if pgrep -x ScreenRecorder >/dev/null; then
  # Quit politely so an in-progress recording is finished and saved, not cut off.
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" || true
  for _ in {1..30}; do pgrep -x ScreenRecorder >/dev/null || break; sleep 1; done
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "✓ Installed: $DEST"
