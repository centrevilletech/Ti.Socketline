#!/usr/bin/env bash
# Run the self-test on an iOS simulator (macOS): trusts the test CA in that simulator, starts the test
# server, installs and launches the example app, waits for the summary, then sends the app to the
# background (opens Settings) and back for the background check.
#
#   ./run-selftest-ios.sh <simulator-udid> [path/to/Socketline.app]
#
# Build the app first (./build.sh ios). The simulator shares the Mac's network, so 127.0.0.1 is the server.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM="${1:?simulator udid}"
APP="${2:-$HERE/app/build/iphone/build/Products/Debug-iphonesimulator/Socketline.app}"
APP_ID=io.example.socketline
BASE=8765

xcrun simctl keychain "$SIM" add-root-cert "$HERE/server/certs/ca.crt"
node "$HERE/server/server.js" --base "$BASE" > "$HERE/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
until nc -z 127.0.0.1 "$BASE" 2>/dev/null; do sleep 0.2; done

xcrun simctl uninstall "$SIM" "$APP_ID" >/dev/null 2>&1 || true
xcrun simctl install "$SIM" "$APP"
xcrun simctl launch "$SIM" "$APP_ID" >/dev/null
DATA="$(xcrun simctl get_app_container "$SIM" "$APP_ID" data)"
RESULT="$DATA/Documents/selftest.json"

wait_for() { # grep pattern in selftest.json, seconds
	for _ in $(seq 1 "$2"); do
		[ -f "$RESULT" ] && grep -q "$1" "$RESULT" && return 0
		sleep 1
	done
	echo "timed out waiting for: $1" >&2
	return 1
}
wait_for '"passed"' 600
xcrun simctl launch "$SIM" com.apple.Preferences >/dev/null
sleep 3
xcrun simctl launch "$SIM" "$APP_ID" >/dev/null
wait_for '"background": true' 60 || true

cp "$RESULT" "$HERE/selftest-ios.json"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for r in d["results"]:
    print(r["status"], r["name"] + (": " + r["detail"] if r["detail"] else ""))
print("SUMMARY passed=%d failed=%d skipped=%d" % (d["passed"], d["failed"], d["skipped"]))
sys.exit(1 if d["failed"] else 0)' "$HERE/selftest-ios.json"
