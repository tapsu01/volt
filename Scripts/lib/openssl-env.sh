#!/bin/sh
# Shared helper: derive the OpenSSL formula and dylib names that the Homebrew
# libssh2 build actually links against. Sourced with `.`; requires BREW and
# LIBSSH2_PREFIX to be set by the caller. Exports:
#   LIBSSH2_SSL_LINK, LIBSSH2_CRYPTO_LINK  - load-command paths inside libssh2
#   SSL_LIB_NAME, CRYPTO_LIB_NAME          - e.g. libssl.4.dylib / libcrypto.4.dylib
#   OPENSSL_FORMULA                        - e.g. openssl@4
#   OPENSSL_PREFIX                         - brew --prefix of that formula

openssl_env_fail() {
  /usr/bin/printf 'openssl-env failed: %s\n' "$1" >&2
  exit 1
}

[ -n "${BREW:-}" ] || openssl_env_fail 'BREW is not set'
[ -n "${LIBSSH2_PREFIX:-}" ] || openssl_env_fail 'LIBSSH2_PREFIX is not set'

LIBSSH2_DYLIB="$LIBSSH2_PREFIX/lib/libssh2.1.dylib"
[ -f "$LIBSSH2_DYLIB" ] || openssl_env_fail "libssh2 dylib not found at $LIBSSH2_DYLIB"

LIBSSH2_SSL_LINK="$(/usr/bin/otool -L "$LIBSSH2_DYLIB" | /usr/bin/awk '/\/libssl\.[0-9]+\.dylib/{print $1; exit}')"
LIBSSH2_CRYPTO_LINK="$(/usr/bin/otool -L "$LIBSSH2_DYLIB" | /usr/bin/awk '/\/libcrypto\.[0-9]+\.dylib/{print $1; exit}')"
[ -n "$LIBSSH2_SSL_LINK" ] || openssl_env_fail "could not find a libssl load command in $LIBSSH2_DYLIB"
[ -n "$LIBSSH2_CRYPTO_LINK" ] || openssl_env_fail "could not find a libcrypto load command in $LIBSSH2_DYLIB"

SSL_LIB_NAME="$(/usr/bin/basename "$LIBSSH2_SSL_LINK")"
CRYPTO_LIB_NAME="$(/usr/bin/basename "$LIBSSH2_CRYPTO_LINK")"

OPENSSL_FORMULA="$(/usr/bin/printf '%s\n' "$LIBSSH2_SSL_LINK" | /usr/bin/sed -n 's|.*/\(openssl@[0-9][0-9]*\)/.*|\1|p')"
[ -n "$OPENSSL_FORMULA" ] || openssl_env_fail "could not derive an openssl@N formula from $LIBSSH2_SSL_LINK"

OPENSSL_PREFIX="$($BREW --prefix "$OPENSSL_FORMULA")"
[ -f "$OPENSSL_PREFIX/lib/$SSL_LIB_NAME" ] && [ -f "$OPENSSL_PREFIX/lib/$CRYPTO_LIB_NAME" ] \
  || openssl_env_fail "libssh2 links against $LIBSSH2_SSL_LINK but formula $OPENSSL_FORMULA is not installed; run: brew install $OPENSSL_FORMULA"

export LIBSSH2_SSL_LINK LIBSSH2_CRYPTO_LINK SSL_LIB_NAME CRYPTO_LIB_NAME OPENSSL_FORMULA OPENSSL_PREFIX
