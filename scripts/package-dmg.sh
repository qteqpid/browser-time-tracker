#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/mac-menubar"
PACKAGING_DIR="$APP_DIR/Packaging"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="Browser Time Tracker"
PROJECT_PATH="$APP_DIR/BrowserTimeTracker.xcodeproj"
SCHEME_NAME="Browser Time Tracker"
ARCHIVE_PATH="$DIST_DIR/BrowserTimeTracker.xcarchive"
APP_BUNDLE="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
DMG_ROOT="$DIST_DIR/dmg-root"
DMG_PATH="$DIST_DIR/BrowserTimeTracker.dmg"
RW_DMG_PATH="$DIST_DIR/BrowserTimeTracker-rw.dmg"
DMG_BACKGROUND_SVG="$PACKAGING_DIR/dmg-background.svg"
SKIP_SIGNING="${SKIP_SIGNING:-0}"
DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$DIST_DIR/DerivedData}"

detect_developer_id() {
  security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p'
}

if [[ "$SKIP_SIGNING" != "1" && -z "$DEVELOPER_ID" ]]; then
  developer_ids=("${(@f)$(detect_developer_id)}")
  if [[ "${#developer_ids[@]}" == "1" && -n "${developer_ids[1]}" ]]; then
    DEVELOPER_ID="${developer_ids[1]}"
    echo "Using detected Developer ID: $DEVELOPER_ID"
  elif [[ "${#developer_ids[@]}" == "0" || -z "${developer_ids[1]:-}" ]]; then
    echo "No Developer ID Application certificate found in your keychain."
    echo "Create one in Xcode: Settings -> Accounts -> Manage Certificates -> + -> Developer ID Application"
    echo 'Then run: DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/package-dmg.sh'
    exit 1
  else
    echo "Multiple Developer ID Application certificates found:"
    printf '  %s\n' "${developer_ids[@]}"
    echo 'Set the one to use explicitly, for example:'
    echo 'DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/package-dmg.sh'
    exit 1
  fi
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

xcodebuild_args=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME_NAME"
  -configuration Release
  -archivePath "$ARCHIVE_PATH"
  -derivedDataPath "$DERIVED_DATA_PATH"
  archive
  SKIP_INSTALL=NO
)

if [[ "$SKIP_SIGNING" == "1" ]]; then
  xcodebuild_args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="")
fi

/usr/bin/xcodebuild "${xcodebuild_args[@]}"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Xcode archive did not produce $APP_BUNDLE"
  exit 1
fi

if [[ "$SKIP_SIGNING" != "1" ]]; then
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
else
  echo "Built unsigned app for local testing."
fi

mkdir -p "$DMG_ROOT"
cp -R "$APP_BUNDLE" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
mkdir -p "$DMG_ROOT/.background"
if [[ -f "$DMG_BACKGROUND_SVG" ]]; then
  cp "$DMG_BACKGROUND_SVG" "$DMG_ROOT/.background/background.svg"
  /usr/bin/sips -s format png "$DMG_ROOT/.background/background.svg" --out "$DMG_ROOT/.background/background.png" >/dev/null 2>&1 || true
fi

/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDRW \
  "$RW_DMG_PATH"

device=$(/usr/bin/hdiutil attach "$RW_DMG_PATH" -readwrite -noverify -noautoopen | awk '/\\/Volumes\\// {print $1; exit}')
volume="/Volumes/$APP_NAME"

cleanup_dmg_mount() {
  if [[ -n "${device:-}" ]]; then
    /usr/bin/hdiutil detach "$device" -quiet >/dev/null 2>&1 || true
  fi
}
trap cleanup_dmg_mount EXIT

/usr/bin/osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {120, 120, 760, 500}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 13
    try
      set background picture of viewOptions to file ".background:background.png"
    end try
    set position of item "$APP_NAME.app" of container window to {180, 190}
    set position of item "Applications" of container window to {460, 190}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
APPLESCRIPT

/bin/sync
/usr/bin/hdiutil detach "$device" -quiet
device=""

/usr/bin/hdiutil convert "$RW_DMG_PATH" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH"

rm -f "$RW_DMG_PATH"

if [[ "$SKIP_SIGNING" != "1" ]]; then
  /usr/bin/codesign --force \
    --sign "$DEVELOPER_ID" \
    --timestamp \
    "$DMG_PATH"

  if [[ -n "$NOTARY_PROFILE" ]]; then
    /usr/bin/xcrun notarytool submit "$DMG_PATH" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait
    /usr/bin/xcrun stapler staple "$DMG_PATH"
  else
    echo "NOTARY_PROFILE not set; skipping notarization."
  fi
fi

echo "Built: $DMG_PATH"
