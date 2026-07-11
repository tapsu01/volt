#!/bin/sh
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

ROOT_DIR="$(cd "$(/usr/bin/dirname "$0")/.." && pwd)"
ARCH="${ARCH:-$(/usr/bin/uname -m)}"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
APP_DIR="$ROOT_DIR/build/Volt.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
LICENSES_DIR="$RESOURCES_DIR/Licenses"
ZIP_PATH="$ROOT_DIR/build/Volt-macOS-$ARCH.zip"
DMG_PATH="$ROOT_DIR/build/Volt-macOS-$ARCH.dmg"

case "$ARCH" in
  arm64|x86_64) ;;
  *) /usr/bin/printf 'Unsupported architecture: %s\n' "$ARCH" >&2; exit 1 ;;
esac

if [ -x /opt/homebrew/bin/brew ]; then
  BREW=/opt/homebrew/bin/brew
elif [ -x /usr/local/bin/brew ]; then
  BREW=/usr/local/bin/brew
else
  /usr/bin/printf 'Homebrew was not found.\n' >&2
  exit 1
fi

LIBSSH2_PREFIX="$($BREW --prefix libssh2)"
OPENSSL_PREFIX="$($BREW --prefix openssl@3)"
LIBSSH2_SOURCE="$LIBSSH2_PREFIX/lib/libssh2.1.dylib"
SSL_SOURCE="$OPENSSL_PREFIX/lib/libssl.3.dylib"
CRYPTO_SOURCE="$OPENSSL_PREFIX/lib/libcrypto.3.dylib"

check_architecture() {
  file="$1"
  file_archs="$(/usr/bin/lipo -archs "$file")"
  if [ "$file_archs" != "$ARCH" ]; then
    /usr/bin/printf 'Architecture mismatch: expected %s, found %s in %s\n' "$ARCH" "$file_archs" "$file" >&2
    exit 1
  fi
}

check_architecture "$LIBSSH2_SOURCE"
check_architecture "$SSL_SOURCE"
check_architecture "$CRYPTO_SOURCE"

export VOLT_LIBSSH2_PREFIX="$LIBSSH2_PREFIX"
/usr/bin/env PATH="$PATH" \
  VOLT_LIBSSH2_PREFIX="$VOLT_LIBSSH2_PREFIX" \
  CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache" \
  HOME="$ROOT_DIR/.build/home" \
  /usr/bin/swift build -c release --arch "$ARCH"

BUILD_DIR="$(/usr/bin/env PATH="$PATH" VOLT_LIBSSH2_PREFIX="$VOLT_LIBSSH2_PREFIX" HOME="$ROOT_DIR/.build/home" /usr/bin/swift build -c release --arch "$ARCH" --show-bin-path)"

