#!/usr/bin/env node
/**
 * Ti.Socketline example: the local test server the example app's self-test runs against.
 * Copyright (c) 2026 Centreville Tech LLC. Licensed under the Apache License, Version 2.0.
 *
 * Node.js only, no dependencies. A deliberately small RFC 6455 server that can misbehave on request:
 *
 *   BASE+0  ws://   the WebSocket routes below
 *   BASE+1  tcp     accepts connections and never says anything (connect timeouts, for ws:// and wss://)
 *   BASE+2  wss://  the same routes, certificate from the test CA for 127.0.0.1 / localhost, TLS 1.3 only
 *   BASE+3  wss://  certificate from the test CA, but for another host name (wrong.example)
 *   BASE+4  wss://  self-signed certificate (not from the test CA)
 *   BASE+5  -       nothing listens (connection refused)
 *
 * Routes (path):
 *   /echo           echoes text frames; text commands below
 *   /protocol       requires the subprotocol chat.v2 (HTTP 400 otherwise) and selects it
 *   /no-protocol    accepts, ignoring any offered subprotocol (no Sec-WebSocket-Protocol in the response)
 *   /evil-protocol  answers with a subprotocol the client did not offer
 *   /slow?ms=N      waits N ms before answering the upgrade
 *   /reject         answers HTTP 401
 *   /headers        sends the request headers as JSON, then echoes
 *   /ignore-close   echoes, but never answers the client's close frame
 *
 * Commands (text frames on any accepting route):
 *   close:CODE:REASON  the server closes with CODE and REASON
 *   close-nocode       the server sends a close frame without a code
 *   drop               the server destroys the TCP connection without a close frame
 *   binary             the server sends a binary frame, then "after-binary"
 *   ping               the server sends a ping and answers "pong-received" when the pong arrives
 *   big:N              the server sends one text frame of N bytes
 *   burst:N            the server sends N text frames "m0" .. "m(N-1)"
 *   tls                the server answers the negotiated TLS version (or "none")
 *
 * Usage: node server.js [--base 8765] [--certs ./certs]   (run ./make-certs.sh once first)
 */
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const net = require('net');
const path = require('path');
const tls = require('tls');

const args = process.argv.slice(2);
const option = (name, fallback) => {
	const i = args.indexOf('--' + name);
	return i >= 0 ? args[i + 1] : fallback;
};
const BASE = Number(option('base', 8765));
const CERTS = path.resolve(option('certs', path.join(__dirname, 'certs')));
const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function log(...parts) {
	console.log(new Date().toISOString().slice(11, 23), ...parts);
}

function frame(opcode, payload) {
	const body = Buffer.isBuffer(payload) ? payload : Buffer.from(payload || '');
	let header;
	if (body.length < 126) {
		header = Buffer.from([ 0x80 | opcode, body.length ]);
	} else if (body.length < 65536) {
		header = Buffer.alloc(4);
		header[0] = 0x80 | opcode;
		header[1] = 126;
		header.writeUInt16BE(body.length, 2);
	} else {
		header = Buffer.alloc(10);
		header[0] = 0x80 | opcode;
		header[1] = 127;
		header.writeBigUInt64BE(BigInt(body.length), 2);
	}
	return Buffer.concat([ header, body ]);
}

function closePayload(code, reason) {
	if (code === undefined) {
		return Buffer.alloc(0);
	}
	const r = Buffer.from(reason || '');
	const b = Buffer.alloc(2 + r.length);
	b.writeUInt16BE(code, 0);
	r.copy(b, 2);
	return b;
}

function httpResponse(socket, status, text) {
	socket.end(`HTTP/1.1 ${status} ${text}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`);
}

