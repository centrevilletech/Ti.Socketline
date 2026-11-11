// Ti.Socketline example: connect to a WebSocket echo server, send a message every few
// seconds and show what comes back. Change URL to your own server.
const Socketline = require('ti.socketline');

const URL = 'wss://echo.websocket.org';

const win = Ti.UI.createWindow({ backgroundColor: '#fff', layout: 'vertical' });
const status = Ti.UI.createLabel({ top: 60, left: 20, right: 20, text: 'idle' });
const log = Ti.UI.createLabel({ top: 20, left: 20, right: 20, font: { fontSize: 12 }, text: '' });
const button = Ti.UI.createButton({ top: 20, title: 'Connect' });
win.add([status, button, log]);

let socket = null;
let timer = null;

function append(line) {
	log.text = (line + '\n' + log.text).slice(0, 2000);
}

function connect() {
	socket = Socketline.createSocket({ url: URL });
	status.text = 'connecting';
	socket.addEventListener('open', function () {
		status.text = 'open';
		button.title = 'Close';
		let n = 0;
		timer = setInterval(function () {
			n += 1;
			socket.send('hello ' + n);
		}, 3000);
	});
	socket.addEventListener('message', function (e) {
		append('< ' + e.data);
	});
	socket.addEventListener('error', function (e) {
		append('error: ' + e.error);
	});
	socket.addEventListener('close', function (e) {
		clearInterval(timer);
		status.text = 'closed ' + e.code + (e.reason ? ' (' + e.reason + ')' : '');
		button.title = 'Connect';
		socket = null;
	});
	socket.connect();
}

button.addEventListener('click', function () {
	if (socket) {
		socket.close(1000, 'user closed');
	} else {
		connect();
	}
});

win.open();
