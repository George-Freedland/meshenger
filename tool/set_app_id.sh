#!/usr/bin/env bash
# Sets Meshenger's permanent app ID, publisher and display name on every
# platform (Android, iOS, macOS, Windows, Linux, web).
#
#   tool/set_app_id.sh com.yourname.meshenger "Your Name" [Meshenger]
#
# The app ID is permanent once you publish: stores, signing keys and
# updates are tied to it. Changing it also gives the app a fresh data
# location on each machine, so identities created under the old ID stop
# showing up (their files are left in place, not deleted).
set -euo pipefail

usage() {
  echo "usage: tool/set_app_id.sh <app id> \"<publisher name>\" [display name]" >&2
  echo "  e.g. tool/set_app_id.sh com.georgefreedland.meshenger \"George Freedland\"" >&2
  exit 1
}

APP_ID="${1:-}"
PUBLISHER="${2:-}"
NAME="${3:-Meshenger}"
[[ -n "$APP_ID" && -n "$PUBLISHER" ]] || usage

# Lowercase letters and digits only, 3+ parts: valid on Android, Apple and Linux.
if [[ ! "$APP_ID" =~ ^[a-z][a-z0-9]*(\.[a-z][a-z0-9]*){2,}$ ]]; then
  echo "App ID must look like com.yourname.meshenger (lowercase letters/digits, 3+ parts, no - or _)." >&2
  exit 1
fi
# Used as the macOS bundle name and in Xcode paths, so keep it simple.
if [[ ! "$NAME" =~ ^[A-Za-z][A-Za-z0-9]{0,14}$ ]]; then
  echo "Display name must be letters/digits, max 15 characters (e.g. Meshenger)." >&2
  exit 1
fi
if [[ "$PUBLISHER" == *'"'* || "$PUBLISHER" == *'\'* ]]; then
  echo "Publisher name can't contain quotes or backslashes." >&2
  exit 1
fi

cd "$(dirname "$0")/.."
YEAR="$(date +%Y)"

OLD_ID="$(perl -ne 'print $1 if /applicationId\s*=\s*"([^"]+)"/' android/app/build.gradle.kts)"
OLD_NAME="$(perl -ne 'print $1 if /^PRODUCT_NAME\s*=\s*(\S+)/' macos/Runner/Configs/AppInfo.xcconfig)"
OLD_PUBLISHER="$(perl -ne 'print $1 if /VALUE "CompanyName", "([^"]*)"/' windows/runner/Runner.rc)"
[[ -n "$OLD_ID" && -n "$OLD_NAME" && -n "$OLD_PUBLISHER" ]] || {
  echo "Couldn't read the current app ID/name/publisher; is this the Meshenger repo?" >&2
  exit 1
}

echo "App ID:    $OLD_ID -> $APP_ID"
echo "Name:      $OLD_NAME -> $NAME"
echo "Publisher: $OLD_PUBLISHER -> $PUBLISHER"
echo
echo "Identities created under the old ID won't appear afterwards (files stay on disk)."
read -r -p "Continue? [y/N] " answer
[[ "$answer" == [yY]* ]] || { echo "Nothing changed."; exit 1; }

export OLD_ID APP_ID OLD_NAME NAME OLD_PUBLISHER PUBLISHER YEAR

# Literal (not regex) replacement of $FROM with $TO in the given files.
replace() {
  local from="$1" to="$2"; shift 2
  FROM="$from" TO="$to" perl -pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$@"
}

# --- Android
replace "\"$OLD_ID\"" "\"$APP_ID\"" android/app/build.gradle.kts
perl -pi -e 's/android:label="[^"]*"/android:label="$ENV{NAME}"/' \
  android/app/src/main/AndroidManifest.xml
KOTLIN_ROOT=android/app/src/main/kotlin
OLD_DIR="$KOTLIN_ROOT/${OLD_ID//.//}"
NEW_DIR="$KOTLIN_ROOT/${APP_ID//.//}"
if [[ "$OLD_DIR" != "$NEW_DIR" ]]; then
  mkdir -p "$NEW_DIR"
  mv "$OLD_DIR"/*.kt "$NEW_DIR"/
  # Remove now-empty package directories left behind.
  find "$KOTLIN_ROOT" -type d -empty -delete
fi
perl -pi -e 's/^package \S+/package $ENV{APP_ID}/' "$NEW_DIR"/*.kt

# --- iOS
replace "$OLD_ID" "$APP_ID" ios/Runner.xcodeproj/project.pbxproj
perl -0pi -e 's{(<key>CFBundleDisplayName</key>\s*<string>)[^<]*}{$1$ENV{NAME}}; s{(<key>CFBundleName</key>\s*<string>)[^<]*}{$1$ENV{NAME}}' \
  ios/Runner/Info.plist

# --- macOS
perl -pi -e '
  s/^PRODUCT_NAME = .*/PRODUCT_NAME = $ENV{NAME}/;
  s/^PRODUCT_BUNDLE_IDENTIFIER = .*/PRODUCT_BUNDLE_IDENTIFIER = $ENV{APP_ID}/;
  s/^PRODUCT_COPYRIGHT = .*/PRODUCT_COPYRIGHT = Copyright © $ENV{YEAR} $ENV{PUBLISHER}. All rights reserved./;
' macos/Runner/Configs/AppInfo.xcconfig
replace "$OLD_ID" "$APP_ID" macos/Runner.xcodeproj/project.pbxproj
replace "$OLD_NAME.app" "$NAME.app" \
  macos/Runner.xcodeproj/project.pbxproj \
  macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme
replace "/$OLD_NAME\";" "/$NAME\";" macos/Runner.xcodeproj/project.pbxproj

# --- Windows (the data folder lives under %APPDATA%\<publisher>\<name>)
perl -pi -e '
  s/(VALUE "CompanyName", ")[^"]*/$1$ENV{PUBLISHER}/;
  s/(VALUE "FileDescription", ")[^"]*/$1$ENV{NAME}/;
  s/(VALUE "ProductName", ")[^"]*/$1$ENV{NAME}/;
  s/(VALUE "LegalCopyright", ")[^"]*/$1Copyright (C) $ENV{YEAR} $ENV{PUBLISHER}. All rights reserved./;
' windows/runner/Runner.rc
perl -pi -e 's/window\.Create\(L"[^"]*"/window.Create(L"$ENV{NAME}"/' windows/runner/main.cpp

# --- Linux
replace "\"$OLD_ID\"" "\"$APP_ID\"" linux/CMakeLists.txt
perl -pi -e 's/(gtk_(?:header_bar|window)_set_title\([^,]+, ")[^"]*/$1$ENV{NAME}/' \
  linux/runner/my_application.cc

# --- Web
perl -pi -e 's/("(?:short_)?name": ")[^"]*/$1$ENV{NAME}/' web/manifest.json
perl -pi -e 's/(<title>)[^<]*/$1$ENV{NAME}/; s/(apple-mobile-web-app-title" content=")[^"]*/$1$ENV{NAME}/' \
  web/index.html

echo
echo "Done. Leftover references to the old ID (should be none):"
grep -rIn --exclude-dir=build --exclude-dir=.dart_tool --exclude-dir=Pods \
  -e "$OLD_ID" android ios macos windows linux web || echo "  none"
echo
echo "Next: flutter clean && flutter pub get, then rebuild each platform."
