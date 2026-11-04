#!/bin/sh
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

if [ -x /opt/homebrew/bin/brew ]; then
  BREW=/opt/homebrew/bin/brew
elif [ -x /usr/local/bin/brew ]; then
  BREW=/usr/local/bin/brew
else
  /usr/bin/printf 'Homebrew was not found.\n' >&2
  exit 1
fi

ROOT_DIR="$(cd "$(/usr/bin/dirname "$0")/.." && pwd)"
LIBSSH2_PREFIX="$($BREW --prefix libssh2)"
. "$ROOT_DIR/Scripts/lib/openssl-env.sh"

set +e
OUTDATED="$($BREW outdated --formula libssh2 "$OPENSSL_FORMULA")"
OUTDATED_STATUS=$?
set -e
if [ -n "$OUTDATED" ]; then
  /usr/bin/printf 'Security dependencies need review/update:\n%s\n' "$OUTDATED" >&2
  exit 1
fi
if [ "$OUTDATED_STATUS" -ne 0 ]; then
  /usr/bin/printf 'Could not audit Homebrew dependency freshness.\n' >&2
  exit 1
fi

$BREW list --versions libssh2 "$OPENSSL_FORMULA"
/usr/bin/printf 'libssh2 links against %s (%s, %s)\n' "$OPENSSL_FORMULA" "$SSL_LIB_NAME" "$CRYPTO_LIB_NAME"
/usr/bin/printf 'Bundled SSH/crypto dependencies are current in Homebrew. Review upstream advisories before each release.\n'
