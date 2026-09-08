#!/bin/sh
set -eu
ROOT_DIR="$(cd "$(/usr/bin/dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
DEVELOPER_DIR_PATH="$(/usr/bin/xcode-select -p)"
case "$DEVELOPER_DIR_PATH" in
  */CommandLineTools)
    # CLT ships Swift Testing without the Foundation overlay module or XCTest.
    FRAMEWORKS="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
    exec /usr/bin/swift test --disable-xctest --filter UploadTests \
      -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
      -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
      -Xlinker -F -Xlinker "$FRAMEWORKS" \
      -Xlinker -rpath -Xlinker "$FRAMEWORKS" "$@"
    ;;
  *) exec /usr/bin/swift test --filter UploadTests "$@" ;;
esac
