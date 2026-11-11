/**
 * Ti.Socketline example: self-test against the local test server (../../server/server.js).
 * Copyright (c) 2026 Centreville Tech LLC. Licensed under the Apache License, Version 2.0.
 *
 * Every check runs against the real module on the device or simulator. Results go to the log
 * ("[selftest] PASS|FAIL|SKIP name: detail", then "[selftest] SUMMARY passed=N failed=N skipped=N")
 * and to selftest.json in the app's data directory.
 */
'use strict';

const Socketline = require('ti.socketline');

const HOST = '127.0.0.1';
const BASE = 8765;
const WS = `ws://${HOST}:${BASE}`;
const SILENT = `${HOST}:${BASE + 1}`;
const WSS_GOOD = `wss://${HOST}:${BASE + 2}`;
const WSS_WRONG_HOST = `wss://${HOST}:${BASE + 3}`;
const WSS_SELF_SIGNED = `wss://${HOST}:${BASE + 4}`;
const REFUSED = `ws://${HOST}:${BASE + 5}/echo`;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** A socket whose events are recorded, with helpers to wait for them. */
function track(options) {
	const socket = Socketline.createSocket(options);
	const events = [];
	const waiters = [];
	const record = (type) => (e) => {
		const entry = { type, e, at: Date.now() };
		events.push(entry);
		for (const w of waiters.slice()) {
			if (w.match(entry)) {
				waiters.splice(waiters.indexOf(w), 1);
				clearTimeout(w.timer);
				w.resolve(entry);
			}
		}
	};
	[ 'open', 'message', 'error', 'close' ].forEach((type) => socket.addEventListener(type, record(type)));
	const t = {
		socket,
		events,
		count: (type) => events.filter((x) => x.type === type).length,
		types: () => events.map((x) => x.type),
		waitFor(match, ms, what) {
			const matcher = typeof match === 'string' ? (x) => x.type === match : match;
			const found = events.find(matcher);
			if (found) {
				return Promise.resolve(found);
			}
			return new Promise((resolve, reject) => {
				const w = { match: matcher, resolve };
				w.timer = setTimeout(() => {
					waiters.splice(waiters.indexOf(w), 1);
					reject(new Error(`timed out after ${ms} ms waiting for ${what || match}; events: ${t.types().join(',') || 'none'}`));
				}, ms);
				waiters.push(w);
			});
		},
		message(text, ms) {
			return t.waitFor((x) => x.type === 'message' && x.e.data === text, ms || 5000, 'message ' + JSON.stringify(text));
		},
		async opened(ms) {
			const first = await t.waitFor((x) => x.type === 'open' || x.type === 'close', ms || 8000, 'open');
			if (first.type !== 'open') {
				throw new Error('closed instead of opening: ' + describe(first.e) + ' after ' + t.types().join(','));
			}
			return first;
		},
		closed(ms) {
			return t.waitFor('close', ms || 8000, 'close');
		}
	};
	return t;
}

function describe(e) {
	return e ? JSON.stringify({ code: e.code, reason: e.reason, wasClean: e.wasClean, error: e.error, errorCode: e.code }) : '';
}

function check(condition, message) {
	if (!condition) {
		throw new Error(message);
	}
}

function expectClose(closeEvent, code, wasClean, reason) {
	const e = closeEvent.e;
	check(e.code === code, `close code ${e.code}, expected ${code}`);
	check(e.wasClean === wasClean, `wasClean ${e.wasClean}, expected ${wasClean}`);
	if (reason !== undefined) {
		check(e.reason === reason, `close reason ${JSON.stringify(e.reason)}, expected ${JSON.stringify(reason)}`);
	}
}

/** After close: exactly one close event, and nothing after it. */
async function settled(t) {
	await sleep(400);
	check(t.count('close') === 1, `close fired ${t.count('close')} times`);
	check(t.types()[t.types().length - 1] === 'close', 'events after close: ' + t.types().join(','));
	check(t.socket.readyState === Socketline.CLOSED, `readyState ${t.socket.readyState} after close`);
	check(t.socket.send('late') === false, 'send() after close returned true');
}

function errorBeforeClose(t, code) {
	const errors = t.events.filter((x) => x.type === 'error');
	check(errors.length === 1, `${errors.length} error events, expected 1: ` + t.types().join(','));
	check(errors[0].e.code === code, `error code ${errors[0].e.code} (${errors[0].e.error}), expected ${code}`);
	check(typeof errors[0].e.error === 'string' && errors[0].e.error.length > 0, 'error has no description');
	check(t.types().indexOf('error') < t.types().indexOf('close'), 'error did not come before close');
}

