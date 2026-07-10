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

OUTDATED="$($BREW outdated --formula libssh2 openssl@3)"
if [ -n "$OUTDATED" ]; then
  /usr/bin/printf 'Security dependencies need review/update:\n%s\n' "$OUTDATED" >&2
  exit 1
fi

$BREW list --versions libssh2 openssl@3
/usr/bin/printf 'Bundled SSH/crypto dependencies are current in Homebrew. Review upstream advisories before each release.\n'
