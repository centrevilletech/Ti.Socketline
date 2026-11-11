# Ti.Socketline

A native WebSocket client for Titanium (`ws://` and `wss://`, text frames), with the
same events and close codes on iOS and Android.

```javascript
const socket = require('ti.socketline').createSocket({ url: 'wss://example.com/socket', protocols: ['chat.v2'] });
socket.addEventListener('message', (e) => Ti.API.info(e.data));
socket.connect();
```

Options: `url`, `protocols`, `headers`, `connectTimeout`.
Methods: `connect()`, `send(text)` → Boolean, `close([code], [reason])` (throws on
invalid arguments). Properties: `readyState`, `protocol`, `url`. Events: `open`
(`protocol`), `message` (`data`), `error` (`code`, `error`), `close` (`code`,
`reason`, `wasClean`).

Full documentation, the close-code and error-code tables: https://github.com/centrevilletech/Ti.Socketline