async function failsWith(options, errorCode, ms) {
	const t = track(options);
	const started = Date.now();
	t.socket.connect();
	const close = await t.closed(ms || 10000);
	check(t.count('open') === 0, 'opened');
	expectClose(close, 1006, false, '');
	errorBeforeClose(t, errorCode);
	await settled(t);
	return close.at - started;
}

/** Opens /echo (or the given route) and returns the tracker. */
async function openEcho(extra) {
	const t = track(Object.assign({ url: WS + '/echo' }, extra));
	t.socket.connect();
	await t.opened();
	return t;
}

async function serverCloses(command, code, reason) {
	const t = await openEcho();
	t.socket.send(command);
	const close = await t.closed();
	expectClose(close, code, true, reason);
	check(t.count('error') === 0, 'error event on a clean close');
	await settled(t);
}

const tests = [
	[ 'echo, readyState, open.protocol, send() before open', async () => {
		const t = track({ url: WS + '/echo' });
		check(t.socket.readyState === Socketline.CONNECTING, 'readyState before connect ' + t.socket.readyState);
		check(t.socket.send('too early') === false, 'send() before open returned true');
		check(t.socket.url === WS + '/echo', 'url property ' + t.socket.url);
		t.socket.connect();
		check(t.socket.send('too early') === false, 'send() while connecting returned true');
		const open = await t.opened();
		check(open.e.protocol === '', 'open.protocol ' + JSON.stringify(open.e.protocol));
		check(t.socket.protocol === '', 'socket.protocol ' + JSON.stringify(t.socket.protocol));
		check(t.socket.readyState === Socketline.OPEN, 'readyState after open ' + t.socket.readyState);
		check(t.socket.send('hello') === true, 'send() returned false');
		await t.message('hello');
		t.socket.close();
		check(t.socket.readyState === Socketline.CLOSING, 'readyState after close() ' + t.socket.readyState);
		expectClose(await t.closed(), 1000, true, '');
		await settled(t);
	} ],
	[ 'close(4000, reason): the server echoes it, clean', async () => {
		const t = await openEcho();
		t.socket.close(4000, 'see you later');
		expectClose(await t.closed(), 4000, true, 'see you later');
		check(t.count('error') === 0, 'error event');
		await settled(t);
	} ],
	[ 'server closes 1000', () => serverCloses('close:1000:done', 1000, 'done') ],
	[ 'server closes 1001', () => serverCloses('close:1001:going away', 1001, 'going away') ],
	[ 'server closes with an application code 4001: clean', () => serverCloses('close:4001:token expired', 4001, 'token expired') ],
	[ 'server close frame without a code: 1005, clean', () => serverCloses('close-nocode', 1005, '') ],
	[ 'server drops the TCP connection: CONNECTION_LOST, 1006', async () => {
		const t = await openEcho();
		t.socket.send('drop');
		expectClose(await t.closed(), 1006, false, '');
		errorBeforeClose(t, 'CONNECTION_LOST');
		await settled(t);
	} ],
	[ 'connection refused: CONNECT_FAILED, 1006', () => failsWith({ url: REFUSED }, 'CONNECT_FAILED') ],
	[ 'ws:// server accepts TCP and says nothing: CONNECT_TIMEOUT after connectTimeout', async () => {
		const ms = await failsWith({ url: `ws://${SILENT}/echo`, connectTimeout: 1500 }, 'CONNECT_TIMEOUT', 8000);
		check(ms >= 1300 && ms < 4000, `closed after ${ms} ms, expected about 1500`);
	} ],
	[ 'wss:// server accepts TCP and says nothing (TLS never starts): CONNECT_TIMEOUT', async () => {
		const ms = await failsWith({ url: `wss://${SILENT}/echo`, connectTimeout: 1500 }, 'CONNECT_TIMEOUT', 8000);
		check(ms >= 1300 && ms < 4000, `closed after ${ms} ms, expected about 1500`);
	} ],
	[ 'slow upgrade (1.5 s) within connectTimeout opens', async () => {
		const t = await openEcho({ url: WS + '/slow?ms=1500', connectTimeout: 5000 });
		t.socket.close();
		await t.closed();
		await settled(t);
	} ],
	[ 'close() while connecting: 1006 at once, no error', async () => {
		const t = track({ url: `ws://${SILENT}/echo`, connectTimeout: 10000 });
		t.socket.connect();
		await sleep(300);
		const asked = Date.now();
		t.socket.close();
		const close = await t.closed(3000);
		expectClose(close, 1006, false, '');
		check(close.at - asked < 1000, `close came ${close.at - asked} ms after close()`);
		check(t.count('error') === 0 && t.count('open') === 0, 'events: ' + t.types().join(','));
		await sleep(1500);
		check(t.count('open') === 0, 'opened after close()');
		await settled(t);
	} ],
	[ 'close() before connect(): 1006, and connect() then does nothing', async () => {
		const t = track({ url: WS + '/echo' });
		t.socket.close();
		expectClose(await t.closed(2000), 1006, false, '');
		t.socket.connect();
		await sleep(1000);
		check(t.count('open') === 0, 'opened after close()');
		await settled(t);
	} ],
	[ 'TLS: certificate from a trusted CA, TLS 1.3', async () => {
		const t = await openEcho({ url: WSS_GOOD + '/echo' });
		t.socket.send('tls');
		await t.message('TLSv1.3');
		t.socket.close();
		expectClose(await t.closed(), 1000, true);
		await settled(t);
	} ],
	[ 'TLS: certificate for another host name: TLS_FAILED', () => failsWith({ url: WSS_WRONG_HOST + '/echo' }, 'TLS_FAILED') ],
	[ 'TLS: self-signed certificate: TLS_FAILED', () => failsWith({ url: WSS_SELF_SIGNED + '/echo' }, 'TLS_FAILED') ],
	[ 'cleartext ws:// to a host the platform policy forbids: CLEARTEXT_NOT_PERMITTED', () => failsWith({ url: 'ws://example.com/socket' }, 'CLEARTEXT_NOT_PERMITTED') ],
	[ 'subprotocol: the server selects chat.v2', async () => {
		const t = await openEcho({ url: WS + '/protocol', protocols: [ 'chat.v2', 'chat.v1' ] });
		check(t.events[0].e.protocol === 'chat.v2', 'open.protocol ' + JSON.stringify(t.events[0].e.protocol));
		check(t.socket.protocol === 'chat.v2', 'socket.protocol ' + JSON.stringify(t.socket.protocol));
		t.socket.send('x');
		await t.message('x');
		t.socket.close();
		await t.closed();
		await settled(t);
	} ],
	[ 'subprotocol required, none offered: HANDSHAKE_FAILED', () => failsWith({ url: WS + '/protocol' }, 'HANDSHAKE_FAILED') ],
	[ 'server selects a subprotocol that was not offered: HANDSHAKE_FAILED', () => failsWith({ url: WS + '/evil-protocol', protocols: 'chat.v2' }, 'HANDSHAKE_FAILED') ],
	[ 'server ignores the offered subprotocols: opens with protocol ""', async () => {
		const t = await openEcho({ url: WS + '/no-protocol', protocols: [ 'chat.v2' ] });
		check(t.events[0].e.protocol === '', 'open.protocol ' + JSON.stringify(t.events[0].e.protocol));
		t.socket.close();
		await t.closed();
		await settled(t);
	} ],
	[ 'upgrade rejected with HTTP 401: HANDSHAKE_FAILED', () => failsWith({ url: WS + '/reject' }, 'HANDSHAKE_FAILED') ],
	[ 'custom headers reach the server; the subprotocol header is set from protocols', async () => {
		const t = track({ url: WS + '/headers', headers: { 'X-Test': 'abc 123', Authorization: 'Bearer t0k3n' }, protocols: [ 'p1', 'p2' ] });
		t.socket.connect();
		const first = await t.waitFor('message', 8000);
		const headers = JSON.parse(first.e.data);
		check(headers['x-test'] === 'abc 123', 'x-test ' + headers['x-test']);
		check(headers.authorization === 'Bearer t0k3n', 'authorization ' + headers.authorization);
		check(/^p1, ?p2$/.test(headers['sec-websocket-protocol'] || ''), 'sec-websocket-protocol ' + headers['sec-websocket-protocol']);
		t.socket.close();
		await t.closed();
		await settled(t);
	} ],
	[ 'large text frames: 2 MiB each way', async () => {
		const t = await openEcho();
		const big = 'y'.repeat(2 * 1024 * 1024);
		check(t.socket.send(big) === true, 'send() returned false');
		const echo = await t.waitFor((x) => x.type === 'message' && x.e.data.length === big.length, 20000, '2 MiB echo');
		check(echo.e.data === big, 'echo differs');
		t.socket.send('big:3000000');
		await t.waitFor((x) => x.type === 'message' && x.e.data.length === 3000000, 20000, '3,000,000 byte message');
		t.socket.close();
		await t.closed();
		await settled(t);
	} ],
	[ 'many small frames: 2000 in order', async () => {
		const t = await openEcho();
		t.socket.send('burst:2000');
		await t.message('m1999', 20000);
		const got = t.events.filter((x) => x.type === 'message').map((x) => x.e.data);
		check(got.length === 2000, `${got.length} messages`);
		for (let i = 0; i < 2000; i++) {
			if (got[i] !== 'm' + i) {
				throw new Error(`message ${i} is ${got[i]}`);
			}
		}
		t.socket.close();
		await t.closed();
		await settled(t);
	} ],
	[ 'ping from the server is answered with a pong', async () => {
		const t = await openEcho();
		t.socket.send('ping');
		await t.message('pong-received');
		t.socket.close();
		await t.closed();
		await settled(t);
	} ],
	[ 'binary frame: BINARY_FRAME error, nothing delivered, connection stays open', async () => {
		const t = await openEcho();
		t.socket.send('binary');
		await t.message('after-binary');
		const errors = t.events.filter((x) => x.type === 'error');
		check(errors.length === 1 && errors[0].e.code === 'BINARY_FRAME', 'errors: ' + JSON.stringify(errors.map((x) => x.e)));
		const messages = t.events.filter((x) => x.type === 'message').map((x) => x.e.data);
		check(messages.length === 1 && messages[0] === 'after-binary', 'messages: ' + JSON.stringify(messages));
		check(t.socket.readyState === Socketline.OPEN, 'readyState ' + t.socket.readyState);
		t.socket.send('still here');
		await t.message('still here');
		t.socket.close();
		await t.closed();
		await settled(t);
	} ],
	[ 'server never answers the close frame: 1006 after closeTimeout, no error', async () => {
		const t = await openEcho({ url: WS + '/ignore-close', closeTimeout: 1000 });
		const asked = Date.now();
		t.socket.close(1000, 'bye');
		const close = await t.closed(6000);
		expectClose(close, 1006, false, '');
		check(close.at - asked >= 800 && close.at - asked < 3500, `closed ${close.at - asked} ms after close()`);
		check(t.count('error') === 0, 'error event');
		await settled(t);
	} ],
	[ 'close() argument validation throws and leaves the socket open', async () => {
		const t = await openEcho();
		const bad = [
			[ [ 1001 ], 'close code must be 1000 or an integer from 3000 to 4999' ],
			[ [ 2999 ], 'close code must be 1000 or an integer from 3000 to 4999' ],
			[ [ 5000 ], 'close code must be 1000 or an integer from 3000 to 4999' ],
			[ [ 3000.5 ], 'close code must be 1000 or an integer from 3000 to 4999' ],
			[ [ '1000' ], 'close code must be a number' ],
			[ [ 1000, 'a'.repeat(124) ], 'close reason must be at most 123 bytes in UTF-8' ],
			[ [ 4000, 'é'.repeat(62) ], 'close reason must be at most 123 bytes in UTF-8' ],
			[ [ 1000, 42 ], 'close reason must be a string' ]
		];
		for (const [ argsList, message ] of bad) {
			let thrown = null;
			try {
				t.socket.close.apply(t.socket, argsList);
			} catch (e) {
				thrown = e;
			}
			check(thrown !== null, `close(${JSON.stringify(argsList).slice(1, 40)}) did not throw`);
			check(String(thrown.message || thrown).indexOf(message) >= 0, `close(${JSON.stringify(argsList).slice(1, 40)}) threw "${thrown.message || thrown}"`);
			check(t.socket.readyState === Socketline.OPEN, 'readyState changed to ' + t.socket.readyState);
		}
		t.socket.send('still open');
		await t.message('still open');
		t.socket.close(3000, 'é'.repeat(61));
		expectClose(await t.closed(), 3000, true, 'é'.repeat(61));
		await settled(t);
	} ],
	[ 'invalid options: INVALID_OPTIONS error and close 1006, delivered after connect() returns', async () => {
		const cases = [
			{ url: 'https://example.com/' },
			{ url: WS + '/echo', protocols: [ 'bad protocol' ] },
			{ url: WS + '/echo', headers: { 'Sec-WebSocket-Protocol': 'chat' } },
			{ url: WS + '/echo', connectTimeout: 0 }
		];
		for (const options of cases) {
			const t = track(options);
			t.socket.connect();
			check(t.events.length === 0, 'events delivered synchronously inside connect()');
			const close = await t.closed(3000);
			expectClose(close, 1006, false, '');
			errorBeforeClose(t, 'INVALID_OPTIONS');
			await settled(t);
		}
	} ],
	[ 'idle 6 s with connectTimeout 1.5 s: still open, still echoes', async () => {
		const t = await openEcho({ connectTimeout: 1500 });
		await sleep(6000);
		check(t.count('close') === 0, 'closed while idle: ' + describe((t.events.find((x) => x.type === 'close') || {}).e));
		t.socket.send('after idle');
		await t.message('after idle');
		t.socket.close();
		await t.closed();
		await settled(t);
	} ],
	[ 'a socket the app no longer references keeps working until it closes', async () => {
		let result = null;
		(function () {
			const s = Socketline.createSocket({ url: WS + '/echo' });
			s.addEventListener('open', () => s.send('orphan'));
			s.addEventListener('message', (e) => {
				if (e.data === 'orphan') {
					s.close();
				}
			});
			s.addEventListener('close', (e) => {
				result = e;
			});
			s.connect();
		}());
		for (let i = 0; i < 50 && !result; i++) {
			await sleep(100);
		}
		check(result && result.code === 1000 && result.wasClean === true, 'close ' + describe(result));
	} ]
];