function handleConnection(socket, label) {
	let buffered = Buffer.alloc(0);
	let upgraded = false;
	const onHandshakeData = (chunk) => {
		buffered = Buffer.concat([ buffered, chunk ]);
		const end = buffered.indexOf('\r\n\r\n');
		if (end < 0) {
			return;
		}
		socket.removeListener('data', onHandshakeData);
		const head = buffered.slice(0, end).toString('latin1');
		const rest = buffered.slice(end + 4);
		const lines = head.split('\r\n');
		const [ , target ] = lines[0].split(' ');
		const headers = {};
		for (const line of lines.slice(1)) {
			const i = line.indexOf(':');
			if (i > 0) {
				headers[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim();
			}
		}
		const url = new URL(target, 'http://localhost');
		const route = url.pathname;
		log(label, 'upgrade', target, headers['sec-websocket-protocol'] ? 'protocols=' + headers['sec-websocket-protocol'] : '');
		if (route === '/reject') {
			return httpResponse(socket, 401, 'Unauthorized');
		}
		if (!headers['sec-websocket-key'] || (headers.upgrade || '').toLowerCase() !== 'websocket') {
			return httpResponse(socket, 400, 'Bad Request');
		}
		const offered = (headers['sec-websocket-protocol'] || '').split(',').map((p) => p.trim()).filter(Boolean);
		let selected = null;
		if (route === '/protocol') {
			if (!offered.includes('chat.v2')) {
				return httpResponse(socket, 400, 'Subprotocol Required');
			}
			selected = 'chat.v2';
		} else if (route === '/evil-protocol') {
			selected = 'evil';
		}
		const accept = crypto.createHash('sha1').update(headers['sec-websocket-key'] + GUID).digest('base64');
		const response = 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
			+ `Sec-WebSocket-Accept: ${accept}\r\n` + (selected ? `Sec-WebSocket-Protocol: ${selected}\r\n` : '') + '\r\n';
		const delay = route === '/slow' ? Number(url.searchParams.get('ms') || 1500) : 0;
		setTimeout(() => {
			if (socket.destroyed) {
				return;
			}
			socket.write(response);
			upgraded = true;
			startSession(socket, label, route, headers, rest);
		}, delay);
	};
	socket.on('data', onHandshakeData);
	socket.on('error', (e) => log(label, 'socket error', e.code || e.message));
	socket.on('close', () => {
		if (!upgraded) {
			log(label, 'connection closed before upgrade');
		}
	});
}

function startSession(socket, label, route, requestHeaders, initial) {
	let buffer = Buffer.alloc(0);
	let fragments = null;
	let fragmentOpcode = 0;
	let closeSent = false;
	let pingPending = false;
	const send = (opcode, payload) => {
		if (!socket.destroyed) {
			socket.write(frame(opcode, payload));
		}
	};
	const sendClose = (code, reason) => {
		if (closeSent) {
			return;
		}
		closeSent = true;
		send(0x8, closePayload(code, reason));
	};

	if (route === '/headers') {
		send(0x1, JSON.stringify(requestHeaders));
	}

	const onText = (text) => {
		if (text.startsWith('close:')) {
			const [ , code, ...reason ] = text.split(':');
			return sendClose(Number(code), reason.join(':'));
		}
		if (text === 'close-nocode') {
			return sendClose(undefined, '');
		}
		if (text === 'drop') {
			log(label, 'dropping the connection');
			return socket.destroy();
		}
		if (text === 'binary') {
			send(0x2, Buffer.from([ 0xff, 0xfe, 0x00, 0x01 ]));
			return send(0x1, 'after-binary');
		}
		if (text === 'ping') {
			pingPending = true;
			return send(0x9, 'are-you-there');
		}
		if (text.startsWith('big:')) {
			return send(0x1, 'x'.repeat(Number(text.slice(4))));
		}
		if (text.startsWith('burst:')) {
			const n = Number(text.slice(6));
			for (let i = 0; i < n; i++) {
				send(0x1, 'm' + i);
			}
			return;
		}
		if (text === 'tls') {
			return send(0x1, socket.getProtocol ? String(socket.getProtocol()) : 'none');
		}
		send(0x1, text);
	};

	const onFrame = (fin, opcode, payload) => {
		if (opcode === 0x0) {
			if (!fragments) {
				return;
			}
			fragments.push(payload);
			if (fin) {
				const whole = Buffer.concat(fragments);
				fragments = null;
				onFrame(true, fragmentOpcode, whole);
			}
			return;
		}
		if (!fin && (opcode === 0x1 || opcode === 0x2)) {
			fragments = [ payload ];
			fragmentOpcode = opcode;
			return;
		}
		switch (opcode) {
			case 0x1:
				onText(payload.toString('utf8'));
				break;
			case 0x2:
				send(0x2, payload); // echo binary
				break;
			case 0x8: {
				const code = payload.length >= 2 ? payload.readUInt16BE(0) : undefined;
				const reason = payload.length > 2 ? payload.slice(2).toString('utf8') : '';
				log(label, 'client close frame', code === undefined ? '(no code)' : code, JSON.stringify(reason));
				if (route === '/ignore-close') {
					log(label, 'ignoring the close frame');
					break;
				}
				if (!closeSent) {
					sendClose(code, reason); // echo, completing the handshake
				}
				socket.end();
				break;
			}
			case 0x9:
				send(0xA, payload);
				break;
			case 0xA:
				if (pingPending) {
					pingPending = false;
					send(0x1, 'pong-received');
				}
				break;
			default:
				break;
		}
	};

	const onData = (chunk) => {
		buffer = Buffer.concat([ buffer, chunk ]);
		while (buffer.length >= 2) {
			const fin = (buffer[0] & 0x80) !== 0;
			const opcode = buffer[0] & 0x0f;
			const masked = (buffer[1] & 0x80) !== 0;
			let length = buffer[1] & 0x7f;
			let offset = 2;
			if (length === 126) {
				if (buffer.length < 4) {
					return;
				}
				length = buffer.readUInt16BE(2);
				offset = 4;
			} else if (length === 127) {
				if (buffer.length < 10) {
					return;
				}
				length = Number(buffer.readBigUInt64BE(2));
				offset = 10;
			}
			const maskOffset = offset;
			if (masked) {
				offset += 4;
			}
			if (buffer.length < offset + length) {
				return;
			}
			const payload = Buffer.from(buffer.slice(offset, offset + length));
			if (masked) {
				for (let i = 0; i < payload.length; i++) {
					payload[i] ^= buffer[maskOffset + (i % 4)];
				}
			}
			buffer = buffer.slice(offset + length);
			onFrame(fin, opcode, payload);
		}
	};
	socket.on('data', onData);
	socket.on('close', () => log(label, 'closed'));
	if (initial.length) {
		onData(initial);
	}
}

function readCert(name) {
	return fs.readFileSync(path.join(CERTS, name));
}

let connections = 0;
const label = (port) => (socket) => `${port}#${++connections}`;

net.createServer((s) => handleConnection(s, label(BASE)(s))).listen(BASE, '127.0.0.1', () => log('ws   ', BASE));
net.createServer((s) => {
	log(`${BASE + 1}#${++connections}`, 'silent connection accepted');
	s.on('error', () => {});
}).listen(BASE + 1, '127.0.0.1', () => log('silent', BASE + 1));

const tlsServers = [
	[ BASE + 2, 'good.key', 'good.crt', { minVersion: 'TLSv1.3' } ],
	[ BASE + 3, 'wrong-host.key', 'wrong-host.crt', {} ],
	[ BASE + 4, 'self-signed.key', 'self-signed.crt', {} ]
];
for (const [ port, key, cert, extra ] of tlsServers) {
	const server = tls.createServer(Object.assign({ key: readCert(key), cert: readCert(cert) }, extra), (s) => handleConnection(s, label(port)(s)));
	server.on('tlsClientError', (e) => log(port, 'TLS handshake failed:', e.code || e.message));
	server.listen(port, '127.0.0.1', () => log('wss  ', port, cert));
}
log('refused', BASE + 5, '(nothing listens)');
