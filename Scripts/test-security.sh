#!/bin/sh
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

ROOT_DIR="$(cd "$(/usr/bin/dirname "$0")/.." && pwd)"
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
OUTPUT="${TMPDIR:-/tmp}/volt-host-key-store-test"
SANITIZER_FLAGS="${VOLT_TEST_SANITIZER_FLAGS:--fsanitize=address,undefined -fno-omit-frame-pointer}"
ASAN_OPTIONS_VALUE="${ASAN_OPTIONS:-detect_leaks=0:halt_on_error=1}"
UBSAN_OPTIONS_VALUE="${UBSAN_OPTIONS:-halt_on_error=1:print_stacktrace=1}"

/usr/bin/clang \
  $SANITIZER_FLAGS \
  -I"$LIBSSH2_PREFIX/include" \
  -I"$ROOT_DIR/Sources/CVoltSSH/include" \
  "$ROOT_DIR/Tests/host_key_store_test.c" \
  "$ROOT_DIR/Sources/CVoltSSH/VoltSSH.c" \
  -L"$LIBSSH2_PREFIX/lib" \
  -lssh2 \
  -o "$OUTPUT"

ASAN_OPTIONS="$ASAN_OPTIONS_VALUE" UBSAN_OPTIONS="$UBSAN_OPTIONS_VALUE" DYLD_LIBRARY_PATH="$LIBSSH2_PREFIX/lib:$OPENSSL_PREFIX/lib" "$OUTPUT"
/bin/rm -f "$OUTPUT"

NAME_OUTPUT="${TMPDIR:-/tmp}/volt-entry-name-validation-test"

/usr/bin/clang \
  $SANITIZER_FLAGS \
  -I"$LIBSSH2_PREFIX/include" \
  -I"$ROOT_DIR/Sources/CVoltSSH/include" \
  "$ROOT_DIR/Tests/entry_name_validation_test.c" \
  "$ROOT_DIR/Sources/CVoltSSH/VoltSSH.c" \
  -L"$LIBSSH2_PREFIX/lib" \
  -lssh2 \
  -o "$NAME_OUTPUT"

ASAN_OPTIONS="$ASAN_OPTIONS_VALUE" UBSAN_OPTIONS="$UBSAN_OPTIONS_VALUE" DYLD_LIBRARY_PATH="$LIBSSH2_PREFIX/lib:$OPENSSL_PREFIX/lib" "$NAME_OUTPUT"
/bin/rm -f "$NAME_OUTPUT"

UPLOAD_OUTPUT="${TMPDIR:-/tmp}/volt-upload-publish-test"
/usr/bin/clang \
  $SANITIZER_FLAGS \
  -I"$LIBSSH2_PREFIX/include" \
  -I"$ROOT_DIR/Sources/CVoltSSH/include" \
  "$ROOT_DIR/Tests/upload_publish_test.c" \
  -L"$LIBSSH2_PREFIX/lib" -lssh2 -o "$UPLOAD_OUTPUT"
ASAN_OPTIONS="$ASAN_OPTIONS_VALUE" UBSAN_OPTIONS="$UBSAN_OPTIONS_VALUE" DYLD_LIBRARY_PATH="$LIBSSH2_PREFIX/lib:$OPENSSL_PREFIX/lib" "$UPLOAD_OUTPUT"
/bin/rm -f "$UPLOAD_OUTPUT"

ERROR_OUTPUT="${TMPDIR:-/tmp}/volt-sftp-error-test"
/usr/bin/clang $SANITIZER_FLAGS -I"$LIBSSH2_PREFIX/include" \
  "$ROOT_DIR/Tests/sftp_error_test.c" -o "$ERROR_OUTPUT"
ASAN_OPTIONS="$ASAN_OPTIONS_VALUE" UBSAN_OPTIONS="$UBSAN_OPTIONS_VALUE" "$ERROR_OUTPUT"
/bin/rm -f "$ERROR_OUTPUT"
