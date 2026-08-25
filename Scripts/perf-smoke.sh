#!/bin/sh
set -eu

COUNT="${VOLT_PERF_FILE_COUNT:-10000}"
DEPTH="${VOLT_PERF_TREE_DEPTH:-32}"
WORKERS="${VOLT_PERF_WORKERS:-8}"
AUTO_CLEANUP="${VOLT_PERF_AUTO_CLEANUP:-0}"
ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/volt-perf.XXXXXX")"

cleanup() {
  /bin/rm -rf "$ROOT"
}
trap cleanup EXIT INT TERM

/bin/mkdir -p "$ROOT/large-folder"

fixture_start="$(/bin/date +%s)"
/usr/bin/jot "$COUNT" 0 | /usr/bin/xargs -P "$WORKERS" -n 250 /bin/sh -c '
  directory="$1"
  shift
  for index do
    printf "sample %s\n" "$index" > "$directory/file-$index.txt"
  done
' volt-perf-batch "$ROOT/large-folder"

current="$ROOT/deep-tree"
/bin/mkdir -p "$current"
i=0
while [ "$i" -lt "$DEPTH" ]; do
  current="$current/level-$i"
  /bin/mkdir -p "$current"
  /usr/bin/printf 'depth %s\n' "$i" > "$current/item-$i.txt"
  i=$((i + 1))
done

fixture_end="$(/bin/date +%s)"
start="$fixture_end"
found="$(/usr/bin/find "$ROOT/large-folder" -type f -name '*.txt' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
end="$(/bin/date +%s)"

/usr/bin/printf 'Created %s files and a %s-level tree under:\n%s\n' "$COUNT" "$DEPTH" "$ROOT"
/usr/bin/printf 'Fixture creation: %ss using %s workers\n' "$((fixture_end - fixture_start))" "$WORKERS"
/usr/bin/printf 'Filesystem smoke count: %s files in %ss\n' "$found" "$((end - start))"
/usr/bin/printf 'Open the large-folder path in Volt, then try search, sort, thumbnails, and cancellation flows before this script exits.\n'
if [ "$AUTO_CLEANUP" = "1" ]; then
  /usr/bin/printf 'Automatic cleanup enabled.\n'
else
  /usr/bin/printf 'Press Enter to clean up the fixture.\n'
  IFS= read -r _
fi
