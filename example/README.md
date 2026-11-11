# Ti.Socketline example

A classic Titanium app that runs the module's self-test on launch, and a small Node.js
WebSocket server that misbehaves on request so the self-test can check every event and
close code on a real device or simulator.

```
server/server.js         the test server (Node.js 18+, no dependencies); routes and ports in its header
server/make-certs.sh     a test CA and three certificates for the TLS checks (git-ignored output)
app/                     the Titanium app (tiapp.xml, Resources/app.js, Resources/selftest.js)
build.sh                 builds the app against ../dist/*.zip
run-selftest-android.sh  runs it on a device or emulator and prints the results
run-selftest-ios.sh      runs it on an iOS simulator (macOS) and prints the results
```

## Run

```bash
server/make-certs.sh                  # once: certs, and the CA copied into the app (Android trust anchor)
../build.sh android && ./build.sh android
ADB_SERIAL=emulator-5554 ./run-selftest-android.sh
```

On macOS, for iOS (the simulator shares the Mac's network; the script adds the test CA to
that simulator's keychain):

```bash
server/make-certs.sh
../build.sh ios && ./build.sh ios
./run-selftest-ios.sh <simulator-udid>
```

Each script starts the server, installs and launches the app, waits for the summary, then
sends the app to the background and back for the background check. Results are printed and
saved to `selftest-android.json` / `selftest-ios.json`; the exit status is non-zero when a
check failed.

The test CA is trusted by the example app only: on Android through its network security
config (`app/platform/android/res/xml/network_security_config.xml`), on iOS by adding it to
the simulator. Nothing in the module trusts it. The same config allows cleartext `ws://` to
`127.0.0.1` only, so the check that `ws://example.com` is refused exercises the platform's
policy (network security config on Android; on iOS the module's own application of the
app's App Transport Security settings, since `NSURLSessionWebSocketTask` does not apply
them to `ws://`).

## What the self-test checks

Echo and `readyState`; close codes 1000, 1001, 4001, a close frame without a code (1005), a
dropped TCP connection, a refused connection; connect timeouts on a server that accepts TCP
and then says nothing (ws and wss); a slow upgrade within the timeout; `close()` while
connecting and before `connect()`; TLS with a trusted certificate (TLS 1.3 only), a
certificate for another host and a self-signed one; cleartext refused by policy;
subprotocols (selected, required but not offered, an unoffered selection, none selected);
an upgrade rejected with HTTP 401; custom headers; 2 MiB and 3 MB text frames; 2000 small
frames in order; ping/pong; binary frames; `close()` against a server that never answers
the close frame and one that answers with another code;
`close()` argument validation; invalid options; 6 s idle with a short `connectTimeout`; a
socket JavaScript no longer references; and, driven by the scripts, close on pause and a
new socket after resume.
