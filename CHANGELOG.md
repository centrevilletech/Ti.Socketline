# Changelog

## 1.0.0 — 2026-11-11

Initial release.

- `createSocket({ url, protocols, headers, connectTimeout })` with
  `connect()`, `send(text)`, `close([code], [reason])`, `readyState`, `protocol`
  and `url`
- `open` (`protocol`), `message` (`data`), `error` (`code`, `error`) and `close`
  (`code`, `reason`, `wasClean`) events, identical on iOS and Android: `close`
  exactly once and last; 1006 for anything that never opened; `wasClean` when the
  connection ended with a close frame (the server's, or the app's after `close()`);
  1005 for a server close frame without a code
- `connectTimeout` is a deadline for DNS, TCP, TLS and the upgrade on both
  platforms
- `ws://` follows the app's cleartext policy on both platforms: the network security
  config on Android, the App Transport Security settings on iOS (applied by the
  module, since `NSURLSessionWebSocketTask` does not)
- Subprotocols through `protocols`, checked against the server's answer
- `close()` validates its arguments (1000 or 3000-4999, a reason of at most 123
  UTF-8 bytes) and throws on invalid ones; `close()` while connecting stops the
  connection
- Binary frames are dropped with a `BINARY_FRAME` error, never delivered as text
- iOS: `NSURLSessionWebSocketTask` (iOS 15+), all state on the main queue
- Android: the platform's TLS (TLS 1.3, network security config, host name
  verification) and cleartext policy, with Java-WebSocket 1.5.3 (shared with
  Titanium itself) for the upgrade and framing
- 16 KB page-size aligned Android binaries; the zips include the LICENSE
- Unit tests for the state machine and validation on both platforms
  (`test/vectors.json`), and an example app whose self-test runs against a local
  test server
