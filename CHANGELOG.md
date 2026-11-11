# Changelog

## 1.0.0 — 2026-11-11

Initial release.

- `createSocket({ url, headers, connectTimeout })` with `connect()`,
  `send(text)`, `close(code, reason)` and `readyState`
- `open`, `message`, `error` and `close` events, `close` exactly once
- iOS: `NSURLSessionWebSocketTask` (iOS 15+ deployment target)
- Android: Java-WebSocket 1.5.3, shared with Titanium itself
- `ws://` and `wss://` with the platform's TLS on both platforms
- 16 KB page-size aligned Android binaries