const results = [];

function report(status, name, detail) {
	results.push({ status, name, detail: detail || '' });
	Ti.API.info(`[selftest] ${status} ${name}${detail ? ': ' + detail : ''}`);
}

function writeResults(extra) {
	const passed = results.filter((r) => r.status === 'PASS').length;
	const failed = results.filter((r) => r.status === 'FAIL').length;
	const skipped = results.filter((r) => r.status === 'SKIP').length;
	const file = Ti.Filesystem.getFile(Ti.Filesystem.applicationDataDirectory, 'selftest.json');
	file.write(JSON.stringify(Object.assign({ platform: Ti.Platform.osname, passed, failed, skipped, results }, extra || {}), null, 1));
	return { passed, failed, skipped };
}

exports.run = async function (onProgress) {
	results.length = 0;
	for (const [ name, fn ] of tests) {
		onProgress && onProgress(name);
		try {
			await Promise.race([ fn(), sleep(45000).then(() => {
				throw new Error('test timed out after 45 s');
			}) ]);
			report('PASS', name);
		} catch (e) {
			report('FAIL', name, String(e && e.message || e));
		}
	}
	const counts = writeResults();
	Ti.API.info(`[selftest] SUMMARY passed=${counts.passed} failed=${counts.failed} skipped=${counts.skipped}`);
	return counts;
};

