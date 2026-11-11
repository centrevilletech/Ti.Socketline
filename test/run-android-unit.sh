#!/usr/bin/env bash
# The state machine and argument validation (android/src/ti/socketline/SocketCore.java) against test/vectors.json,
# on a plain JVM.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/build/android"
rm -rf "$OUT" && mkdir -p "$OUT"
javac -d "$OUT" "$HERE/../android/src/ti/socketline/SocketCore.java" "$HERE/android/VectorsTest.java"
java -cp "$OUT" ti.socketline.VectorsTest "$HERE/vectors.json"
