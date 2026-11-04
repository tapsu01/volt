#!/bin/sh
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

ROOT_DIR="$(cd "$(/usr/bin/dirname "$0")/.." && pwd)"
APP_DIR="${1:-$ROOT_DIR/build/Volt.app}"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MANIFEST_PATH="$RESOURCES_DIR/DependencyManifest.json"

fail() {
  /usr/bin/printf 'verify-build failed: %s\n' "$1" >&2
  exit 1
}

manifest_sha() {
  name="$1"
  /usr/bin/sed -n "/\"name\": \"$name\"/s/.*\"sha256\": \"\([^\"]*\)\".*/\1/p" "$MANIFEST_PATH" | /usr/bin/head -n 1
}

verify_hash() {
  name="$1"
  path="$2"
  expected="$(manifest_sha "$name")"
  [ -n "$expected" ] || fail "missing $name hash in DependencyManifest.json"
  actual="$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}')"
  [ "$actual" = "$expected" ] || fail "$name hash mismatch"
}

[ -d "$APP_DIR" ] || fail "app bundle not found at $APP_DIR"
[ -f "$MANIFEST_PATH" ] || fail "DependencyManifest.json is missing"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"

single_dylib() {
  pattern="$1"
  set -- "$FRAMEWORKS_DIR"/$pattern
  [ $# -eq 1 ] && [ -f "$1" ] || fail "expected exactly one $pattern in $FRAMEWORKS_DIR"
  /usr/bin/printf '%s\n' "$1"
}

SSL_DYLIB="$(single_dylib 'libssl.*.dylib')"
CRYPTO_DYLIB="$(single_dylib 'libcrypto.*.dylib')"
SSL_LIB_NAME="$(/usr/bin/basename "$SSL_DYLIB")"
CRYPTO_LIB_NAME="$(/usr/bin/basename "$CRYPTO_DYLIB")"

verify_hash "libssh2" "$FRAMEWORKS_DIR/libssh2.1.dylib"
verify_hash "libssl" "$SSL_DYLIB"
verify_hash "libcrypto" "$CRYPTO_DYLIB"

for binary in "$MACOS_DIR/Volt" "$FRAMEWORKS_DIR/libssh2.1.dylib" "$SSL_DYLIB" "$CRYPTO_DYLIB"; do
  [ -f "$binary" ] || fail "missing binary: $binary"
  if /usr/bin/otool -L "$binary" | /usr/bin/grep -E '/opt/homebrew|/usr/local' >/dev/null; then
    /usr/bin/otool -L "$binary" >&2
    fail "Homebrew path leaked into runtime load commands for $binary"
  fi
done

require_link() {
  binary="$1"
  expected="$2"
  if ! /usr/bin/otool -L "$binary" | /usr/bin/grep -F "$expected" >/dev/null; then
    /usr/bin/otool -L "$binary" >&2
    fail "$binary does not link against bundled $expected"
  fi
}
require_link "$FRAMEWORKS_DIR/libssh2.1.dylib" "@loader_path/$SSL_LIB_NAME"
require_link "$FRAMEWORKS_DIR/libssh2.1.dylib" "@loader_path/$CRYPTO_LIB_NAME"
require_link "$SSL_DYLIB" "@loader_path/$CRYPTO_LIB_NAME"
require_link "$MACOS_DIR/Volt" "@executable_path/../Frameworks/libssh2.1.dylib"

/usr/bin/printf 'Volt build verification passed: %s\n' "$APP_DIR"
