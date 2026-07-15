#!/bin/sh
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

ROOT_DIR="$(cd "$(/usr/bin/dirname "$0")/.." && pwd)"

if [ -d "$ROOT_DIR/.git" ] && [ -x /usr/bin/git ]; then
  if [ -n "$(/usr/bin/git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]; then
    if [ "${ALLOW_DIRTY:-0}" != "1" ]; then
      /usr/bin/printf 'Working tree is dirty. Commit/stash changes or rerun with ALLOW_DIRTY=1 for a local test build.\n' >&2
      exit 1
    fi
    /usr/bin/printf 'Warning: building from a dirty working tree because ALLOW_DIRTY=1.\n' >&2
  fi
fi

"$ROOT_DIR/Scripts/test-security.sh"
"$ROOT_DIR/Scripts/audit-dependencies.sh"
"$ROOT_DIR/Scripts/package-app.sh"
"$ROOT_DIR/Scripts/verify-build.sh" "$ROOT_DIR/build/Volt.app"

if [ -z "${NOTARY_PROFILE:-}" ]; then
  /usr/bin/printf 'Warning: this build is not notarized. Treat it as a self-use-only build for this Mac.\n' >&2
fi

/usr/bin/printf 'Self-build verification complete. Verify each server host-key fingerprint out of band before trusting it.\n'
