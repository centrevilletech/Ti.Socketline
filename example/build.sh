#!/usr/bin/env bash
# Build the example app against the module zips in ../dist (run ../build.sh and server/make-certs.sh first).
#
#   ./build.sh android     # -> app/build/android/app/build/outputs/apk/debug/app-debug.apk
#   ./build.sh ios         # simulator build (macOS) -> app/build/iphone/build/Products/Debug-iphonesimulator/Socketline.app
#
# A different zip: ZIP=/path/to/ti.socketline-android-1.0.0.zip ./build.sh android
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM="${1:?android or ios}"
ZIP_PLATFORM="$PLATFORM"; [ "$PLATFORM" = ios ] && ZIP_PLATFORM=iphone
ZIP="${ZIP:-$(ls "$HERE"/../dist/ti.socketline-"$ZIP_PLATFORM"-*.zip | tail -1)}"
[ -f "$HERE/app/platform/android/res/raw/socketline_test_ca.pem" ] || { echo "run server/make-certs.sh first" >&2; exit 1; }
rm -rf "$HERE/app/modules/$ZIP_PLATFORM"
unzip -q -o "$ZIP" -d "$HERE/app"
cd "$HERE/app"
if [ "$PLATFORM" = android ]; then
	ti build -p android -T emulator --build-only --no-prompt
	(cd build/android && ./gradlew --stop >/dev/null 2>&1) || true   # only the daemon this build started
else
	ti build -p ios -T simulator --build-only --no-prompt
fi
