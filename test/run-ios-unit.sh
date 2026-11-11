#!/usr/bin/env bash
# The state machine and argument validation (ios/Classes/TiSocketlineCore.m) against test/vectors.json.
# macOS with Xcode (clang); the core uses Foundation only.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/build/ios"
rm -rf "$OUT" && mkdir -p "$OUT"
clang -fobjc-arc -Wall -Werror -framework Foundation -I "$HERE/../ios/Classes" -o "$OUT/vectors" \
	"$HERE/../ios/Classes/TiSocketlineCore.m" "$HERE/ios/main.m"
"$OUT/vectors" "$HERE/vectors.json"