/**
 * Background check, the way an app should handle it: close the socket on pause, open a new one on
 * resume. The driver script sends the app to the background and brings it back.
 */
exports.armBackgroundCheck = function () {
	let socket = null;
	let oldClose = 0;
	let phase = 'waiting for pause';
	Ti.API.info('[selftest] BACKGROUND armed: send the app to the background, then bring it back');
	const open = () => new Promise((resolve, reject) => {
		const t = track({ url: WS + '/echo' });
		t.socket.connect();
		t.opened().then(() => resolve(t), reject);
	});
	open().then((t) => {
		socket = t;
	});
	Ti.App.addEventListener('pause', function onPause() {
		Ti.App.removeEventListener('pause', onPause);
		phase = 'paused';
		if (socket) {
			socket.socket.addEventListener('close', () => {
				oldClose += 1;
			});
			socket.socket.close(1000, 'background');
		}
	});
	Ti.App.addEventListener('resume', async function onResume() {
		Ti.App.removeEventListener('resume', onResume);
		phase = 'resumed';
		try {
			check(socket !== null, 'no socket was open before pause');
			const t = await open();
			t.socket.send('back');
			await t.message('back');
			await sleep(800);
			check(oldClose === 1, `the old socket's close fired ${oldClose} times`);
			check(socket.socket.readyState === Socketline.CLOSED, 'old socket readyState ' + socket.socket.readyState);
			t.socket.close();
			await t.closed();
			report('PASS', 'background: closed on pause, a new socket works after resume');
		} catch (e) {
			report('FAIL', 'background: closed on pause, a new socket works after resume', String(e && e.message || e) + ' (phase ' + phase + ')');
		}
		const counts = writeResults({ background: true });
		Ti.API.info(`[selftest] BACKGROUND DONE passed=${counts.passed} failed=${counts.failed} skipped=${counts.skipped}`);
	});
};
