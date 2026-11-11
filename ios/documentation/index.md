# Ti.Socketline

A native WebSocket client for Titanium (`ws://` and `wss://`, text frames).

```javascript
const socket = require('ti.socketline').createSocket({ url: 'wss://example.com/socket' });
socket.addEventListener('message', (e) => Ti.API.info(e.data));
socket.connect();
```

Methods: `connect()`, `send(text)` → Boolean, `close([code], [reason])`.
Properties: `readyState`, `url`. Events: `open`, `message` (`data`), `error`
(`error`), `close` (`code`, `reason`, `wasClean`).

Full documentation: https://github.com/centrevilletech/Ti.Socketline
