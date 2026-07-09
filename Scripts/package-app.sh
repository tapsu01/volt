#!/bin/sh
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

ROOT_DIR="$(cd "$(/usr/bin/dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/x86_64-apple-macosx/debug"
APP_DIR="$ROOT_DIR/build/Volt.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

/usr/bin/env PATH="$PATH" \
  CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache" \
  HOME="$ROOT_DIR/.build/home" \
  /usr/bin/swift build

/bin/rm -rf "$APP_DIR"
/bin/mkdir -p "$MACOS_DIR"
/bin/cp "$BUILD_DIR/Volt" "$MACOS_DIR/Volt"
/bin/cp "$ROOT_DIR/Support/Info.plist" "$CONTENTS_DIR/Info.plist"
/bin/mkdir -p "$CONTENTS_DIR/Resources"
/bin/cp "$ROOT_DIR/Support/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - --options runtime --entitlements "$ROOT_DIR/Support/Volt.entitlements" "$APP_DIR"

printf '%s\n' "$APP_DIR"
