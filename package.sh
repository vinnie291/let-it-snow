#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="LetItSnow"
VERSION="1.1.0"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"
STAGE_DIR="$BUILD_DIR/dmg-staging"

DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION-Universal.dmg"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION-Universal.zip"

"$ROOT_DIR/build.sh"

mkdir -p "$DIST_DIR"
rm -rf "$STAGE_DIR" "$DMG_PATH" "$ZIP_PATH"
mkdir -p "$STAGE_DIR"

echo "Staging release artifacts..."
cp -R "$APP_BUNDLE" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

cat > "$STAGE_DIR/Read Me First.txt" <<'TXT'
Let It Snow — macOS Desktop Snow App (v1.1.0, Universal: Apple Silicon & Intel)
Requires macOS 14.0 (Sonoma) or newer.

INSTALL
1. Drag LetItSnow.app into the Applications folder.
2. Open LetItSnow from Applications.

FIRST LAUNCH (macOS Gatekeeper)
Because this app is shared directly rather than from the Mac App Store:
- If macOS says "Apple could not verify LetItSnow":
  1. Click Done.
  2. Open System Settings -> Privacy & Security.
  3. Scroll down to the Security section and click "Open Anyway" next to LetItSnow.

OPTIONAL PERMISSIONS (for full physics on everything)
- Accessibility (in Settings -> Enable Access):
  Lets snow detect exact positions of your Desktop icons, folders, and Dock icons.
- Screen Recording (in Settings -> Scan Live Wallpaper):
  Lets snow scan your live/dynamic desktop wallpaper so flakes land on people & objects
  (or click "Choose Photo..." in Settings to scan any image with no extra permission).

CONTROLS
- Use the snowflake icon in the top macOS Menu Bar to open Settings, trigger a
  Wind Gust, Shake Icons, Clear Snow, switch Presets, or Quit.
- Move your cursor through snow piles to swirl flakes and brush snow off icons!
TXT

echo "Creating compressed DMG at $DMG_PATH..."
hdiutil create \
    -volname "Let It Snow" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

echo "Creating ZIP archive at $ZIP_PATH..."
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

rm -rf "$STAGE_DIR"

echo "Verifying binary architectures & signatures..."
lipo -info "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
codesign --verify --deep --strict "$APP_BUNDLE"

echo ""
echo "Packaged for sharing:"
ls -lh "$DMG_PATH" "$ZIP_PATH"
