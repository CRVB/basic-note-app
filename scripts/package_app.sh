#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
APP_EXECUTABLE_NAME="NoteLight"
APP_BUNDLE_NAME="Yazboz Note.app"
APP_PARENT_DIR="$ROOT_DIR/dist/$CONFIGURATION"
APP_BUNDLE_PATH="$APP_PARENT_DIR/$APP_BUNDLE_NAME"
CONTENTS_PATH="$APP_BUNDLE_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$CONTENTS_PATH/Resources"
INFO_PLIST_SOURCE="$ROOT_DIR/App/Info.plist"
ENTITLEMENTS_SOURCE="$ROOT_DIR/App/NoteLight.entitlements"
APP_ICON_SOURCE="$ROOT_DIR/Sources/YazbozNoteApp/Resources/AppIcon.icns"

cd "$ROOT_DIR"

swift build -c "$CONFIGURATION"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path | tail -n 1)"
EXECUTABLE_PATH="$BIN_DIR/$APP_EXECUTABLE_NAME"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Executable not found: $EXECUTABLE_PATH" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE_PATH"
mkdir -p "$MACOS_PATH" "$RESOURCES_PATH"

cp "$EXECUTABLE_PATH" "$MACOS_PATH/$APP_EXECUTABLE_NAME"
cp "$INFO_PLIST_SOURCE" "$CONTENTS_PATH/Info.plist"

if [[ -f "$APP_ICON_SOURCE" ]]; then
  cp "$APP_ICON_SOURCE" "$RESOURCES_PATH/AppIcon.icns"
fi

/usr/bin/codesign --force --sign - --entitlements "$ENTITLEMENTS_SOURCE" --timestamp=none "$APP_BUNDLE_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE_PATH"

echo "$APP_BUNDLE_PATH"
