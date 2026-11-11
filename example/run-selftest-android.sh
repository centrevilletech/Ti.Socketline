#!/usr/bin/env bash
# Run the self-test on an Android device or emulator: starts the test server, forwards its ports to the
# device, installs and launches the example app, waits for the summary, then sends the app to the
# background and back for the background check. Prints the results and exits non-zero on a failure.
#
#   ADB_SERIAL=emulator-5554 ./run-selftest-android.sh [path/to/app-debug.apk]
#
# Build the app first (./build.sh android). Port BASE+5 is deliberately not forwarded (connection refused).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APK="${1:-$HERE/app/build/android/app/build/outputs/apk/debug/app-debug.apk}"
APP_ID=io.example.socketline
BASE=8765
adb_() { if [ -n "${ADB_SERIAL:-}" ]; then adb -s "$ADB_SERIAL" "$@"; else adb "$@"; fi; }

node "$HERE/server/server.js" --base "$BASE" > "$HERE/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true; for p in 0 1 2 3 4; do adb_ reverse --remove tcp:$((BASE + p)) 2>/dev/null || true; done' EXIT
until (exec 3<>/dev/tcp/127.0.0.1/$BASE) 2>/dev/null; do sleep 0.2; done
for p in 0 1 2 3 4; do adb_ reverse tcp:$((BASE + p)) tcp:$((BASE + p)) >/dev/null; done

adb_ uninstall "$APP_ID" >/dev/null 2>&1 || true
adb_ install -r "$APK" >/dev/null
adb_ logcat -c
ACTIVITY="$(adb_ shell cmd package resolve-activity --brief "$APP_ID" | tail -1 | tr -d '\r')"
adb_ shell am start -W -n "$ACTIVITY" >/dev/null

wait_for() { # pattern, seconds
	for _ in $(seq 1 "$2"); do
		adb_ logcat -d -s TiAPI:I | grep -q "$1" && return 0
		sleep 1
	done
	echo "timed out waiting for: $1" >&2
	return 1
}
wait_for '\[selftest\] SUMMARY' 600
adb_ shell input keyevent KEYCODE_HOME
sleep 3
adb_ shell am start -W -n "$ACTIVITY" >/dev/null
wait_for '\[selftest\] BACKGROUND DONE' 60 || true

adb_ logcat -d -s TiAPI:I | grep '\[selftest\]' | sed 's/^.*\[selftest\] //'
adb_ shell run-as "$APP_ID" cat app_appdata/selftest.json > "$HERE/selftest-android.json" 2>/dev/null || true
grep -q '"failed": 0' "$HERE/selftest-android.json"
