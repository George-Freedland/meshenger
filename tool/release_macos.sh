#!/usr/bin/env bash
# Builds Meshenger for macOS and packages it into build/dist/:
#   <Name>-macOS.dmg  (drag-to-Applications installer)
#   <Name>-macOS.zip
#
# Unsigned by default, which is fine on your own Mac. Public downloads
# must be signed and notarized or macOS refuses to open them:
#
#   export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   export NOTARY_PROFILE=meshenger-notary   # see CONTRIBUTING.md
#   tool/release_macos.sh
#
# MAC_ARCHS=arm64 builds for Apple silicon only (default: Intel + Apple
# silicon). Flutter older than the late-July-2026 stable fails universal
# builds on Xcode 27 (flutter/flutter#188346), so use it until you upgrade.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [[ -n "${MAC_ARCHS:-}" ]]; then
  export FLUTTER_XCODE_ARCHS="$MAC_ARCHS"
fi
if [[ -n "$NOTARY_PROFILE" && -z "$SIGN_IDENTITY" ]]; then
  echo "NOTARY_PROFILE needs SIGN_IDENTITY too (Apple only notarizes signed apps)." >&2
  exit 1
fi

flutter build macos --release

APP="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' -print -quit)"
[[ -n "$APP" ]] || { echo "No .app found in build/macos/Build/Products/Release" >&2; exit 1; }
NAME="$(basename "$APP" .app)"
DIST=build/dist
mkdir -p "$DIST"

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Signing $APP with: $SIGN_IDENTITY"
  # Inside-out: nested frameworks first (no entitlements), then the app.
  find "$APP/Contents/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -print0 |
    while IFS= read -r -d '' item; do
      codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$item"
    done
  codesign --force --options runtime --timestamp \
    --entitlements macos/Runner/Release.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"

  if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "Notarizing the app (usually 1-10 minutes)…"
    ditto -c -k --keepParent "$APP" "$DIST/notarize-app.zip"
    notarize "$DIST/notarize-app.zip"
    rm "$DIST/notarize-app.zip"
    # Stapling lets the app pass Gatekeeper on a Mac with no internet.
    xcrun stapler staple "$APP"
  fi
fi

DMG="$DIST/$NAME-macOS.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "Notarizing the DMG…"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
  fi
fi

ZIP="$DIST/$NAME-macOS.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
if [[ -n "$NOTARY_PROFILE" ]]; then
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" || true
  echo "Signed + notarized:"
elif [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Signed but NOT notarized (other Macs will still warn):"
else
  echo "Unsigned (for your own testing only):"
fi
ls -lh "$DMG" "$ZIP"
