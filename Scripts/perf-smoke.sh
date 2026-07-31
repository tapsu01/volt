#!/bin/sh
set -eu

COUNT="${VOLT_PERF_FILE_COUNT:-10000}"
DEPTH="${VOLT_PERF_TREE_DEPTH:-32}"
ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/volt-perf.XXXXXX")"

cleanup() {
  /bin/rm -rf "$ROOT"
}
trap cleanup EXIT INT TERM

/bin/mkdir -p "$ROOT/large-folder"

i=0
while [ "$i" -lt "$COUNT" ]; do
  /usr/bin/printf 'sample %s\n' "$i" > "$ROOT/large-folder/file-$i.txt"
  i=$((i + 1))
done

current="$ROOT/deep-tree"
/bin/mkdir -p "$current"
i=0
while [ "$i" -lt "$DEPTH" ]; do
  current="$current/level-$i"
  /bin/mkdir -p "$current"
  /usr/bin/printf 'depth %s\n' "$i" > "$current/item-$i.txt"
  i=$((i + 1))
done

start="$(/bin/date +%s)"
found="$(/usr/bin/find "$ROOT/large-folder" -type f -name '*.txt' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
end="$(/bin/date +%s)"

/usr/bin/printf 'Created %s files and a %s-level tree under:\n%s\n' "$COUNT" "$DEPTH" "$ROOT"
/usr/bin/printf 'Filesystem smoke count: %s files in %ss\n' "$found" "$((end - start))"
/usr/bin/printf 'Open the large-folder path in Volt, then try search, sort, thumbnails, and cancellation flows before this script exits.\n'
/usr/bin/printf 'Press Enter to clean up the fixture.\n'
IFS= read -r _
