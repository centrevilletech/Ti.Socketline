# Ti.Socketline

A native WebSocket client for Titanium, on iOS and Android: `ws://` and `wss://`
with the platform's own TLS, text frames, open/message/error/close events.

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

- **iOS:** `NSURLSessionWebSocketTask` (iOS 13+), with the system's TLS,
  proxy and certificate handling.
- **Android:** [Java-WebSocket](https://github.com/TooTallNate/Java-WebSocket)
  1.5.3, the library Titanium itself already depends on, so nothing is
  packaged twice and there is no duplicate-class build failure.

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

Requires Titanium SDK 13.0.0.GA or later and iOS 15 or later.

## Usage

```javascript
const Socketline = require('ti.socketline');

const socket = Socketline.createSocket({
    url: 'wss://echo.example.com/socket',
    headers: { 'Sec-WebSocket-Protocol': 'chat' },   // optional
    connectTimeout: 15000                              // optional, ms
});

socket.addEventListener('open', () => {
    socket.send(JSON.stringify({ hello: 'world' }));
});

socket.addEventListener('message', (e) => {
    Ti.API.info('received ' + e.data);
});

socket.addEventListener('error', (e) => {
    Ti.API.warn('socket error: ' + e.error);
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
`close()` once. To reconnect, create a new socket. That keeps the state
machine on the native side trivial and puts reconnect policy (back-off,
re-subscribing, refetching what was missed) in your JavaScript, where it can
be tested.

### Keep-alive is yours

The module sends no pings of its own on either platform, so both behave the
same. Most protocols define an application-level ping (Pusher's
`pusher:ping`, Phoenix's heartbeat); send it, and treat a missing answer as a
dead connection: `close()` and connect a new socket.

### Background

iOS suspends sockets when the app goes to the background, and Android may
kill them. Close the socket on `pause` and open a new one on `resume`; push
notifications cover the time in between.

## API

### Module

| Member | Description |
| --- | --- |
| `createSocket({ url, headers, connectTimeout })` | A new, unconnected socket. `url` must start with `ws://` or `wss://`. |
| `CONNECTING`, `OPEN`, `CLOSING`, `CLOSED` | `readyState` values 0 to 3. |

### Socket

| Member | Returns | Notes |
| --- | --- | --- |
| `connect()` | | Opens the connection. Fires `open`, or `error` then `close`. |
| `send(text)` | `Boolean` | Sends a text frame. `false` when the socket is not open. |
| `close([code], [reason])` | | Starts the closing handshake. `code` defaults to 1000. |
| `readyState` | `Number` | One of the module constants. |
| `url` | `String` | The URL it was created with. |

### Events

| Event | Properties |
| --- | --- |
| `open` | |
| `message` | `data`: the frame's text (binary frames are passed as UTF-8 text when they decode) |
| `error` | `error`: a description |
| `close` | `code`, `reason`, `wasClean` (true for 1000 and 1001) |

`close` fires exactly once per socket, also after a failed connect (code
1006).

## Building from source

```bash
./build.sh            # Android here; Android and iOS on macOS
./build.sh android
./build.sh ios        # needs Xcode
```

Needs the Titanium CLI and SDK 13.x. The Titanium CLI refuses to build a
module that lives inside an app project, which is why `build.sh` copies the
platform folder to a temp directory first.

The Android binaries are built with Titanium 13's NDK settings and are 16 KB
page-size aligned (Android 15+).

## License

Apache-2.0. Copyright (c) 2026 Centreville Tech LLC. See [LICENSE](LICENSE).
