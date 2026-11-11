# Ti.Socketline

A native WebSocket client for Titanium, on iOS and Android: `ws://` and `wss://`
with the platform's own TLS, text frames, open/message/error/close events, and the
same events and close codes on both platforms.

## Why this exists

Titanium has no WebSocket API, and no maintained module fills the gap:

- **Pure-JavaScript clients** built on `Ti.Network.Socket.TCP` cannot do
  `wss://` on iOS. The TCP socket's `secure` option exists on Android only
  (since SDK 12.1), so on an iPhone you are limited to unencrypted `ws://`,
  which nothing in production should use.
- **Socket.IO modules** speak Socket.IO's own protocol on top of WebSockets.
  They cannot talk to a plain WebSocket server such as a Pusher-protocol
  server (Laravel Reverb, Soketi, Pusher itself), Phoenix channels or your
  own RFC 6455 endpoint.
- The older native WebSocket modules stopped years ago and do not build for
  current Titanium, Xcode or Android.

This module wraps what each platform already ships and maintains:

- **iOS:** `NSURLSessionWebSocketTask`, with the system's TLS, proxy,
  certificate and App Transport Security handling.
- **Android:** the platform's TLS (`SSLSocketFactory.getDefault()`: TLS 1.3, the
  app's network security config, host name verification) for the connection, and
  [Java-WebSocket](https://github.com/TooTallNate/Java-WebSocket) 1.5.3 for the
  upgrade and framing: the library Titanium itself already depends on, so nothing
  is packaged twice and there is no duplicate-class build failure.

The API is deliberately small and shaped like the browser's `WebSocket`, so a
protocol client written against it (a Pusher client, for example) stays
testable in plain JavaScript.

## Install

Download the zips for your platforms from
[Releases](https://github.com/centrevilletech/Ti.Socketline/releases) and
unzip them into your project root (each zip contains a `modules/` directory,
so it lands in the right place):

```bash
unzip ti.socketline-android-1.0.0.zip -d /path/to/your/app
unzip ti.socketline-iphone-1.0.0.zip -d /path/to/your/app
```

Then add it to `tiapp.xml`:

```xml
<modules>
    <module>ti.socketline</module>
</modules>
```

Requires Titanium SDK 13.0.0.GA or later, iOS 15 or later, Android 7.0 (API 24,
Titanium 13's minimum) or later.

## Usage

```javascript
const Socketline = require('ti.socketline');

const socket = Socketline.createSocket({
    url: 'wss://realtime.example.com/socket',
    protocols: ['chat.v2'],                    // optional: subprotocols to offer
    headers: { Authorization: 'Bearer …' },     // optional: extra upgrade request headers
    connectTimeout: 15000                       // optional, ms (default 15000)
});

socket.addEventListener('open', (e) => {
    Ti.API.info('open, subprotocol: ' + e.protocol);
    socket.send(JSON.stringify({ hello: 'world' }));
});

socket.addEventListener('message', (e) => {
    Ti.API.info('received ' + e.data);
});

socket.addEventListener('error', (e) => {
    Ti.API.warn('socket error ' + e.code + ': ' + e.error);
});

socket.addEventListener('close', (e) => {
    Ti.API.info('closed ' + e.code + ' ' + e.reason + ' clean=' + e.wasClean);
});

socket.connect();

// later
socket.close(1000, 'bye');
```

### One socket, one connection

Like a browser `WebSocket`, a socket object is single use: `connect()` once,
`close()` once. To reconnect, create a new socket. That keeps reconnect policy
(back-off, re-subscribing, refetching what was missed) in your JavaScript, where
it can be tested. A second `connect()` is ignored.

### The connect timeout is the module's

`connectTimeout` is a deadline for the whole connect: DNS, TCP, TLS and the HTTP
upgrade. If `open` has not fired by then, the socket fires `error`
(`CONNECT_TIMEOUT`) and `close` (1006), also behind a captive portal or a
middlebox that accepts the connection and then says nothing. Your reconnect logic
needs no connect timer of its own.

### Closing does not wait

`close(code, reason)` sends the close frame and closes the connection; `close`
follows at once with your code and reason. Neither platform's WebSocket stack waits
for the server's answering close frame (`NSURLSessionWebSocketTask` completes the
task as soon as it has sent the frame, and Java-WebSocket's client stops reading),
so the module does not pretend to: the server's answer is not reported.

### Keep-alive is yours

The module sends no pings of its own on either platform (it answers the server's
pings), and an open connection never times out for being idle. Most protocols
define an application-level ping (Pusher's `pusher:ping`, Phoenix's heartbeat);
send it, and treat a missing answer as a dead connection: `close()` and connect a
new socket.

### Background

iOS suspends sockets when the app goes to the background, and Android may kill
them. Close the socket on `pause` and open a new one on `resume`; push
notifications cover the time in between. If the app is suspended before the
closing handshake finished, the old socket's `close` event is delivered when the
app runs again (exactly once, as always).

## The contract

The same on iOS and Android; checked by the unit tests (`test/vectors.json`) and the
example's self-test on both platforms (see [What was verified](#what-was-verified)).

### Events

| Event | Properties | When |
| --- | --- | --- |
| `open` | `protocol`: the subprotocol the server selected, `""` for none | The upgrade succeeded. |
| `message` | `data`: the text | A text message arrived (also while closing). |
| `error` | `code`: one of the error codes below; `error`: a description | Something failed that the app did not ask for (never for `close()`). |
| `close` | `code`, `reason`, `wasClean` | Exactly once per socket, always last. |

Events are delivered on the JavaScript thread, in order, and always after the call
that caused them returned (an invalid URL does not fire anything inside `connect()`).

### Close codes

`wasClean` is true when the connection ended with a close frame: the server's (it
closed first; `code` and `reason` are its), or yours (you called `close()` on the open
socket; `code` and `reason` are yours). It is false when the connection ended without
one.

| Situation | `code` | `reason` | `wasClean` | `error` before it |
| --- | --- | --- | --- | --- |
| The server closes with a code (1000, 1001, 4001, …) | that code | the server's | `true` | – |
| The server's close frame has no code | 1005 | `""` | `true` | – |
| You `close(code, reason)` on the open socket | your code | your reason | `true` | – |
| You `close()` while connecting, or before `connect()` | 1006 | `""` | `false` | – |
| The connection drops while open (no close frame) | 1006 | `""` | `false` | `CONNECTION_LOST` |
| Connecting fails: refused, DNS, TLS, timeout, rejected upgrade, invalid options, cleartext refused | 1006 | `""` | `false` | the matching code |
| The server's close frame carries a code that is not valid on the wire | 1006 | `""` | `false` | – |

The module never reports -1, and never reports a code it made up for a closing
handshake that did not happen.

### Error codes

| `code` | Meaning |
| --- | --- |
| `INVALID_OPTIONS` | `url`, `headers`, `protocols` or `connectTimeout` is not valid (the description says which). |
| `CLEARTEXT_NOT_PERMITTED` | `ws://` to a host the app's policy forbids cleartext for: its network security config on Android, its App Transport Security settings on iOS (see Security). Use `wss://`. |
| `CONNECT_FAILED` | DNS failure, connection refused, network unreachable. |
| `TLS_FAILED` | The TLS handshake failed: untrusted certificate, wrong host name, expired, protocol mismatch. |
| `CONNECT_TIMEOUT` | No `open` within `connectTimeout`. |
| `HANDSHAKE_FAILED` | The server refused the WebSocket upgrade (any non-101 answer, a required subprotocol not offered) or selected a subprotocol that was not offered. |
| `CONNECTION_LOST` | The connection dropped while open, without a closing handshake. |
| `BINARY_FRAME` | A binary message arrived. It is dropped (never delivered as text); the connection stays open. |

### Security

- Certificate validation is the platform's and is never relaxed; there is no option
  to turn it off. On Android the host name is checked twice (endpoint identification
  and the default `HostnameVerifier`), and TLS 1.3 is negotiated where the device
  supports it.
- The app's own cleartext policy applies to `ws://`. On Android `ws://` is refused
  when the network security config does not permit cleartext for that host (the
  default for apps targeting API 28+), and custom trust anchors or pins in that config
  apply to `wss://`. On iOS, `NSURLSessionWebSocketTask` does not apply App Transport
  Security to `ws://` (observed on iOS 27), so the module applies the app's ATS
  cleartext rules itself: a matching `NSExceptionDomains` entry decides
  (`NSExceptionAllowsInsecureHTTPLoads`, `NSIncludesSubdomains`, most specific domain
  first); otherwise `NSAllowsLocalNetworking` permits `localhost`, `.local`,
  unqualified names and IP literals; otherwise `NSAllowsArbitraryLoads` permits
  everything (ignored, as in ATS, when `NSAllowsLocalNetworking`,
  `NSAllowsArbitraryLoadsInWebContent` or `NSAllowsArbitraryLoadsForMedia` is set).
  Without any of these, `ws://` is refused on iOS, IP addresses included.

## API

### Module

| Member | Description |
| --- | --- |
| `createSocket(options)` | A new, unconnected socket. Options below; they are checked at `connect()`. |
| `CONNECTING`, `OPEN`, `CLOSING`, `CLOSED` | `readyState` values 0 to 3. |

### Options

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `url` | String | required | `ws://` or `wss://`, with a host, without a fragment. |
| `protocols` | String or Array of Strings | none | Subprotocols to offer (`Sec-WebSocket-Protocol`). Each must be an HTTP token, no duplicates. |
| `headers` | Object | none | Extra request headers (string, number or boolean values). `Sec-WebSocket-*` headers are the module's: use `protocols`. |
| `connectTimeout` | Number (ms) | 15000 | Deadline for DNS, TCP, TLS and the upgrade. |

### Socket

| Member | Returns | Notes |
| --- | --- | --- |
| `connect()` | | Opens the connection. Fires `open`, or `error` then `close`. Only the first call does anything. |
| `send(text)` | `Boolean` | Sends a text frame. `false` when the socket is not open (also while closing). |
| `close([code], [reason])` | | `code`: 1000 (default) or an integer from 3000 to 4999. `reason`: a string of at most 123 bytes in UTF-8. Invalid arguments **throw** (see below) and change nothing. On an open socket: sends the close frame and closes (`close` with your code follows at once). While connecting: stops the connection (`close` 1006 follows at once). |
| `readyState` | `Number` | `CONNECTING` (also before `connect()`), `OPEN`, `CLOSING`, `CLOSED`. |
| `protocol` | `String` | The selected subprotocol, `""` before `open` or when none was selected. |
| `url` | `String` | The URL it was created with. |

`close()` throws an exception whose message is one of:
`Ti.Socketline: close code must be a number`,
`Ti.Socketline: close code must be 1000 or an integer from 3000 to 4999`,
`Ti.Socketline: close reason must be a string`,
`Ti.Socketline: close reason must be at most 123 bytes in UTF-8`.

### Limits

- Text frames only. Binary messages are dropped with a `BINARY_FRAME` error.
- Message size: iOS accepts messages up to 16 MiB (larger ones fail the connection);
  Android sets no limit beyond memory. Messages of 3 MB were tested on both.
- Compression: Android offers no extensions; iOS offers `permessage-deflate`
  (NSURLSession does) and uses it if the server accepts it (not tested).
- Proxies: iOS uses the system's proxy settings; Android connects directly.

## Updating a client written against earlier builds

If your real-time client was written against the unreleased first builds of this
module, check:

- Close codes: connect failures and `close()` during connect are now 1006 on both
  platforms (Android used to report -1; iOS reported 1000 and clean for `close()`
  during connect), and `wasClean` means "ended with a close frame" (a server close with
  4001 used to be reported as unclean). Decide what to do from `code` and `wasClean`
  together, and from the `error` event's `code`.
- Your own connect timer can go: `connectTimeout` now covers the whole connect on both
  platforms and always ends in `close`. Keep your application-level ping.
- `error` now has a `code`; binary frames produce `BINARY_FRAME` instead of text.
- `close()` throws on invalid arguments; it used to accept anything.
- Use `protocols` instead of a `Sec-WebSocket-Protocol` header (the header is now
  rejected with `INVALID_OPTIONS`).
- `ws://` now follows the app's cleartext policy on both platforms: use `wss://`, or
  allow the host for development (network security config on Android; an ATS
  exception or `NSAllowsLocalNetworking` on iOS).
- A dropped connection gives an `error` (`CONNECTION_LOST`) before `close`, and a failed
  connect gives `error` then `close`; `close` always comes last and exactly once, so
  drive reconnects from `close`, not from `error`.

## Testing

```bash
test/run-android-unit.sh     # the state machine and validation (SocketCore.java) on a plain JVM
test/run-ios-unit.sh         # the same vectors against TiSocketlineCore (macOS, clang)
```

Both run `test/vectors.json`: close-argument and option validation, close-code
normalisation, and event sequences for every situation in the tables above. The
example app's self-test runs the real module against a local test server on a
device or simulator: see [example/README.md](example/README.md).

## What was verified

What was run for 1.0.0, on 2026-11-11, with Titanium SDK 13.4.1.GA, the unit tests
and the example's self-test against its local test server.

| Check | Android | iOS |
| --- | --- | --- |
| Environment | Android 15 (API 35) x86_64 container image, no Google Play services | iOS 27.0 simulator (iPhone 18 Pro), Xcode 27.1, macOS 26.6 |
| Module builds; ABIs / slices | arm64-v8a, armeabi-v7a, x86, x86_64; 64-bit `.so` 16 KB aligned; LICENSE in the zip | arm64 device, arm64 + x86_64 simulator, no Mac Catalyst; LICENSE in the zip |
| State machine and validation (`test/vectors.json`) | ✅ 95 checks, JVM | ✅ 115 checks (the same plus 20 ATS cleartext rules), clang |
| Echo, `readyState` through every state, `send()` refused before open and after close, `url`, `protocol` | ✅ | ✅ |
| Server closes 1000, 1001, 4001 (clean, its code and reason) | ✅ | ✅ |
| Server close frame without a code → 1005, clean | ✅ | ✅ |
| `close(4000, reason)` → 4000, clean; also against a server that never answers (at once, < 1 s) and one that answers with another code | ✅ | ✅ |
| Server drops TCP → `CONNECTION_LOST`, 1006 | ✅ | ✅ |
| Connection refused → `CONNECT_FAILED`, 1006 | ✅ | ✅ |
| Server accepts TCP and says nothing, `ws://` and `wss://`, `connectTimeout` 1.5 s → `CONNECT_TIMEOUT`, 1006 after about 1.5 s | ✅ | ✅ |
| Slow upgrade (1.5 s) within `connectTimeout` opens | ✅ | ✅ |
| `close()` while connecting → 1006 at once, no `error`, never opens; `close()` before `connect()` → 1006 | ✅ | ✅ |
| TLS: certificate from a CA the app trusts, server TLS 1.3 only → opens, TLS 1.3 | ✅ (CA trusted through the example's network security config) | ✅ (CA added to the simulator) |
| TLS: certificate from that CA for another host name → `TLS_FAILED` | ✅ | ✅ |
| TLS: self-signed certificate → `TLS_FAILED` | ✅ | ✅ |
| `ws://example.com` with cleartext allowed for 127.0.0.1 only → `CLEARTEXT_NOT_PERMITTED` | ✅ network security config | ✅ the module's ATS rule (`NSAllowsLocalNetworking`) |
| Subprotocols: selected (`open.protocol`), required but not offered → `HANDSHAKE_FAILED`, unoffered selection → `HANDSHAKE_FAILED`, none selected → `""` | ✅ | ✅ |
| Upgrade rejected with HTTP 401 → `HANDSHAKE_FAILED` | ✅ | ✅ |
| Custom headers and the `Sec-WebSocket-Protocol` offer reach the server | ✅ | ✅ |
| 2 MiB text frame each way, 3,000,000-byte frame from the server | ✅ | ✅ |
| 2000 small frames, all in order | ✅ | ✅ |
| Server ping answered with a pong | ✅ | ✅ |
| Binary frame → `BINARY_FRAME`, nothing delivered, connection stays open | ✅ | ✅ |
| `close()` argument validation: 8 invalid calls throw the documented messages, the socket stays open | ✅ | ✅ |
| Invalid options → `INVALID_OPTIONS`, 1006, nothing delivered inside `connect()` | ✅ | ✅ |
| 6 s idle with `connectTimeout` 1.5 s: still open, still echoes | ✅ | ✅ |
| A socket JavaScript no longer references keeps working until `close` | ✅ | ✅ |
| Background: closed on `pause` (Home), new socket after `resume`, old `close` exactly once | ✅ | ✅ (Settings opened, app relaunched) |
| The same self-test against the module before these fixes (commit `5f97334`) | 9 passed, 24 failed | 9 passed, 24 failed |
| Physical devices | **not tested** | **not tested** |
| A real captive portal or half-open middlebox | **not tested** (simulated by the silent port) | **not tested** (same) |
| `release()` while connecting | unit-tested only (JavaScript cannot trigger a proxy's release) | n/a (the socket keeps itself alive until `close`) |
| HTTP proxies | – (connects directly) | **not tested** |
| A server that accepts `permessage-deflate` | – (not offered) | **not tested** (offered by NSURLSession) |
| Network change or loss while open (Wi-Fi to cellular, airplane mode) | **not tested** | **not tested** |
| Text frames over 3 MB; over iOS's 16 MiB limit; invalid UTF-8 in a text frame | **not tested** | **not tested** |
| ProGuard / R8 minified release build | **not tested** | – |
| Other Titanium SDKs, other OS versions | **not tested** | **not tested** |

## Building from source

```bash
./build.sh            # Android here; Android and iOS on macOS
./build.sh android
./build.sh ios        # needs Xcode
```

Needs the Titanium CLI and SDK 13.x. The Titanium CLI refuses to build a
module that lives inside an app project, which is why `build.sh` copies the
platform folder to a temp directory first. The zips contain the LICENSE.

The Android binaries are built with Titanium 13's NDK settings and are 16 KB
page-size aligned (Android 15+).

## Third-party notices

| Component | Licence |
| --- | --- |
| [Java-WebSocket](https://github.com/TooTallNate/Java-WebSocket) 1.5.3 (Android; a dependency Titanium itself ships, resolved by Gradle, not copied into this repository or the zips) | MIT, Copyright (c) 2010-2020 Nathan Rajlich |

`ios/.clang-format`, `android/.clang-format`, the generated `TiSocketlineModuleAssets`
files and `example/app/DefaultIcon.png` come from the Titanium SDK's templates
(Apache-2.0, TiDev, Inc.). Titanium SDK is Apache-2.0.

## License

Apache-2.0. Copyright (c) 2026 Centreville Tech LLC. See [LICENSE](LICENSE).
