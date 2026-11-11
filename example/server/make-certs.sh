#!/usr/bin/env bash
# Creates the self-test's certificates in ./certs (git-ignored):
#   ca.crt / ca.key                 a test CA, trusted only by the example app (Android: res/raw, see
#                                   ../app/platform/android; iOS simulator: xcrun simctl keychain <id> add-root-cert)
#   good.crt / good.key             from the test CA, for 127.0.0.1 and localhost
#   wrong-host.crt / wrong-host.key from the test CA, for wrong.example only
#   self-signed.crt / .key          self-signed, for 127.0.0.1
# and copies the CA certificate into the example app (Android trust anchor, git-ignored).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/certs"
mkdir -p "$OUT"
cd "$OUT"

openssl req -x509 -newkey rsa:2048 -nodes -days 30 -keyout ca.key -out ca.crt \
	-subj "/CN=Ti.Socketline Test CA" -addext "basicConstraints=critical,CA:TRUE" \
	-addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

leaf() { # name, subjectAltName
	openssl req -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" -subj "/CN=$1" 2>/dev/null
	printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' "$2" > "$1.ext"
	openssl x509 -req -in "$1.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -out "$1.crt" -extfile "$1.ext" 2>/dev/null
	rm -f "$1.csr" "$1.ext"
}
leaf good "IP:127.0.0.1,DNS:localhost"
leaf wrong-host "DNS:wrong.example"

openssl req -x509 -newkey rsa:2048 -nodes -days 30 -keyout self-signed.key -out self-signed.crt \
	-subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" 2>/dev/null

RAW="$HERE/../app/platform/android/res/raw"
mkdir -p "$RAW"
cp ca.crt "$RAW/socketline_test_ca.pem"
openssl verify -CAfile ca.crt good.crt wrong-host.crt
ls "$OUT"