/bin/rm -rf "$APP_DIR"
/bin/mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$LICENSES_DIR"
/bin/cp "$BUILD_DIR/Volt" "$MACOS_DIR/Volt"
/bin/cp -L "$LIBSSH2_SOURCE" "$FRAMEWORKS_DIR/libssh2.1.dylib"
/bin/cp -L "$SSL_SOURCE" "$FRAMEWORKS_DIR/libssl.3.dylib"
/bin/cp -L "$CRYPTO_SOURCE" "$FRAMEWORKS_DIR/libcrypto.3.dylib"
/bin/chmod u+w "$MACOS_DIR/Volt" "$FRAMEWORKS_DIR"/*.dylib

check_architecture "$MACOS_DIR/Volt"
check_architecture "$FRAMEWORKS_DIR/libssh2.1.dylib"
check_architecture "$FRAMEWORKS_DIR/libssl.3.dylib"
check_architecture "$FRAMEWORKS_DIR/libcrypto.3.dylib"

EXECUTABLE_LIBSSH2_PATH="$(/usr/bin/otool -L "$MACOS_DIR/Volt" | /usr/bin/awk '/libssh2\.1\.dylib/{print $1; exit}')"
LIBSSH2_SSL_PATH="$(/usr/bin/otool -L "$FRAMEWORKS_DIR/libssh2.1.dylib" | /usr/bin/awk '/libssl\.3\.dylib/{print $1; exit}')"
LIBSSH2_CRYPTO_PATH="$(/usr/bin/otool -L "$FRAMEWORKS_DIR/libssh2.1.dylib" | /usr/bin/awk '/libcrypto\.3\.dylib/{print $1; exit}')"
SSL_CRYPTO_PATH="$(/usr/bin/otool -L "$FRAMEWORKS_DIR/libssl.3.dylib" | /usr/bin/awk '/libcrypto\.3\.dylib/{print $1; exit}')"

/usr/bin/install_name_tool -change "$EXECUTABLE_LIBSSH2_PATH" "@executable_path/../Frameworks/libssh2.1.dylib" "$MACOS_DIR/Volt"
/usr/bin/install_name_tool -id "@rpath/libssh2.1.dylib" "$FRAMEWORKS_DIR/libssh2.1.dylib"
/usr/bin/install_name_tool -change "$LIBSSH2_SSL_PATH" "@loader_path/libssl.3.dylib" "$FRAMEWORKS_DIR/libssh2.1.dylib"
/usr/bin/install_name_tool -change "$LIBSSH2_CRYPTO_PATH" "@loader_path/libcrypto.3.dylib" "$FRAMEWORKS_DIR/libssh2.1.dylib"
/usr/bin/install_name_tool -id "@rpath/libssl.3.dylib" "$FRAMEWORKS_DIR/libssl.3.dylib"
/usr/bin/install_name_tool -change "$SSL_CRYPTO_PATH" "@loader_path/libcrypto.3.dylib" "$FRAMEWORKS_DIR/libssl.3.dylib"
/usr/bin/install_name_tool -id "@rpath/libcrypto.3.dylib" "$FRAMEWORKS_DIR/libcrypto.3.dylib"

/bin/cp "$ROOT_DIR/Support/Info.plist" "$CONTENTS_DIR/Info.plist"
/bin/cp "$ROOT_DIR/Support/VoltIcon.png" "$RESOURCES_DIR/VoltIcon.png"
/bin/cp "$ROOT_DIR/Support/THIRD_PARTY_NOTICES.txt" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.txt"
/bin/cp "$LIBSSH2_PREFIX/COPYING" "$LICENSES_DIR/libssh2-COPYING.txt"
/bin/cp "$OPENSSL_PREFIX/LICENSE.txt" "$LICENSES_DIR/OpenSSL-LICENSE.txt"

sign_code() {
  target="$1"
  if [ "$SIGN_IDENTITY" = "-" ]; then
    /usr/bin/codesign --force --sign - "$target"
  else
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --options=runtime --timestamp "$target"
  fi
}

sign_code "$FRAMEWORKS_DIR/libcrypto.3.dylib"
sign_code "$FRAMEWORKS_DIR/libssl.3.dylib"
sign_code "$FRAMEWORKS_DIR/libssh2.1.dylib"

LIBSSH2_VERSION="$($BREW list --versions libssh2 | /usr/bin/awk '{print $2; exit}')"
OPENSSL_VERSION="$($BREW list --versions openssl@3 | /usr/bin/awk '{print $2; exit}')"
LIBSSH2_SHA="$(/usr/bin/shasum -a 256 "$FRAMEWORKS_DIR/libssh2.1.dylib" | /usr/bin/awk '{print $1}')"
SSL_SHA="$(/usr/bin/shasum -a 256 "$FRAMEWORKS_DIR/libssl.3.dylib" | /usr/bin/awk '{print $1}')"
CRYPTO_SHA="$(/usr/bin/shasum -a 256 "$FRAMEWORKS_DIR/libcrypto.3.dylib" | /usr/bin/awk '{print $1}')"
MANIFEST_PATH="$RESOURCES_DIR/DependencyManifest.json"

/usr/bin/printf '%s\n' \
  '{' \
  '  "schemaVersion": 1,' \
  "  \"architecture\": \"$ARCH\"," \
  '  "hashStage": "after-install-name-tool-and-dylib-signing",' \
  '  "dependencies": [' \
  "    {\"name\": \"libssh2\", \"version\": \"$LIBSSH2_VERSION\", \"sha256\": \"$LIBSSH2_SHA\", \"buildProvider\": \"homebrew/core\", \"source\": \"https://github.com/Homebrew/homebrew-core/blob/HEAD/Formula/lib/libssh2.rb\"}," \
  "    {\"name\": \"libssl\", \"version\": \"$OPENSSL_VERSION\", \"sha256\": \"$SSL_SHA\", \"buildProvider\": \"homebrew/core\", \"source\": \"https://github.com/openssl/openssl\"}," \
  "    {\"name\": \"libcrypto\", \"version\": \"$OPENSSL_VERSION\", \"sha256\": \"$CRYPTO_SHA\", \"buildProvider\": \"homebrew/core\", \"source\": \"https://github.com/openssl/openssl\"}" \
  '  ]' \
  '}' > "$MANIFEST_PATH"

if [ "$SIGN_IDENTITY" = "-" ]; then
  /usr/bin/codesign --force --sign - --entitlements "$ROOT_DIR/Support/Volt.entitlements" "$APP_DIR"
else
  /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --options=runtime --timestamp --entitlements "$ROOT_DIR/Support/Volt.entitlements" "$APP_DIR"
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"

/bin/rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  if [ "$SIGN_IDENTITY" = "-" ]; then
    /usr/bin/printf 'NOTARY_PROFILE requires a Developer ID CODE_SIGN_IDENTITY.\n' >&2
    exit 1
  fi
  /usr/bin/xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$APP_DIR"
  /usr/bin/xcrun stapler validate "$APP_DIR"
  /usr/sbin/spctl --assess --type execute -vvv "$APP_DIR"
  /bin/rm -f "$ZIP_PATH"
  /usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
fi

if [ "${CREATE_DMG:-0}" = "1" ]; then
  /bin/rm -f "$DMG_PATH"
  /usr/bin/hdiutil create -volname Volt -srcfolder "$APP_DIR" -ov -format UDZO "$DMG_PATH"
  if [ "$SIGN_IDENTITY" != "-" ]; then
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
  fi
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    /usr/bin/xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    /usr/bin/xcrun stapler staple "$DMG_PATH"
    /usr/bin/xcrun stapler validate "$DMG_PATH"
  fi
  /usr/bin/printf '%s\n' "$DMG_PATH"
fi

/usr/bin/printf '%s\n%s\n' "$APP_DIR" "$ZIP_PATH"
